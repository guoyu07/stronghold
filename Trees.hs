{-# LANGUAGE GADTs, DataKinds, OverloadedStrings, StandaloneDeriving, FlexibleInstances #-}
module Trees where

{-
  This module is responsible for the interacting with the tree structure on the
  data in zookeeper.
-}

import Data.Monoid (mempty, mappend)
import Data.Maybe (fromJust, isJust)
import Data.Text (Text)
import qualified Data.Text as Text
import qualified Data.Aeson as Aeson
import Data.HashMap.Strict (HashMap, unionWith)
import qualified Data.HashMap.Strict as HashMap
import qualified Data.HashSet as HashSet
import Data.Hashable (Hashable)
import Data.Time.Clock (UTCTime)

import Control.Applicative ((<$>))
import Control.Monad (foldM)

import StoredData
import qualified ZkInterface as Zk

import Util (deepMerge, Path(Path), pathToList, listToPath)

-- This is a little tricky, if you're having difficulty understanding, read up 
-- on fixed point combinators and fixed point types.

-- Essentially, what's going on here is that a tree is being defined by taking 
-- the fixed point of (m :: * -> *). Except that, at every recursion site, 
-- there might be a reference instead of a subtree.
newtype Mu t m = Mu (Either t (m (Mu t m)))

-- These are data types that may have pieces that aren't in local memory.
type JSON' = Either (Ref JSONTag) JSON
type Hierarchy = Mu (Ref HierarchyTag) (TreeNode JSON' Text)
type History = Mu (Ref HistoryTag) (ListNode (MetaInfo, Hierarchy))

instance Show (Mu (Ref HierarchyTag) (TreeNode JSON' Text)) where
  show (Mu t) = show t

instance Show (Mu (Ref HistoryTag) (ListNode (MetaInfo, Hierarchy))) where
  show (Mu t) = show t

makeHistoryTree :: Ref HistoryTag -> History
makeHistoryTree = Mu . Left

makeHierarchyTree :: Ref HierarchyTag -> Hierarchy
makeHierarchyTree = Mu . Left

storeJSON :: JSON' -> StoreOp (Ref JSONTag)
storeJSON (Left x) = return x
storeJSON (Right x) = store $ JSONData x

storeHierarchy :: Hierarchy -> StoreOp (Ref HierarchyTag)
storeHierarchy (Mu (Left x)) = return x
storeHierarchy (Mu (Right (TreeNode l json))) = do
  json' <- storeJSON json
  l' <- HashMap.fromList <$> mapM (\(k, v) -> (,) k <$> storeHierarchy v) (HashMap.toList l)
  store $ HierarchyNode (TreeNode l' json')

storeHistory :: History -> StoreOp (Ref HistoryTag)
storeHistory (Mu (Left x)) = return x
storeHistory (Mu (Right Nil)) = store $ HistoryNode Nil
storeHistory (Mu (Right (Cons (meta, hier) xs))) = do
  xs' <- storeHistory xs
  hier' <- storeHierarchy hier
  store $ HistoryNode $ Cons (meta, hier') xs'

emptyObject' :: JSON' -> Bool
emptyObject' (Left x) = emptyObject x
emptyObject' (Right x) = Aeson.object [] == x

refJSON :: JSON -> JSON'
refJSON = Right

derefJSON :: JSON' -> StoreOp JSON
derefJSON (Right x) = return x
derefJSON (Left r) = do
  JSONData d <- load r
  return d

refHistory :: ListNode (MetaInfo, Hierarchy) History -> History
refHistory = Mu . Right

derefHistory :: History -> StoreOp (ListNode (MetaInfo, Hierarchy) History)
derefHistory (Mu (Right x)) = return x
derefHistory (Mu (Left r)) = do
  HistoryNode l <- load r
  return $
    case l of
      Nil -> Nil
      Cons (meta, hierarchy) history -> Cons (meta, Mu (Left hierarchy)) (Mu (Left history))

refHierarchy :: TreeNode JSON' Text Hierarchy -> Hierarchy
refHierarchy = Mu . Right

derefHierarchy :: Hierarchy -> StoreOp (TreeNode JSON' Text Hierarchy)
derefHierarchy (Mu (Right x)) = return x
derefHierarchy (Mu (Left r)) = do
  HierarchyNode (TreeNode l json) <- load r
  return $ TreeNode (HashMap.map (\v -> Mu (Left v)) l) (Left json)

data HierarchyCtx = HierarchyCtx [(Text, HashMap Text Hierarchy, JSON')] deriving Show
data HierarchyZipper = HierarchyZipper HierarchyCtx (TreeNode JSON' Text Hierarchy) deriving Show

makeHierarchyZipper :: Hierarchy -> StoreOp HierarchyZipper
makeHierarchyZipper hier = HierarchyZipper (HierarchyCtx []) <$> derefHierarchy hier

down :: Text -> HierarchyZipper -> StoreOp HierarchyZipper
down key (HierarchyZipper (HierarchyCtx hierCtx) (TreeNode children json)) =
  let hierCtx' = HierarchyCtx ((key, HashMap.delete key children, json):hierCtx)
      def = return $ TreeNode HashMap.empty (refJSON (Aeson.object [])) in
        HierarchyZipper hierCtx' <$> maybe def derefHierarchy (HashMap.lookup key children)

followPath :: Path -> HierarchyZipper -> StoreOp HierarchyZipper
followPath = flip (foldM (flip down)) . pathToList

up :: HierarchyZipper -> HierarchyZipper
up z@(HierarchyZipper (HierarchyCtx []) _) = z
up (HierarchyZipper (HierarchyCtx ((key, children', json'):xs)) hier@(TreeNode children json)) =
  HierarchyZipper (HierarchyCtx xs) $
    if HashMap.null children && emptyObject' json then do
      (TreeNode children' json')
    else
      (TreeNode (HashMap.insert key (refHierarchy hier) children') json')

isTop :: HierarchyZipper -> Bool
isTop (HierarchyZipper (HierarchyCtx x) _) = null x

top :: HierarchyZipper -> HierarchyZipper
top z =
  if isTop z then
    z
  else
    top (up z)

getJSON :: HierarchyZipper -> StoreOp (HierarchyZipper, JSON)
getJSON (HierarchyZipper hierCtx (TreeNode children json')) = do
  json <- derefJSON json'
  return (HierarchyZipper hierCtx (TreeNode children (refJSON json)), json)

setJSON' :: JSON' -> HierarchyZipper -> HierarchyZipper
setJSON' json' (HierarchyZipper hierCtx (TreeNode children _)) =
  HierarchyZipper hierCtx (TreeNode children json')

children :: HierarchyZipper -> [Text]
children (HierarchyZipper _ (TreeNode children _)) = HashMap.keys children

solidifyHierarchyZipper :: HierarchyZipper -> Hierarchy
solidifyHierarchyZipper hier =
  let HierarchyZipper _ hier' = top hier in
    refHierarchy hier'

subPaths :: HierarchyZipper -> StoreOp [Path]
subPaths z =
  ((mempty :) . concat) <$> mapM (\child -> do
    z' <- down child z
    paths <- subPaths z'
    return (map (mappend (listToPath [child])) paths)) (children z)

emptyHierarchy :: Hierarchy
emptyHierarchy =
  refHierarchy (TreeNode HashMap.empty (refJSON (Aeson.object [])))

lastHierarchy :: History -> StoreOp Hierarchy
lastHierarchy hist = do
  hist' <- derefHistory hist
  case hist' of
    Nil -> return emptyHierarchy
    Cons (_, hier) _ -> return hier

addHistory :: MetaInfo -> Hierarchy -> History -> History
addHistory meta hier hist = refHistory (Cons (meta, hier) hist)

revisionsBefore :: Maybe Int -> Ref HistoryTag -> StoreOp [Ref HistoryTag]
revisionsBefore limit ref =
  fmap reverse (revisionsBefore' limit ref)
 where
  revisionsBefore' :: Maybe Int -> Ref HistoryTag -> StoreOp [Ref HistoryTag]
  revisionsBefore' (Just 0) _ = return []
  revisionsBefore' limit ref = do
    ref' <- loadHistory ref
    case ref' of
      Nothing -> return []
      Just (_, _, next) -> (ref :) <$> revisionsBefore' (fmap (flip (-) 1) limit) next

-- from < x <= to
revisionsBetween :: Ref HistoryTag -> Ref HistoryTag -> StoreOp (Maybe [Ref HistoryTag])
revisionsBetween from to = do
  fmap (fmap reverse) (revisionsBetween' from to)
 where
  revisionsBetween' :: Ref HistoryTag -> Ref HistoryTag -> StoreOp (Maybe [Ref HistoryTag])
  revisionsBetween' from to = do
    hist <- derefHistory (makeHistoryTree to)
    case hist of
      Nil -> return Nothing
      Cons x (Mu (Left xs)) ->
        if xs == from then
          return (Just [to])
         else do
          revisions <- revisionsBetween' from xs
          return (fmap (to :) revisions)

hierarchyFromRevision :: Ref HistoryTag -> StoreOp Hierarchy
hierarchyFromRevision = lastHierarchy . makeHistoryTree

materializedView :: Path -> Hierarchy -> StoreOp (Hierarchy, JSON)
materializedView path hier = do
  z <- makeHierarchyZipper hier
  (z', json) <- getJSON z
  (z'', jsons) <- foldM (\(z, l) label -> do
    z' <- down label z
    (z'', json) <- getJSON z'
    return (z'', json:l)) (z', [json]) (pathToList path)
  return (solidifyHierarchyZipper z'', foldl1 deepMerge $ reverse jsons)

nextMaterializedView :: Ref HistoryTag -> Path -> StoreOp (Maybe (JSON, Ref HistoryTag))
nextMaterializedView ref path = do
  head <- getHeadBlockIfEq ref
  revisions <- revisionsBetween ref head
  case revisions of
    Nothing -> do
      b <- isJust <$> revisionsBetween head ref
      if b then do
        -- wait for head to change
        getHeadBlockIfEq head
        -- try again
        nextMaterializedView ref path
       else
        return Nothing
    Just revisions' -> do
      hier <- hierarchyFromRevision ref
      (_, json) <- materializedView path hier
      result <- foldM (\result revision ->
        case result of
          Just _ ->
            return result
          Nothing -> do
            hier <- hierarchyFromRevision revision
            (_, json') <- materializedView path hier
            if json == json' then
              return Nothing
             else
              return (Just (json', revision))) Nothing revisions'
      case result of
        Nothing -> nextMaterializedView head path
        Just _ -> return result

loadHistory :: Ref HistoryTag -> StoreOp (Maybe (MetaInfo, Ref HierarchyTag, Ref HistoryTag))
loadHistory hist = do
  HistoryNode hist' <- load hist
  case hist' of
    Nil -> return Nothing
    Cons (meta, hier) hist'' -> return (Just (meta, hier, hist''))

loadHierarchy :: Ref HierarchyTag -> StoreOp (JSON, HashMap Text (Ref HierarchyTag))
loadHierarchy ref = do
  HierarchyNode (TreeNode table jsonref) <- load ref
  JSONData json <- load jsonref
  return (json, table)

findActive :: UTCTime -> StoreOp (Ref HistoryTag)
findActive ts = do
  head <- getHead
  findActive' head
 where
  findActive' :: Ref HistoryTag -> StoreOp (Ref HistoryTag)
  findActive' ref = do
    dat <- loadHistory ref
    case dat of
      Nothing -> return ref
      Just (MetaInfo ts' _ _, _, next) ->
        if ts > ts' then
          return ref
        else
          findActive' next

data AtLeastOneOf a b = OnlyLeft a | OnlyRight b | Both a b

unionAB :: (Hashable k, Ord k) => HashMap k a -> HashMap k b -> HashMap k (AtLeastOneOf a b)
unionAB a b =
  HashMap.unionWith
    (\(OnlyLeft x) (OnlyRight y) -> Both x y)
    (HashMap.map OnlyLeft a)
    (HashMap.map OnlyRight b)

collapse :: Ref HierarchyTag -> StoreOp [(Path, JSON)]
collapse ref = do
  (json, table) <- loadHierarchy ref
  let changes = if json == Aeson.object [] then [] else [(mempty, json)]
  l <- mapM (\(k, v) -> do
    dat <- collapse v
    return (map (\(p, json) -> (listToPath [k] `mappend` p, json)) dat)) (HashMap.toList table)
  return (changes ++ concat l)

diff :: Ref HierarchyTag -> Ref HierarchyTag -> StoreOp [(Path, JSON, JSON)]
diff x y =
  if x == y then
    return []
  else do
    (xJson, xMap) <- loadHierarchy x
    (yJson, yMap) <- loadHierarchy y
    let changes = if xJson == yJson then [] else [(mempty, xJson, yJson)]
    let l = HashMap.toList (unionAB xMap yMap)
    l' <- mapM (\(k, x) ->
      case x of
        OnlyLeft x -> do
          l <- collapse x
          return (map (\(path, json) -> (path, json, Aeson.object [])) l)
        OnlyRight x -> do
          l <- collapse x
          return (map (\(path, json) -> (path, Aeson.object [], json)) l)
        Both x y -> do
          changes <- diff x y
          return (map (\(a, b, c) -> (listToPath [k] `mappend` a, b, c)) changes)) l
    return (changes ++ concat l')

loadInfo :: Ref HistoryTag -> StoreOp (Maybe (MetaInfo, Ref HistoryTag, [(Path, JSON, JSON)]))
loadInfo ref = do
  x <- loadHistory ref
  case x of
    Nothing -> return Nothing
    Just (meta, hier, prev) -> do
      y <- loadHistory prev
      case y of
        Nothing -> do
          d <- collapse hier
          return (Just (meta, prev, map (\(x, y) -> (x, Aeson.object [], y)) d))
        Just (_, hier', _) -> do
          d <- diff hier' hier
          return (Just (meta, prev, d))

updateHierarchy :: MetaInfo -> Path -> JSON -> Ref HistoryTag -> StoreOp (Maybe (Ref HistoryTag))
updateHierarchy meta path json ref = do
  head <- getHead
  refTree <- getHierarchy ref
  headTree <- getHierarchy head
  equivalent <- check headTree refTree path
  if equivalent then do
    headTree' <- applyUpdate path json headTree
    head' <- createHistory meta headTree' (makeHistoryTree head)
    success <- updateHead head head'
    if success then
      return (Just head')
     else
      updateHierarchy meta path json ref
   else
    return Nothing
 where
  getHierarchy :: Ref HistoryTag -> StoreOp (Maybe (Ref HierarchyTag))
  getHierarchy = fmap (fmap (\(_, hier, _) -> hier)) . loadHistory

  check :: Maybe (Ref HierarchyTag) -> Maybe (Ref HierarchyTag) -> Path -> StoreOp Bool
  check a b path =
    if a == b then
      return True
    else
      case (a, b, path) of
        (_, _, Path []) -> return False
        (Just a', Just b', Path (p:ps)) -> do
          HierarchyNode (TreeNode aTable aJson) <- load a'
          HierarchyNode (TreeNode bTable bJson) <- load b'
          if aJson == bJson then
            check (HashMap.lookup p aTable) (HashMap.lookup p bTable) (Path ps)
           else
            return False
        (Just a', Nothing, _) -> check b a path
        (Nothing, Just b', Path (p:ps)) -> do
          HierarchyNode (TreeNode bTable bJson) <- load b'
          if emptyObject bJson then
            check Nothing (HashMap.lookup p bTable) (Path ps)
           else
            return False

  applyUpdate :: Path -> JSON -> Maybe (Ref HierarchyTag) -> StoreOp Hierarchy
  applyUpdate path json hier = do
    let hier' =
          case hier of
            Nothing -> emptyHierarchy
            Just hier' -> makeHierarchyTree hier'
    z <- makeHierarchyZipper hier'
    z' <- followPath path z
    let z'' = setJSON' (refJSON json) z'
    return $ solidifyHierarchyZipper z''

  createHistory :: MetaInfo -> Hierarchy -> History -> StoreOp (Ref HistoryTag)
  createHistory meta hier hist = storeHistory (addHistory meta hier hist)
