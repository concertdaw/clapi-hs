{-# OPTIONS_GHC -Wall -Wno-orphans #-}
{-# LANGUAGE ScopedTypeVariables #-}
{-# LANGUAGE TypeApplications #-}
{-# LANGUAGE TupleSections #-}

module Clapi.Validator where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Control.Monad (void, join)
import Data.Word (Word8)
import Data.Maybe (fromJust)
import qualified Data.Set as Set
import qualified Data.Text as Text
import Text.Regex.PCRE ((=~~))
import Text.Printf (printf, PrintfArg)

import Clapi.Util (ensureUnique)
import Clapi.Types (UniqList, mkUniqList, WireValue, Time, Wireable, (<|$|>))
import Clapi.Types.Path (Seg, Path, TypeName)
import qualified Clapi.Types.Path as Path
import Clapi.Types.Tree
  ( TreeType(..), TreeConcreteType(..), TreeContainerTypeName(..), typeEnumOf
  , contTContainedType, Bounds, boundsMin, boundsMax)
import Clapi.TextSerialisation (ttFromText)

inBounds :: (Ord a, MonadFail m, PrintfArg a) => Bounds a -> a -> m a
inBounds b n = go (boundsMin b) (boundsMax b)
  where
    success = return n
    gte lo | n >= lo = success
           | otherwise = fail $ printf "%v is not >= %v" n lo
    lte hi | n <= hi = success
           | otherwise = fail $ printf "%v is not <= %v" n hi
    go Nothing Nothing = success
    go (Just lo) Nothing = gte lo
    go Nothing (Just hi) = lte hi
    go (Just lo) (Just hi) = gte lo >> lte hi

unpackTreeType :: TreeType -> (TreeConcreteType, [TreeContainerTypeName])
unpackTreeType tt = let (c, ts) = inner tt in (c, reverse ts)
  where
    inner (TtConc t) = (t, [])
    inner (TtCont t) = let (c, ts) = inner $ contTContainedType t in
        (c, (typeEnumOf t) : ts)

-- FIXME: If we had first class tree values we would be able to guarantee that
-- a ref thing was the right type
extractTypeAssertion :: TreeType -> WireValue -> [(TypeName, Path)]
extractTypeAssertion tt wv =
  let
    (concT, contTs) = unpackTreeType tt
    mTn = case concT of
      TcRef tn -> Just tn
      _ -> Nothing
    listMash :: Wireable a => [TreeContainerTypeName] -> (a -> [Path]) -> [Path]
    listMash (_:cts) f = listMash cts (mconcat . map f)
    listMash [] f = maybe [] id $ f <|$|> wv
  in do
    case mTn of
      Nothing -> []
      Just tn -> (tn,) <$> listMash contTs (\v -> [fromJust $ Path.fromText v])

validate :: forall m. MonadFail m => TreeType -> WireValue -> m ()
validate tt wv =
  let
    (concT, contTs) = unpackTreeType tt
    g = case concT of
      TcTime -> recy $ return @m @Time
      TcEnum ns  -> recy $ checkEnum ns
      TcWord32 b -> recy $ inBounds b
      TcWord64 b -> recy $ inBounds b
      TcInt32 b -> recy $ inBounds b
      TcInt64 b -> recy $ inBounds b
      TcFloat b -> recy $ inBounds b
      TcDouble b -> recy $ inBounds b
      TcString r -> recy $ checkString r
      TcRef _ -> recy Path.fromText
      TcValidatorDesc -> recy ttFromText
  in
    g contTs
  where
    recy :: (Show b, Ord b, Wireable a) =>
      (a -> m b) -> [TreeContainerTypeName]-> m ()
    recy f [] = void $ join $ f <|$|> wv
    recy f (ct:cts) = case ct of
      TcnList -> recy (checkList f) cts
      TcnSet -> recy (checkSet f) cts
      TcnOrdSet -> recy (checkOrdSet f) cts
    checkEnum :: [Seg] -> Word8 -> m Word8
    checkEnum ns w = let theMax = fromIntegral $ length ns in
      if w >= theMax
        then fail $ printf "Enum value %v out of range" w
        else return w
    checkString r t = maybe
      (fail $ printf "did not match '%s'" r)
      (const $ return t)
      (Text.unpack t =~~ Text.unpack r :: Maybe ())
    checkList :: (a -> m b) -> [a] -> m [b]
    checkList = mapM
    checkSet :: (Show b, Ord b) => (a -> m b) -> [a] -> m (Set.Set b)
    checkSet f v = do
      vs <- mapM f v
      Set.fromList <$> ensureUnique "items" vs
    checkOrdSet :: (Show b, Ord b) => (a -> m b) -> [a] -> m (UniqList b)
    checkOrdSet f v = mapM f v >>= mkUniqList
