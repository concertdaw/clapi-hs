{-# LANGUAGE
    OverloadedStrings
#-}

module TreeSpec where

import Test.Hspec
import qualified Data.Map as Map

import Clapi.TH
import qualified Clapi.Types.AssocList as AL
import qualified Clapi.Types.Dkmap as Dkmap
import Clapi.Types.Path (DataName, pattern Root, pattern (:/))
import Clapi.Types.SequenceOps (SequenceOp(SoAfter), dependencyOrder')
import Clapi.Tree (RoseTree(..), RoseTreeNode(..))
import qualified Clapi.Tree as Tree
import Clapi.Valuespace.ErrWrap (liftExcept)
import Clapi.Valuespace.Errors ()  -- Wraps e IOException

import Instances ()

s0, s1, s2, s3, s4 :: DataName
s0 = [n|t0|]
s1 = [n|t1|]
s2 = [n|t2|]
s3 = [n|t3|]
s4 = [n|t4|]

t0, t1, t2, t3, t4 :: RoseTree Char
t0 = RtEmpty
t1 = RtConstData Nothing 'b'
t2 = RtDataSeries Dkmap.empty
t3 = RtContainer $ fmap (Nothing,) $ AL.fromList [(s0, t0), (s1, t1), (s2, t2)]
t4 = RtContainer $ fmap (Nothing,) $ AL.fromList [(s3, t3), (s1, t1)]

spec :: Spec
spec = do
  describe "Tree.lookup" $ do
    it "should find a node that is present" $
      Tree.lookup (Root :/ s3 :/ s1) t4 `shouldBe` Just t1
    it "should return Nothing if no node is present" $
      Tree.lookup [pathq|/naff|] t4 `shouldBe` Nothing

  describe "Tree.insert" $  do
    it "should insert the node" $
      let
        att = Just "bob"
        t = Tree.insert att (Root :/ s2) t2 t4
        expectedKids = AL.fromList [(s3, Nothing), (s1, Nothing), (s2, att)]
      in do
        Tree.lookup (Root :/ s2) t `shouldBe` Just t2
        Tree.lookupNode Root t `shouldBe` Just (RtnChildren expectedKids)

    it "should overwrite an existing node" $
      let
        att = Just "bob"
        t = Tree.insert att (Root :/ s1) t2 t4
        expectedKids = AL.fromList [(s3, Nothing), (s1, att)]
      in do
        Tree.lookup (Root :/ s1) t `shouldBe` Just t2
        Tree.lookupNode Root t `shouldBe` Just (RtnChildren expectedKids)

    it "should recursively add containers as needed" $
      let
        att = Just "bob"
        t = Tree.insert att ([pathq|/will/bo|]) t0 t1
        expectedT = RtContainer $ AL.singleton [n|will|]
          (att, RtContainer $ AL.singleton [n|bo|] (att, t0))
      in
        t `shouldBe` expectedT

  describe "Tree.delete" $ do
    it "should delete something that isn't there" $ do
      Tree.delete [pathq|/will|] t4 `shouldBe` t4
      Tree.delete [pathq|/will|] t1 `shouldBe` t1
    it "should delete recursively" $
      Tree.delete (Root :/ s3 :/ s1) t4 `shouldBe` RtContainer (AL.fromList
        [ (s3, (Nothing, RtContainer $ AL.fromList
          [(s0, (Nothing, t0)), (s2, (Nothing, t2))]))
        , (s1, (Nothing, t1))
        ])
    it "doesn't create illegitimate parents" $ do
      Tree.delete [pathq|/t3/to/box|] t3 `shouldBe` t3
      Tree.delete [pathq|/t1/to/box|] t3 `shouldBe` t3

  describe "Tree.applyReorderings" $ do
    it "should preserve child contents" $ do
      orderedOps <- liftExcept $ dependencyOrder' snd
        $ Map.singleton s3 (Nothing, SoAfter Nothing)
      Tree.applyReorderings RtEmpty orderedOps t4
        `shouldBe` (Right t4 :: Either String (RoseTree Char))
