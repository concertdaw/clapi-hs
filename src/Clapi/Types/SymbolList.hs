{-# LANGUAGE
    DataKinds
  , GADTs
  , KindSignatures
  , LambdaCase
  , PolyKinds
  , RankNTypes
  , StandaloneDeriving
  , TypeFamilies
  , TypeOperators
#-}
module Clapi.Types.SymbolList where

import Prelude hiding (length, (!!))
import Data.Proxy
import Data.Type.Equality (TestEquality(..), (:~:)(..))

import GHC.TypeLits
  (Symbol, KnownSymbol, SomeSymbol(..), someSymbolVal, symbolVal, sameSymbol)

import Clapi.Types.PNat (PNat(..), SPNat(..), (:<))

withKnownSymbol :: (forall s. KnownSymbol s => Proxy s -> r) -> String -> r
withKnownSymbol f s = case someSymbolVal s of
  (SomeSymbol p) -> f p

data SymbolList (ss :: [Symbol]) where
  SlEmpty :: SymbolList '[]
  SlCons :: KnownSymbol s => Proxy s -> SymbolList ss -> SymbolList ('(:) s ss)

instance Show (SymbolList ss) where
  show SlEmpty = "SlEmpty"
  show (SlCons p ss) = "SlCons (Proxy @" ++ show (symbolVal p) ++ ") " ++
    case ss of
      SlEmpty -> show SlEmpty
      _ -> "(" ++ show ss ++ ")"

instance Eq (SymbolList ss) where
  _ == _ = True  -- Guaranteed by type equality

instance TestEquality SymbolList where
  testEquality SlEmpty SlEmpty = Just Refl
  testEquality (SlCons p1 sl1) (SlCons p2 sl2) =
    case (sameSymbol p1 p2, testEquality sl1 sl2) of
      (Just Refl, Just Refl) -> Just Refl
      _ -> Nothing
  testEquality _ _ = Nothing

data SomeSymbolList where
  SomeSymbolList :: SymbolList ss -> SomeSymbolList
deriving instance Show SomeSymbolList

instance Eq SomeSymbolList where
  SomeSymbolList sl1 == SomeSymbolList sl2 = case testEquality sl1 sl2 of
    Just Refl -> sl1 == sl2
    Nothing -> False

cons :: String -> SymbolList ss -> SomeSymbolList
cons s sl = case someSymbolVal s of
  SomeSymbol p -> SomeSymbolList $ SlCons p sl

cons_ :: String -> SomeSymbolList -> SomeSymbolList
cons_ s (SomeSymbolList sl) = cons s sl

singleton :: KnownSymbol s => Proxy s -> SymbolList '[s]
singleton p = SlCons p SlEmpty

singleton_ :: String -> SomeSymbolList
singleton_ = withKnownSymbol (SomeSymbolList . singleton)

type family Length (sa :: [k]) :: PNat where
  Length '[] = 'Zero
  Length ('(:) a as) = 'Succ (Length as)

length :: SymbolList ss -> SPNat (Length ss)
length = \case
  SlEmpty -> SPZero
  SlCons _ sl -> SPSucc $ length sl

(!!) :: n :< Length ss ~ 'True => SymbolList ss -> SPNat n -> SomeSymbol
(!!) (SlCons p sl) = \case
  SPZero -> SomeSymbol p
  SPSucc sPNat -> sl !! sPNat

withSymbolList :: forall r. (forall ss. SymbolList ss -> r) -> [String] -> r
withSymbolList f = go SlEmpty
  where
    go :: SymbolList ss -> [String] -> r
    go acc [] = f acc
    go acc (s : ss) = case someSymbolVal s of
      SomeSymbol p -> go (SlCons p acc) ss

fromStrings :: [String] -> SomeSymbolList
fromStrings = withSymbolList SomeSymbolList

toStrings :: SymbolList ss -> [String]
toStrings = \case
  SlEmpty -> []
  SlCons p sl -> symbolVal p : toStrings sl

toStrings_ :: SomeSymbolList -> [String]
toStrings_ (SomeSymbolList sl) = toStrings sl
