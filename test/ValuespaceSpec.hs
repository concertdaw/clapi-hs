{-# OPTIONS_GHC -Wno-orphans #-}
{-# LANGUAGE
    GADTs
  , OverloadedStrings
  , QuasiQuotes
  , StandaloneDeriving
#-}
module ValuespaceSpec where

import Test.Hspec

import Data.Maybe (fromJust)
import Data.Either (either, isRight, isLeft)
import Data.Tagged (Tagged(..))
import qualified Data.Map.Strict as Map
import qualified Data.Set as Set
import Control.Monad (void)
import Control.Monad.Fail (MonadFail)

import qualified Data.Map.Mol as Mol

import Clapi.TH
import qualified Clapi.Tree as Tree
import Clapi.Types.AssocList
  ( AssocList, alSingleton, alEmpty, alInsert, alFromList)
import Clapi.Types
  ( InterpolationLimit(ILUninterpolated)
  , someWv, WireType(..), someWireable
  , ttInt32, ttString, ttRef, unbounded, Editability(..)
  , tupleDef, structDef, arrayDef, DataErrorIndex(..)
  , Definition(..), SomeDefinition, withDefinition, DefName
  , TrDigest(..), DefOp(..), DataChange(..)
  , TrpDigest, TrcUpdateDigest, trcudEmpty)
import qualified Clapi.Types.Path as Path
import Clapi.Types.Path
  ( Path, pattern (:/), pattern Root, Seg, Namespace(..))
import Clapi.Valuespace
  ( Valuespace(..), validateVs, baseValuespace, processToRelayProviderDigest
  , processTrcUpdateDigest)
import Clapi.Tree (RoseTree(..), updateTreeWithDigest)
import Clapi.Types.SequenceOps (SequenceOp(..))

import Instances ()

-- | Fully revalidates the given Valuespace and throws an error if there are any
--   validation issues.
unsafeValidateVs :: Valuespace -> Valuespace
unsafeValidateVs vs = either (error . show) snd $ validateVs allTainted vs
  where
    allTainted = Map.fromList $ fmap (,Nothing) $ Tree.paths Root $ _vsTree vs


testS :: Seg
testS = [segq|test|]
testNs :: Namespace
testNs = Namespace testS

versionS :: Seg
versionS = [segq|version|]

testValuespace :: Valuespace
testValuespace = unsafeValidateVs $ (baseValuespace (Tagged testS) Editable)
  { _vsTyDefs = Map.fromList
      [ (Tagged testS, structDef "test root" $ alFromList
          [ (versionS, (Tagged versionS, ReadOnly))
          ])
      , (Tagged versionS, tupleDef
          "versioney" (alSingleton versionS $ ttInt32 unbounded) ILUninterpolated)
      ]
  , _vsTree = RtContainer $ alSingleton versionS
      (Nothing, RtConstData Nothing [someWv WtInt32 3])
  }

vsProviderErrorsOn :: Valuespace -> TrpDigest -> [Path] -> Expectation
vsProviderErrorsOn vs d ps = case (processToRelayProviderDigest d vs) of
    Left errMap -> Mol.keysSet errMap `shouldBe` Set.fromList (PathError <$> ps)
    Right _ -> fail "Did not get expected errors"

vsClientErrorsOn :: Valuespace -> TrcUpdateDigest -> [Path] -> Expectation
vsClientErrorsOn vs d ps = let (errMap, _) = processTrcUpdateDigest vs d in
  if (null errMap)
    then fail "Did not get expected errors"
    else Mol.keysSet errMap `shouldBe` Set.fromList (PathError <$> ps)

validVersionTypeChange :: Valuespace -> TrpDigest
validVersionTypeChange vs =
  let
    svd = tupleDef
      "Stringy" (alSingleton [segq|vstr|] $ ttString "pear")
      ILUninterpolated
    rootDef = redefTestRoot
      (alInsert versionS $ Tagged [segq|stringVersion|]) vs
  in Trpd
    testNs
    mempty
    (Map.fromList
      [ (Tagged [segq|stringVersion|], OpDefine svd)
      , (Tagged $ unNamespace testNs, OpDefine rootDef)
      ])
    (alSingleton [pathq|/version|]
      $ ConstChange Nothing [someWv WtString "pear"])
    mempty
    mempty

vsAppliesCleanly :: MonadFail m => TrpDigest -> Valuespace -> m Valuespace
vsAppliesCleanly d vs = either (fail . show) (return . snd) $
  processToRelayProviderDigest d vs

redefTestRoot
  :: (AssocList Seg DefName -> AssocList Seg DefName)
  -> Valuespace -> SomeDefinition
redefTestRoot f vs =
    structDef "Frigged by test" $ (, ReadOnly) <$> f currentKids
  where
    currentKids = fmap fst $ withDefinition grabDefTypes $ fromJust $
      Map.lookup (Tagged $ unNamespace testNs) $ _vsTyDefs vs
    grabDefTypes :: Definition mt -> AssocList Seg (DefName, Editability)
    grabDefTypes (StructDef { strDefChildTys = tyinfo }) = tyinfo
    grabDefTypes _ = error "Test vs root type not a struct!"

extendedVs :: MonadFail m => SomeDefinition -> Seg -> DataChange -> m Valuespace
extendedVs def s dc =
  let
    rootDef = redefTestRoot (alInsert s $ Tagged s) testValuespace
    d = Trpd
      testNs
      mempty
      (Map.fromList
        [ (Tagged s, OpDefine def)
        , (Tagged $ unNamespace testNs, OpDefine rootDef)])
      (alSingleton (Root :/ s) dc)
      mempty
      mempty
  in vsAppliesCleanly d testValuespace

vsWithXRef :: MonadFail m => m Valuespace
vsWithXRef =
  let
    newNodeDef = tupleDef
      "for test"
      -- FIXME: Should the ref seg be tagged?:
      (alSingleton [segq|daRef|] $ ttRef versionS)
      ILUninterpolated
    newVal = ConstChange Nothing
      [someWireable $ Path.toText Path.unSeg [pathq|/version|]]
  in extendedVs newNodeDef refSeg newVal

refSeg :: Seg
refSeg = [segq|ref|]

emptyArrayD :: Seg -> Valuespace -> TrpDigest
emptyArrayD s vs = Trpd
    testNs
    mempty
    (Map.fromList
     [ (Tagged s, OpDefine vaDef)
     , (Tagged $ unNamespace testNs, OpDefine rootDef)])
    alEmpty
    mempty
    mempty
  where
    vaDef = arrayDef "for test" Nothing (Tagged [segq|version|]) Editable
    -- FIXME: is vs always testValuespace?
    rootDef = redefTestRoot (alInsert s $ Tagged s) vs

spec :: Spec
spec = do
  return ()
  describe "Validation" $ do
    it "raw baseValuespace invalid" $
      let
        rawValuespace = baseValuespace (Tagged testS) Editable
        allTainted = Map.fromList $ fmap (,Nothing) $ Tree.paths Root $
          _vsTree rawValuespace
      in validateVs allTainted rawValuespace `shouldSatisfy` isLeft
    it "rechecks on data changes" $
      let
        d = Trpd testNs mempty mempty
          (alSingleton [pathq|/version|] $
           ConstChange Nothing [someWv WtString "wrong"])
          mempty mempty
      in vsProviderErrorsOn testValuespace d [[pathq|/version|]]
    it "rechecks on type def changes" $
      -- Make sure changing (api, version) goes and checks things defined
      -- to have that type:
      let
          newDef = tupleDef
            "for test"
            (alSingleton [segq|versionString|] $ ttString "apple")
            ILUninterpolated
          d = Trpd
            testNs mempty
            (Map.singleton (Tagged versionS) $ OpDefine newDef)
            alEmpty mempty mempty
      in vsProviderErrorsOn testValuespace d [[pathq|/version|]]
    it "rechecks on container ops" $
      let
        d = Trpd
            testNs
            mempty
            mempty
            alEmpty
            (Map.singleton Root $ Map.singleton [segq|version|] (Nothing, SoAbsent))
            mempty
      in vsProviderErrorsOn testValuespace d [Root]
    it "should only re-validate data that has been marked as invalid" $
      let
        p = [pathq|/api/version|]
        badVs = testValuespace {
          _vsTree = snd $ updateTreeWithDigest mempty
            (alSingleton p $ ConstChange Nothing []) $
            _vsTree testValuespace}
        invalidatedPaths = Map.singleton p Nothing
      in do
        -- Validation without specifying the change should miss the bad data:
        either (error . show) snd (validateVs mempty badVs) `shouldBe` badVs
        -- Validation explicitly asking to revalidate the change should fail:
        either id (error . show) (validateVs invalidatedPaths badVs)
          `shouldSatisfy` (not . null)
    it "can change the version type" $
      (
        vsAppliesCleanly (validVersionTypeChange testValuespace) testValuespace
        :: Either String Valuespace)
      `shouldSatisfy` isRight
    it "xref referee type change errors" $ do
      -- Change the type of the instance referenced in a cross reference
      vs <- vsWithXRef
      vsProviderErrorsOn vs (validVersionTypeChange vs)
        [Root :/ refSeg]
    it "xref old references do not error" $
      let
        v2s = [segq|v2|]
        v2Val = alSingleton (Root :/ v2s) $ ConstChange Nothing
          [someWv WtInt32 123]
      in do
        vs <- vsWithXRef
        -- Add another version node:
        let v2ApiDef = redefTestRoot
              (alInsert v2s $ Tagged [segq|version|]) vs
        vs' <- vsAppliesCleanly
          (Trpd testNs mempty
            (Map.singleton (Tagged $ unNamespace testNs) $ OpDefine v2ApiDef)
            v2Val mempty mempty)
          vs
        -- Update the ref to point at new version:
        vs'' <- vsAppliesCleanly
          (Trpd testNs mempty mempty
            (alSingleton (Root :/ refSeg)
             $ ConstChange Nothing
             [someWireable $ Path.toText Path.unSeg [pathq|/v2|]])
            mempty mempty)
          vs'
        (vsAppliesCleanly (validVersionTypeChange vs'') vs''
          :: Either String Valuespace) `shouldSatisfy` isRight
    it "Copes with set and absent in same bundle" $
      let
        xS = [segq|cross|]
        aS = [segq|a|]
        vs = baseValuespace (Tagged xS) Editable
        d = Trpd
            (Namespace xS)
            mempty
            (Map.fromList
              [ (Tagged xS, OpDefine $ arrayDef "kriss" Nothing (Tagged aS) ReadOnly)
              , (Tagged aS, OpDefine $ tupleDef "ref a" (alSingleton aS $ ttInt32 unbounded) ILUninterpolated)
              ])
            (alSingleton [pathq|/ard|] $ ConstChange Nothing [someWv WtInt32 3])
            (Map.singleton [pathq|/|] $ Map.singleton [segq|ard|] (Nothing, SoAbsent))
            mempty
      in void $ vsAppliesCleanly d vs :: IO ()
    it "Array" $
      let
        ars = [segq|arr|]
        badChild = Trpd
          testNs
          mempty
          mempty
          (alSingleton [pathq|/arr/bad|] $
            ConstChange Nothing [someWv WtString "boo"])
          mempty
          mempty
        goodChild = Trpd
          testNs
          mempty
          mempty
          (alSingleton [pathq|/arr/mehearties|] $
            ConstChange Nothing [someWv WtInt32 3])
          mempty
          mempty
        removeGoodChild = Trpd
          testNs
          mempty
          mempty
          alEmpty
          (Map.singleton [pathq|/arr|] $ Map.singleton [segq|mehearties|] (Nothing, SoAbsent))
          mempty
      in do
        vs <- vsAppliesCleanly (emptyArrayD ars testValuespace) testValuespace
        vsProviderErrorsOn vs badChild [[pathq|/arr/bad|]]
        vs' <- vsAppliesCleanly goodChild vs
        vs'' <- vsAppliesCleanly removeGoodChild vs'
        vs'' `shouldBe` vs
    it "Errors on struct with missing child" $
      let
        rootDef = redefTestRoot
          (alInsert [segq|unfilled|] $ Tagged [segq|version|])
          testValuespace
        missingChild = Trpd
          testNs
          mempty
          (Map.singleton (Tagged $ unNamespace testNs) $ OpDefine rootDef)
          alEmpty
          mempty
          mempty
      in vsProviderErrorsOn testValuespace missingChild [Root]
    it "Allows nested empty containers" $
      let
        emptyS = [segq|empty|]
        arrS = [segq|arr|]
        emptyNest = Trpd
            (Namespace emptyS)
            mempty
            (Map.fromList
              [ (Tagged emptyS, OpDefine $ structDef "oaea" $ alSingleton arrS (Tagged arrS, ReadOnly))
              , (Tagged arrS, OpDefine $ arrayDef "ea" Nothing (Tagged arrS) ReadOnly)
              ])
            alEmpty
            mempty
            mempty
        addToNestedStruct = Trpd
            (Namespace emptyS)
            mempty
            mempty
            alEmpty
            (Map.singleton [pathq|/arr|] $ Map.singleton emptyS (Nothing, SoAfter Nothing))
            mempty
      in do
        vs <- vsAppliesCleanly emptyNest $ baseValuespace (Tagged emptyS) Editable
        void $ vsAppliesCleanly addToNestedStruct vs :: IO ()
    it "Allows contops in array declaring digest" $
      let
        codS = [segq|cod|]
        codb = Trpd
            (Namespace codS)
            mempty
            (Map.singleton (Tagged codS) $ OpDefine $ arrayDef "fishy" Nothing (Tagged codS) ReadOnly)
            alEmpty
            (Map.singleton Root $ Map.singleton codS (Nothing, SoAfter Nothing))
            mempty
      in void $ vsAppliesCleanly codb $ baseValuespace (Tagged codS) Editable :: IO ()
    it "Rejects recursive struct" $
      let
        rS = [segq|r|]
        rDef = Trpd
            (Namespace rS)
            mempty
            (Map.singleton (Tagged rS) $ OpDefine $ structDef "r4eva" $ alSingleton rS (Tagged rS, ReadOnly))
            alEmpty
            mempty
            mempty
      in vsProviderErrorsOn (baseValuespace (Tagged rS) ReadOnly) rDef [Root]
    describe "Client" $
        it "Cannot itself create new array entries" $
          let
            dd = alSingleton [pathq|/arr/a|] $ ConstChange Nothing
                [someWv WtWord32 1, someWv WtWord32 2, someWv WtInt32 3]
            trcud = (trcudEmpty testNs) {trcudData = dd}
          in do
            vs <- vsAppliesCleanly (emptyArrayD [segq|arr|] testValuespace) testValuespace
            vsClientErrorsOn vs trcud [[pathq|/arr/a|]]
