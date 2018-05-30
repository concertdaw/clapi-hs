{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# OPTIONS_HADDOCK prune #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE QuasiQuotes #-}
{-# LANGUAGE PatternSynonyms #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}
{-# LANGUAGE FlexibleContexts #-}

module Clapi.Valuespace
  ( Valuespace, vsTree, vsTyDefs
  , baseValuespace
  , vsLookupDef, valuespaceGet, getLiberty
  , apiNs, rootTypeName, apiTypeName, dnSeg
  , processToRelayProviderDigest, processToRelayClientDigest
  , validateVs, unsafeValidateVs
  , vsRelinquish, ValidationErr(..)
  ) where

import Prelude hiding (fail)
import Control.Applicative ((<|>))
import Control.Monad (unless, liftM2)
import Control.Monad.Fail (MonadFail(..))
import Data.Bifunctor (first)
import Data.Either (lefts)
import Data.Int
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Map.Strict.Merge
  (merge, preserveMissing, dropMissing, zipWithMaybeMatched)
import Data.Maybe (fromJust, mapMaybe)
import Data.Monoid ((<>))
import Data.Set (Set)
import qualified Data.Set as Set
import Data.Text (Text)
import qualified Data.Text as Text
import Data.Word

import qualified Data.Map.Mol as Mol
import Data.Map.Mos (Mos)
import qualified Data.Map.Mos as Mos

import Data.Maybe.Clapi (note)

import Clapi.TH
import Clapi.Util (strictZipWith, fmtStrictZipError)
import Clapi.Tree (RoseTree(..), RoseTreeNode, treeInsert, treeChildren, TpId, RoseTreeNodeType(..))
import qualified Clapi.Tree as Tree
import Clapi.Types (WireValue(..))
import Clapi.Types.Base (InterpolationLimit(ILUninterpolated))
import Clapi.Types.AssocList
  ( alKeysSet, alValues, alFromMap, alSingleton, alEmpty
  , unsafeMkAssocList, alMapKeys, alFmapWithKey, alToMap)
import Clapi.Types.Definitions
  ( Definition(..), Liberty(..), TupleDefinition(..)
  , StructDefinition(..), defDispatch, childLibertyFor
  , childTypeFor)
import Clapi.Types.Digests
  ( DefOp(..), isUndef, ContainerOps, DataChange(..), isRemove, DataDigest
  , TrpDigest(..), trpdRemovedPaths)
import Clapi.Types.Messages (ErrorIndex(..))
import Clapi.Types.Path
  (Seg, Path, pattern (:/), pattern Root, pattern (:</), TypeName(..))
import qualified Clapi.Types.Path as Path
import Clapi.Types.Tree (TreeType(..), unbounded)
import Clapi.Validator (validate, extractTypeAssertions)
import qualified Clapi.Types.Dkmap as Dkmap

type DefMap def = Map Seg (Map Seg def)
type TypeAssignmentMap = Mos.Dependencies Path TypeName
type Referer = Path
type Referee = Path
type Xrefs = Map Referee (Map Referer (Maybe (Set TpId)))

data Valuespace = Valuespace
  { vsTree :: RoseTree [WireValue]
  , vsTyDefs :: DefMap Definition
  , vsTyAssns :: TypeAssignmentMap
  , vsXrefs :: Xrefs
  } deriving (Eq, Show)

removeTamSubtree :: TypeAssignmentMap -> Path -> TypeAssignmentMap
removeTamSubtree tam p = Mos.filterDependencies (not . flip Path.isChildOf p) tam

removeXrefs :: Referer -> Xrefs -> Xrefs
removeXrefs referer = fmap (Map.delete referer)

filterXrefs :: (Referer -> Bool) -> Xrefs -> Xrefs
filterXrefs f = fmap (Map.filterWithKey $ \k _ -> f k)

removeXrefsTps :: Referer -> Set TpId -> Xrefs -> Xrefs
removeXrefsTps referer tpids = fmap (Map.update updateTpMap referer)
  where
    updateTpMap Nothing = Just Nothing
    updateTpMap (Just tpSet) = let tpSet' = Set.difference tpSet tpids in
      if null tpSet' then Nothing else Just $ Just tpSet'

apiNs :: Seg
apiNs = [segq|api|]

rootTypeName, apiTypeName :: TypeName
rootTypeName = TypeName apiNs [segq|root|]
apiTypeName = TypeName apiNs apiNs

apiDef :: StructDefinition
apiDef = StructDefinition "Information about CLAPI itself" $
  alSingleton [segq|version|] (TypeName apiNs [segq|version|], Cannot)

versionDef :: TupleDefinition
versionDef = TupleDefinition "The version of CLAPI" (unsafeMkAssocList
  [ ([segq|major|], TtWord32 unbounded)
  , ([segq|minor|], TtWord32 unbounded)
  , ([segq|revision|], TtInt32 unbounded)
  ]) ILUninterpolated

dnSeg :: Seg
dnSeg = [segq|display_name|]

displayNameDef :: TupleDefinition
displayNameDef = TupleDefinition
  "A human-readable name for a struct or array element"
  (alSingleton [segq|name|] $ TtString "") ILUninterpolated

-- | Fully revalidates the given Valuespace and throws an error if there are any
--   validation issues.
unsafeValidateVs :: Valuespace -> Valuespace
unsafeValidateVs vs = either (error . show) snd $ validateVs allTainted vs
  where
    allTainted = Map.fromList $ fmap (,Nothing) $ Tree.treePaths Root $
      vsTree vs

baseValuespace :: Valuespace
baseValuespace = unsafeValidateVs $ Valuespace baseTree baseDefs baseTas mempty
  where
    vseg = [segq|version|]
    version = RtConstData Nothing
      [WireValue @Word32 0, WireValue @Word32 1, WireValue @Int32 (-1023)]
    baseTree =
      treeInsert Nothing (Root :/ apiNs :/ vseg) version Tree.RtEmpty
    baseDefs = Map.singleton apiNs $ Map.fromList
      [ (apiNs, StructDef apiDef)
      , (vseg, TupleDef versionDef)
      , (dnSeg, TupleDef displayNameDef)
      ]
    baseTas = Mos.dependenciesFromMap $ Map.singleton Root rootTypeName

lookupDef :: MonadFail m => TypeName -> DefMap Definition -> m Definition
lookupDef tn@(TypeName ns s) defs = note "Missing def" $
    (Map.lookup ns defs >>= Map.lookup s) <|>
    if tn == rootTypeName then Just rootDef else Nothing
  where
    -- NB: We generate the root def on the fly when people ask about it
    rootDef = StructDef $ StructDefinition "root def doc" $ alFromMap $
      Map.mapWithKey (\k _ -> (TypeName k k, Cannot)) defs

vsLookupDef :: MonadFail m => TypeName -> Valuespace -> m Definition
vsLookupDef tn vs = lookupDef tn $ vsTyDefs vs

lookupTypeName :: MonadFail m => Path -> TypeAssignmentMap -> m TypeName
lookupTypeName p = note "Type name not found" . Mos.getDependency p

defForPath :: MonadFail m => Path -> Valuespace -> m Definition
defForPath p (Valuespace _ defs tas _) =
  lookupTypeName p tas >>= flip lookupDef defs

getLiberty :: MonadFail m => Path -> Valuespace -> m Liberty
getLiberty path vs = case path of
  Root :/ _ -> return Cannot
  p :/ s -> defForPath p vs >>= defDispatch (flip childLibertyFor s)
  _ -> return Cannot

valuespaceGet
  :: MonadFail m => Path -> Valuespace
  -> m (Definition, TypeName, Liberty, RoseTreeNode [WireValue])
valuespaceGet p vs@(Valuespace tree defs tas _) = do
    rtn <- note "Path not found" $ Tree.treeLookupNode p tree
    tn <- lookupTypeName p tas
    def <- lookupDef tn defs
    lib <- getLiberty p vs
    return (def, tn, lib, rtn)

type RefTypeClaims = Mos TypeName Referee
type TypeClaimsByPath =
  Map Referer (Either RefTypeClaims (Map TpId RefTypeClaims))

partitionXrefs :: Xrefs -> TypeClaimsByPath -> (Xrefs, Xrefs)
partitionXrefs oldXrefs claims = (preExistingXrefs, newXrefs)
  where
    mosValues :: (Ord k, Ord v) => Mos k v -> Set v
    mosValues = foldl Set.union mempty . Map.elems
    newXrefs = Map.foldlWithKey asXref mempty claims
    asXref acc referer claimEither = case claimEither of
      Left rtcs -> foldl (addReferer referer) acc $ mosValues rtcs
      Right rtcm -> Map.foldlWithKey (addRefererWithTpid referer) acc rtcm
    addReferer referer acc referee = Map.alter
      (Just . Map.insert referer Nothing . maybe mempty id) referee acc
    addRefererWithTpid referer acc tpid rtcs =
      foldl (addRefererWithTpid' referer tpid) acc $ mosValues rtcs
    addRefererWithTpid' referer tpid acc referee = Map.alter
      (Just . Map.alter
        (Just . Just . maybe (Set.singleton tpid) (Set.insert tpid) .
          maybe Nothing id)
        referer . maybe mempty id)
      referee
      acc
    preExistingXrefs = Map.foldlWithKey removeOldXrefs oldXrefs claims
    removeOldXrefs acc referrer claimEither = case claimEither of
      Left _ -> removeXrefs referrer acc
      Right rtcm -> removeXrefsTps referrer (Map.keysSet rtcm) acc

xrefUnion :: Xrefs -> Xrefs -> Xrefs
xrefUnion = Map.unionWith $ Map.unionWith $ liftM2 Set.union

checkRefClaims
  :: TypeAssignmentMap -> Map Path (Either RefTypeClaims (Map TpId RefTypeClaims)) -> Either (Map (ErrorIndex TypeName) [ValidationErr]) ()
checkRefClaims tyAssns = smashErrMap . Map.mapWithKey checkRefsAtPath
  where
    errIf m = unless (null m) $ Left m
    smashErrMap = errIf . Mol.unions . lefts . Map.elems
    checkRefsAtPath
      :: Path
      -> Either RefTypeClaims (Map TpId RefTypeClaims)
      -> Either (Map (ErrorIndex TypeName) [ValidationErr]) ()
    checkRefsAtPath path refClaims =
      let
        doCheck eidx = first (Map.singleton eidx . pure @[]) .
          mapM_ (uncurry checkRef) . Mos.toList
      in
        either
          (doCheck $ PathError path)
          (smashErrMap .
           Map.mapWithKey (\tpid -> doCheck (TimePointError path tpid)))
          refClaims
    checkRef :: TypeName -> Path -> Either ValidationErr ()
    checkRef requiredTn refP = case lookupTypeName refP tyAssns of
        Nothing -> Left $ RefTargetNotFound refP
        Just actualTn -> if actualTn == requiredTn
            then Right ()
            else Left $ RefTargetTypeErr refP actualTn requiredTn

validateVs
  :: Map Path (Maybe (Set TpId)) -> Valuespace
  -> Either (Map (ErrorIndex TypeName) [ValidationErr]) (Map Path TypeName, Valuespace)
validateVs t v = do
    (newTypeAssns, refClaims, vs) <-
      -- As the root type is dynamic we always treat it as if it has been
      -- redefined:
      inner mempty mempty (Map.insert Root Nothing t) v
    checkRefClaims (vsTyAssns vs) refClaims
    let (preExistingXrefs, newXrefs) = partitionXrefs (vsXrefs vs) refClaims
    let existingXrefErrs = validateExistingXrefs preExistingXrefs newTypeAssns
    unless (null existingXrefErrs) $ Left existingXrefErrs
    let vs' = vs {vsXrefs = xrefUnion preExistingXrefs newXrefs}
    return (newTypeAssns, vs')
  where
    errP p = first (Map.singleton (PathError p) . pure . GenericErr)
    tLook p = maybe (Left $ Map.singleton (PathError p) [ProgrammingErr "Missing RTN"]) Right .
      Tree.treeLookup p
    changed :: Eq a => a -> a -> Maybe a
    changed a1 a2 | a1 == a2 = Nothing
                  | otherwise = Just a2

    -- FIXME: this currently bails earlier than it could in light of validation
    -- errors. If we can't figure out the type of children in order to recurse,
    -- then we should probably stop, but if we just encouter bad data, we should
    -- probably just capture the error and continue.
    inner
      :: Map Path TypeName
      -> TypeClaimsByPath
      -> Map Path (Maybe (Set TpId)) -> Valuespace
      -> Either (Map (ErrorIndex TypeName) [ValidationErr])
           (Map Path TypeName, TypeClaimsByPath, Valuespace)
    inner newTas newRefClaims tainted vs@(Valuespace tree _ oldTyAssns _) =
      case Map.toAscList tainted of
        [] -> return (newTas, newRefClaims, vs)
        ((path, invalidatedTps):_) ->
          case lookupTypeName path (vsTyAssns vs) of
            -- When we don't have the type (and haven't bailed out) we know the
            -- parent was implictly added by the rose tree and thus doesn't
            -- appear in the taints, but because it was changed it should be
            -- counted as such.
            Nothing -> case path of
              (parentPath :/ _) -> inner
                newTas newRefClaims (Map.insert parentPath Nothing tainted)
                vs
              _ -> Left $ Map.singleton GlobalError
                [GenericErr "Attempted to taint parent of root"]
            Just tn -> do
              def <- errP path $ vsLookupDef tn vs
              rtn <- tLook path tree
              case validateRoseTreeNode def rtn invalidatedTps of
                Left validationErrs -> if null emptyArrays
                    then Left $ Map.singleton (PathError path) validationErrs
                    else inner newTas' newRefClaims tainted' vs'
                  where
                    emptyArrays = mapMaybe mHandlable validationErrs
                    isEmptyContainer d = case d of
                        ArrayDef _ -> True
                        StructDef (StructDefinition _ defKids) -> defKids == alEmpty
                        _ -> False
                    mHandlable ve = case ve of
                        MissingChild name -> do
                          ctn <- defDispatch (childTypeFor name) def
                          cdef <- vsLookupDef ctn vs
                          if isEmptyContainer cdef
                            then Just (name, ctn)
                            else Nothing
                        _ -> Nothing
                    qEmptyArrays = first (path :/) <$> emptyArrays
                    newTas' = newTas <> Map.fromList qEmptyArrays
                    tainted' = Map.fromList (fmap (const Nothing) <$> qEmptyArrays) <> tainted
                    att = Nothing  -- FIXME: who is this attributed to?
                    insertEmpty childPath = treeInsert att childPath (RtContainer alEmpty)
                    vs' = vs {vsTree = foldl (\acc (cp, _) -> insertEmpty cp acc) tree qEmptyArrays}
                Right pathRefClaims -> inner
                      (newTas <> changedChildPaths)
                      (Map.insert path pathRefClaims newRefClaims)
                      (Map.delete path $
                         tainted <> fmap (const Nothing) changedChildPaths)
                      (vs {vsTyAssns = Mos.setDependencies changedChildPaths oldTyAssns})
                  where
                    oldChildTypes = Map.mapMaybe id $ alToMap $ alFmapWithKey
                      (\name _ -> Mos.getDependency (path :/ name) oldTyAssns) $
                      treeChildren rtn
                    newChildTypes = Map.mapMaybe id $ alToMap $ alFmapWithKey
                      (\name _ -> defDispatch (childTypeFor name) def) $
                      treeChildren rtn
                    changedChildTypes = merge
                      dropMissing preserveMissing
                      (zipWithMaybeMatched $ const changed)
                      oldChildTypes newChildTypes
                    changedChildPaths = Map.mapKeys (path :/) changedChildTypes

opsTouched :: ContainerOps -> DataDigest -> Map Path (Maybe (Set TpId))
opsTouched cops dd = fmap (const Nothing) cops <> fmap classifyDc (alToMap dd)
  where
    classifyDc :: DataChange -> Maybe (Set TpId)
    classifyDc (ConstChange {}) = Nothing
    classifyDc (TimeChange m) = Just $ Map.keysSet m

processToRelayProviderDigest
  :: TrpDigest -> Valuespace
  -> Either (Map (ErrorIndex TypeName) [Text]) (Map Path TypeName, Valuespace)
processToRelayProviderDigest trpd vs =
  let
    ns = trpdNamespace trpd
    tas = foldl removeTamSubtree (vsTyAssns vs) $ trpdRemovedPaths trpd
    redefdPaths = mconcat $
      fmap (\tn -> Mos.getDependants (TypeName ns tn) tas) $ Map.keys $
      trpdDefinitions trpd
    qData = fromJust $ alMapKeys (ns :</) $ trpdData trpd
    qCops = Map.mapKeys (ns :</) $ trpdContainerOps trpd
    updatedPaths = opsTouched qCops qData
    tpRemovals :: DataChange -> Set TpId
    tpRemovals (ConstChange {})= mempty
    tpRemovals (TimeChange m) = Map.keysSet $ Map.filter (isRemove . snd) m
    xrefs' = Map.foldlWithKey' (\x r ts -> removeXrefsTps r ts x) (vsXrefs vs) $
      fmap tpRemovals $ alToMap qData
    (undefOps, defOps) = Map.partition isUndef (trpdDefinitions trpd)
    defs' =
      let
        newDefs = odDef <$> defOps
        updateNsDefs Nothing = Just newDefs
        updateNsDefs (Just existingDefs) = Just $ Map.union newDefs $
          Map.withoutKeys existingDefs (Map.keysSet undefOps)
      in
        Map.alter updateNsDefs ns (vsTyDefs vs)
    (updateErrs, tree') = Tree.updateTreeWithDigest qCops qData (vsTree vs)
  in do
    unless (null updateErrs) $ Left $ Map.mapKeys PathError updateErrs
    (updatedTypes, vs') <- first (fmap $ fmap $ Text.pack . show) $ validateVs
      (Map.fromSet (const Nothing) redefdPaths <> updatedPaths) $
      Valuespace tree' defs' tas xrefs'
    return (updatedTypes, vs')

validatePath :: Valuespace -> Path -> Maybe (Set TpId) -> Either [ValidationErr] (Either RefTypeClaims (Map TpId RefTypeClaims))
validatePath vs p mTpids = do
    def <- first pure $ fromMonadFail $ defForPath p vs
    t <- maybe (Left [ProgrammingErr "Tainted but missing"]) Right $ Tree.treeLookup p $ vsTree vs
    validateRoseTreeNode def t mTpids

processToRelayClientDigest
  :: ContainerOps -> DataDigest -> Valuespace -> Map (ErrorIndex TypeName) [ValidationErr]
processToRelayClientDigest reords dd vs =
  let
    (updateErrs, tree') = Tree.updateTreeWithDigest reords dd (vsTree vs)
    touched = opsTouched reords dd
    (tas', newPaths) = fillTyAssns (vsTyDefs vs) (vsTyAssns vs) (Map.keys touched)
    vs' = vs {vsTree = tree', vsTyAssns = tas'}
    touchedLiberties = Map.mapWithKey (\k _ -> getLiberty k vs') touched
    cannotErrs = const [LibertyErr "Touched a cannot"]
      <$> Map.filter (== Just Cannot) touchedLiberties
    mustErrs = const [LibertyErr "Failed to provide a value for must"] <$>
      ( Map.filter (== Just Must)
      $ Map.fromSet (flip getLiberty vs') $ Set.fromList
      $ Tree.treeMissing tree')
    (validationErrs, refClaims) = Map.mapEitherWithKey (validatePath vs') touched
    refErrs = either id (const mempty) $ checkRefClaims (vsTyAssns vs') refClaims
  in
    foldl (Map.unionWith (<>)) refErrs $ fmap (Map.mapKeys PathError)
      [fmap (fmap $ GenericErr . Text.unpack) updateErrs, validationErrs, cannotErrs, mustErrs]

fillTyAssns
  :: DefMap Definition -> TypeAssignmentMap -> [Path]
  -> (TypeAssignmentMap, Set Path)
fillTyAssns defs = inner mempty
  where
    inner freshlyAssigned tam paths = case paths of
        [] -> (tam, freshlyAssigned)
        (p : ps) -> case Mos.getDependency p tam of
            Just _ -> inner freshlyAssigned tam ps
            Nothing -> let newAssns = infer p $ fst tam in
                inner (freshlyAssigned <> Map.keysSet newAssns) (Mos.setDependencies newAssns tam) ps
    infer p tm = case Path.splitTail p of
        Nothing -> error "Attempted to infer root in fillTyAssns"
        Just (pp, cSeg) ->
          let
            (mptn, tm') = case Map.lookup pp tm of
                Just tn -> (Just tn, tm)
                Nothing -> let ptm = infer pp tm in
                    (Map.lookup pp ptm, tm <> ptm)
          in case mptn >>= flip lookupDef defs >>= defDispatch (childTypeFor cSeg) of
            Just tn -> Map.insert p tn tm'
            Nothing -> tm'

data ValidationErr
  = GenericErr String
  | ProgrammingErr String
  | BadNodeType {vebntExpected :: RoseTreeNodeType, vebntActual :: RoseTreeNodeType}
  | MissingChild Seg
  | ExtraChild Seg
  | RefTargetNotFound Path
  | RefTargetTypeErr {veRttePath :: Path, veRtteExpectedType :: TypeName, veRtteTargetType :: TypeName}
  | LibertyErr String
  deriving (Show)

fromMonadFail :: Either String a -> Either ValidationErr a
fromMonadFail mf = case mf of
    Left msg -> Left $ GenericErr msg
    Right a -> Right a

defNodeType :: Definition -> RoseTreeNodeType
defNodeType def = case def of
    StructDef _ -> RtntContainer
    ArrayDef _ -> RtntContainer
    TupleDef (TupleDefinition _ _ interpLim) -> case interpLim of
        ILUninterpolated -> RtntConstData
        _ -> RtntDataSeries

validateRoseTreeNode
  :: Definition -> RoseTree [WireValue] -> Maybe (Set TpId)
  -> Either [ValidationErr] (Either RefTypeClaims (Map TpId RefTypeClaims))
validateRoseTreeNode def t invalidatedTps = case t of
    RtEmpty -> tyErr
    RtConstData _ wvs -> case def of
      TupleDef (TupleDefinition _ alTreeTypes _) -> first pure $ fromMonadFail $
        Left <$> validateWireValues (alValues alTreeTypes) wvs
      _ -> tyErr
    RtDataSeries m -> case def of
      TupleDef (TupleDefinition _ alTreeTypes _) ->
        let toValidate = case invalidatedTps of
              Nothing -> Dkmap.valueMap m
              Just tpids -> Map.restrictKeys (Dkmap.valueMap m) tpids
        in first pure $ fromMonadFail $
          fmap Right $
          mapM (validateWireValues (alValues alTreeTypes) . snd . snd) toValidate
      _ -> tyErr
    RtContainer alCont -> case def of
      TupleDef _ -> tyErr
      StructDef (StructDefinition _ alDef) -> if defSegs == rtnSegs
          then return $ Left mempty
          else Left $ fmap MissingChild missingSegs ++ fmap ExtraChild extraSegs
        where
          defSegs = alKeysSet alDef
          rtnSegs = alKeysSet alCont
          missingSegs = Set.toList $ Set.difference defSegs rtnSegs
          extraSegs = Set.toList $ Set.difference rtnSegs defSegs
      ArrayDef _ -> return $ Left mempty
  where
    tyErr = Left [BadNodeType (defNodeType def) (Tree.rtType t)]

validateWireValues
  :: MonadFail m => [TreeType] -> [WireValue] -> m RefTypeClaims
validateWireValues tts wvs =
    (fmtStrictZipError "types" "values" $ strictZipWith vr tts wvs)
    >>= sequence >>= return . Mos.fromList . mconcat
  where
    vr tt wv = validate tt wv >> extractTypeAssertions tt wv

-- FIXME: The VS you get back from this can be invalid WRT refs/inter NS types
vsRelinquish :: Seg -> Valuespace -> Valuespace
vsRelinquish ns (Valuespace tree defs tas xrefs) =
  let
    nsp = Root :/ ns
  in
    Valuespace
      (Tree.treeDelete nsp tree)
      (Map.delete ns defs)
      (Mos.filterDeps
       (\p (TypeName ns' _) -> not $ p `Path.isChildOf` nsp || ns == ns') tas)
      (filterXrefs (\p -> not (p `Path.isChildOf` nsp)) xrefs)

validateExistingXrefs
  :: Xrefs -> Map Path TypeName -> Map (ErrorIndex TypeName) [ValidationErr]
validateExistingXrefs xrs newTas =
  let
    retypedPaths = Map.keysSet newTas
    invalidated = Map.restrictKeys xrs retypedPaths
    errText referee = [GenericErr $ "Ref target changed type: " ++ Text.unpack (Path.toText referee)]
    refererErrors referee acc referer mTpids = case mTpids of
      Nothing -> Map.insert (PathError referer) (errText referee) acc
      Just tpids -> Set.foldl
        (\acc' tpid ->
           Map.insert (TimePointError referer tpid) (errText referee) acc')
        acc tpids
    refereeErrs acc referee refererMap =
      Map.foldlWithKey (refererErrors referee) acc refererMap
  in
    Map.foldlWithKey refereeErrs mempty invalidated
