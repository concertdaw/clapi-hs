{-# LANGUAGE
    DataKinds
  , DeriveFoldable
  , DeriveFunctor
  , TemplateHaskell
  , TypeFamilies
#-}

module Clapi.Tree where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad.State (State, get, put, modify, runState)
import Data.Functor.Const (Const(..))
import Data.Functor.Identity (Identity(..))
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Monoid
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word

import Clapi.Types
  (Time, Interpolation(..), Attributee, WireValue)
import Clapi.Types.AssocList
  ( AssocList, unAssocList, alEmpty, alFmapWithKey, alSingleton, alAlterF
  , alKeys, alToMap, alPickFromMap)
import Clapi.Types.Dkmap (Dkmap)
import qualified Clapi.Types.Dkmap as Dkmap
import Clapi.Types.Path (
    Seg, Path, pattern Root, pattern (:/), AbsRel(..), splitHead)
import Clapi.Types.Digests
  ( DataDigest, ContainerOps, DataChange(..), TimeSeriesDataOp(..))
import Clapi.Types.SequenceOps (reorderUniqList)

type TpId = Word32

type TimePoint a = (Interpolation, a)
type Attributed a = (Maybe Attributee, a)
type TimeSeries a = Dkmap TpId Time (Attributed (TimePoint a))

data RoseTree a
  = RtEmpty
  | RtContainer (AssocList Seg (Maybe Attributee, RoseTree a))
  | RtConstData (Maybe Attributee) a
  | RtDataSeries (TimeSeries a)
  deriving (Show, Eq, Functor, Foldable)

treeMissing :: RoseTree a -> [Path ar]
treeMissing = inner Root
  where
    inner p RtEmpty = [p]
    inner p (RtContainer al) =
      mconcat $ (\(s, (_, rt)) -> inner (p :/ s) rt) <$> unAssocList al
    inner _ _ = []

treeChildren :: RoseTree a -> AssocList Seg (RoseTree a)
treeChildren t = case t of
    RtContainer al -> snd <$> al
    _ -> alEmpty

-- FIXME: define in terms of treeChildren (if even used)
treePaths :: Path ar -> RoseTree a -> [Path ar]
treePaths p t = case t of
  RtEmpty -> [p]
  RtConstData _ _ -> [p]
  RtDataSeries _ -> [p]
  RtContainer al ->
    p : (mconcat $ (\(s, (_, t')) -> treePaths (p :/ s) t') <$> unAssocList al)

treeApplyReorderings
  :: MonadFail m
  => Map Seg (Maybe Attributee, Maybe Seg) -> RoseTree a -> m (RoseTree a)
treeApplyReorderings contOps (RtContainer children) =
  let
    attMap = fst <$> contOps
    reattribute s (oldMa, rt) = (Map.findWithDefault oldMa s attMap, rt)
  in
    RtContainer . alFmapWithKey reattribute . alPickFromMap (alToMap children)
    <$> (reorderUniqList (snd <$> contOps) $ alKeys children)
treeApplyReorderings _ _ = fail "Not a container"

treeConstSet :: Maybe Attributee -> a -> RoseTree a -> RoseTree a
treeConstSet att a _ = RtConstData att a

treeSet
  :: MonadFail m => TpId -> Time -> a -> Interpolation -> Maybe Attributee
  -> RoseTree a -> m (RoseTree a)
treeSet tpId t a i att rt =
  let
    ts' = case rt of
      RtDataSeries ts -> ts
      _ -> Dkmap.empty
  in
    RtDataSeries <$> Dkmap.set tpId t (att, (i, a)) ts'


treeRemove :: MonadFail m => TpId -> RoseTree a -> m (RoseTree a)
treeRemove tpId rt = case rt of
  RtDataSeries ts -> RtDataSeries <$> Dkmap.deleteK0' tpId ts
  _ -> fail "Not a time series"


treeLookup :: Path ar -> RoseTree a -> Maybe (RoseTree a)
treeLookup p = getConst . treeAlterF Nothing Const p

treeInsert :: Maybe Attributee -> Path ar -> RoseTree a -> RoseTree a -> RoseTree a
treeInsert att p t = treeAlter att (const $ Just t) p

treeDelete :: Path ar -> RoseTree a -> RoseTree a
treeDelete p = treeAlter Nothing (const Nothing) p

treeAdjust
  :: Maybe Attributee -> (RoseTree a -> RoseTree a) -> Path ar -> RoseTree a
  -> RoseTree a
treeAdjust att f p = runIdentity . treeAdjustF att (Identity . f) p

treeAdjustF
  :: Functor f => Maybe Attributee -> (RoseTree a -> f (RoseTree a)) -> Path ar
  -> RoseTree a -> f (RoseTree a)
treeAdjustF att f = treeAlterF att (fmap Just . f . maybe RtEmpty id)

treeAlter
  :: Maybe Attributee -> (Maybe (RoseTree a) -> Maybe (RoseTree a)) -> Path ar
  -> RoseTree a -> RoseTree a
treeAlter att f path = runIdentity . treeAlterF att (Identity . f) path

treeAlterF
  :: forall f a ar. Functor f
  => Maybe Attributee -> (Maybe (RoseTree a) -> f (Maybe (RoseTree a)))
  -> Path ar -> RoseTree a -> f (RoseTree a)
treeAlterF att f path tree = maybe tree snd <$> inner path (Just (att, tree))
  where
    inner
      :: Path arr -> Maybe (Maybe Attributee, RoseTree a)
      -> f (Maybe (Maybe Attributee, RoseTree a))
    inner p mat = case splitHead p of
      Nothing -> fmap (att,) <$> f (snd <$> mat)
      Just (s, cp) -> case mat of
        existingChild@(Just (att', t)) -> case t of
          RtContainer al -> Just . (att',) . RtContainer <$> alAlterF (inner cp) s al
          _ -> maybe existingChild Just <$> buildChildTree s cp
        Nothing -> buildChildTree s cp
    buildChildTree s p =
      fmap ((att,) . RtContainer . alSingleton s) <$> inner p Nothing

-- FIXME: Maybe reorder the args to reflect application order?
updateTreeWithDigest
  :: ContainerOps 'Abs -> DataDigest 'Abs -> RoseTree [WireValue]
  -> (Map (Path 'Abs) [Text], RoseTree [WireValue])
updateTreeWithDigest contOps dd = runState $ do
    errs <- alToMap <$> (sequence $ alFmapWithKey applyDd dd)
    errs' <- sequence $ Map.mapWithKey applyContOp contOps
    return $ Map.filter (not . null) $ Map.unionWith (<>) errs errs'
  where
    applyContOp
      :: Path 'Abs -> Map Seg (Maybe Attributee, Maybe Seg)
      -> State (RoseTree [WireValue]) [Text]
    applyContOp np m = do
      eRt <- treeAdjustF Nothing (treeApplyReorderings m) np <$> get
      either (return . pure . Text.pack) (\rt -> put rt >> return []) eRt
    applyDd
      :: Path 'Abs -> DataChange
      -> State (RoseTree [WireValue]) [Text]
    applyDd np dc = case dc of
      ConstChange att wv -> do
        modify $ treeAdjust Nothing (treeConstSet att wv) np
        return []
      TimeChange m -> mconcat <$> (mapM (applyTc np) $ Map.toList m)
    applyTc
      :: Path 'Abs
      -> (TpId, (Maybe Attributee, TimeSeriesDataOp))
      -> State (RoseTree [WireValue]) [Text]
    applyTc np (tpId, (att, op)) = case op of
      OpSet t wv i -> get >>=
        either (return . pure . Text.pack) (\vs -> put vs >> return [])
        . treeAdjustF Nothing (treeSet tpId t wv i att) np
      OpRemove -> get >>=
        either (return . pure . Text.pack) (\vs -> put vs >> return [])
        . treeAdjustF Nothing (treeRemove tpId) np

data RoseTreeNode a
  = RtnEmpty
  | RtnChildren (AssocList Seg (Maybe Attributee))
  | RtnConstData (Maybe Attributee) a
  | RtnDataSeries (TimeSeries a)
  deriving (Show, Eq)

roseTreeNode :: RoseTree a -> RoseTreeNode a
roseTreeNode t = case t of
  RtEmpty -> RtnEmpty
  RtContainer al -> RtnChildren $ fmap fst al
  RtConstData att a -> RtnConstData att a
  RtDataSeries m -> RtnDataSeries m

treeLookupNode :: Path ar -> RoseTree a -> Maybe (RoseTreeNode a)
treeLookupNode p = fmap roseTreeNode . treeLookup p

data RoseTreeNodeType
  = RtntEmpty
  | RtntContainer
  | RtntConstData
  | RtntDataSeries
  deriving Show

rtType :: RoseTree a -> RoseTreeNodeType
rtType rt = case rt of
  RtEmpty -> RtntEmpty
  RtContainer _ -> RtntContainer
  RtConstData _ _ -> RtntConstData
  RtDataSeries _ -> RtntDataSeries
