{-# OPTIONS_GHC -Wno-orphans #-}

module SerialisationSpec where

import Prelude hiding (fail)
import Control.Monad.Fail (MonadFail(..))
import Data.ByteString (ByteString)
import qualified Data.Map as Map
import qualified Data.ByteString as BS

import Test.Hspec
import Test.QuickCheck
  (property, Property, counterexample, Arbitrary(..), Gen, oneof)

import Blaze.ByteString.Builder (toByteString)
import Data.Attoparsec.ByteString (parseOnly, endOfInput)

import Clapi.Types
  ( Time, Attributee, WireValue
  , Interpolation(..), SubMessage(..), DataUpdateMessage(..), TypeMessage(..)
  , PostMessage(..), MsgError(..), TpId, DefMessage(..)
  , ContainerUpdateMessage(..), DeleteMessage(..)
  , ToRelayClientBundle(..), ToRelayProviderBundle(..)
  , FromRelayClientBundle(..), FromRelayProviderBundle(..)
  , FromRelayProviderErrorBundle(..), ToRelayProviderRelinquish(..)
  , ToRelayBundle(..), FromRelayBundle(..)
  , ErrorIndex(..))
import Clapi.Types.Path (Path(..), pattern Root)
import Clapi.Serialisation (Encodable(..))

-- Incl. Arbitrary instances of WireValue:
import TypesSpec (smallListOf, arbitraryTextNoNull)

encode :: (MonadFail m, Encodable a) => a -> m ByteString
encode x = toByteString <$> builder x

decode :: (MonadFail m, Encodable a) => ByteString -> m a
decode = either fail return . parseOnly (parser <* endOfInput)

instance Arbitrary Interpolation where
  arbitrary = oneof
      [ return IConstant
      , return ILinear
      , IBezier <$> arbitrary <*> arbitrary]

instance (Arbitrary ident, Arbitrary def)
    => Arbitrary (DefMessage ident def) where
  arbitrary = oneof
    [ MsgDefine <$> arbitrary <*> arbitrary
    , MsgUndefine <$> arbitrary
    ]

instance Arbitrary SubMessage where
  arbitrary = oneof
      [ MsgPostTypeSubscribe <$> arbitrary
      , MsgTypeSubscribe <$> arbitrary
      , MsgSubscribe <$> arbitrary
      , MsgPostTypeUnsubscribe <$> arbitrary
      , MsgTypeUnsubscribe <$> arbitrary
      , MsgUnsubscribe <$> arbitrary]

instance Arbitrary TypeMessage where
  arbitrary = MsgAssignType <$> arbitrary <*> arbitrary <*> arbitrary

instance Arbitrary (PostMessage ar) where
  arbitrary = MsgPost <$> arbitrary <*> arbitrary <*>
    (Map.fromList <$> smallListOf arbitrary)

genAttributee :: Gen (Maybe Attributee)
genAttributee = oneof [return Nothing, Just <$> arbitraryTextNoNull]

instance Arbitrary (DataUpdateMessage ar) where
  arbitrary = oneof
    [ MsgConstSet
      <$> (arbitrary @(Path ar))
      <*> (smallListOf $ arbitrary @WireValue)
      <*> genAttributee
    , MsgSet
      <$> (arbitrary @(Path ar))
      <*> (arbitrary @TpId)
      <*> (arbitrary @Time)
      <*> (smallListOf $ arbitrary @WireValue)
      <*> (arbitrary @Interpolation)
      <*> genAttributee
    , MsgRemove
      <$> (arbitrary @(Path ar))
      <*> (arbitrary @TpId)
      <*> genAttributee
    ]
  shrink (MsgConstSet Root [] Nothing) = []
  shrink (MsgConstSet p vs a) =
    [MsgConstSet p' vs' a' | (p', vs', a') <- shrink (p, vs, a)]
  shrink (MsgSet (Path []) _ _ [] _ Nothing) = []
  shrink (MsgSet p tpid t vs i a) =
    [MsgSet p' tpid t vs' i a' | (p', vs', a') <- shrink (p, vs, a)]
  shrink (MsgRemove (Path []) _ Nothing) = []
  shrink (MsgRemove p t a) = [MsgRemove p' t a' | (p', a') <- shrink (p, a)]


instance Arbitrary (ContainerUpdateMessage ar) where
  arbitrary = MsgMoveAfter <$> arbitrary <*> arbitrary <*> arbitrary
    <*> genAttributee

instance Arbitrary (DeleteMessage ar) where
  arbitrary = MsgDelete <$> arbitrary <*> arbitrary

instance Arbitrary a => Arbitrary (ErrorIndex a) where
  arbitrary = oneof
    [ return GlobalError
    , PathError <$> arbitrary
    , TimePointError <$> arbitrary <*> arbitrary
    , PostTypeError <$> arbitrary
    , TypeError <$> arbitrary
    ]

instance Arbitrary a => Arbitrary (MsgError a) where
  arbitrary = MsgError <$> arbitrary <*> arbitraryTextNoNull


instance Arbitrary ToRelayProviderBundle where
  arbitrary = ToRelayProviderBundle
    <$> arbitrary <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
  shrink (ToRelayProviderBundle n e pt t dels d c) =
    [ToRelayProviderBundle n e' pt' t' dels' d' c' |
       (e', pt', t', dels', d', c') <- shrink (e, pt, t, dels, d, c)]

instance Arbitrary FromRelayProviderBundle where
  arbitrary = FromRelayProviderBundle <$> arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary

instance Arbitrary ToRelayProviderRelinquish where
  arbitrary = ToRelayProviderRelinquish <$> arbitrary

instance Arbitrary FromRelayProviderErrorBundle where
  arbitrary = FromRelayProviderErrorBundle <$> smallListOf arbitrary

instance Arbitrary ToRelayClientBundle where
  arbitrary = ToRelayClientBundle <$> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
  shrink (ToRelayClientBundle s dels p d c) =
    [ToRelayClientBundle s' dels' p' d' c'
    | (s', dels', p', d', c') <- shrink (s, dels, p, d, c)]

instance Arbitrary FromRelayClientBundle where
  arbitrary = FromRelayClientBundle <$> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary <*> smallListOf arbitrary
    <*> smallListOf arbitrary
  shrink (FromRelayClientBundle ptu tu du e postDefs defs tas dels dd c) =
    [FromRelayClientBundle ptu' tu' du' e' postDefs' defs' tas' dels' dd' c'
    | (ptu', tu', du', e', postDefs', defs', tas', dels', dd', c')
    <- shrink (ptu, tu, du, e, postDefs, defs, tas, dels, dd, c)]


instance Arbitrary ToRelayBundle where
  arbitrary = oneof
    [ Trpb <$> arbitrary
    , Trpr <$> arbitrary
    , Trcb <$> arbitrary
    ]
  shrink (Trpb b) = Trpb <$> shrink b
  shrink (Trpr b) = Trpr <$> shrink b
  shrink (Trcb b) = Trcb <$> shrink b

instance Arbitrary FromRelayBundle where
  arbitrary = oneof
    [ Frpb <$> arbitrary
    , Frpeb <$> arbitrary
    , Frcb <$> arbitrary
    ]
  shrink (Frpb b) = Frpb <$> shrink b
  shrink (Frpeb b) = Frpeb <$> shrink b
  shrink (Frcb b) = Frcb <$> shrink b


showBytes :: ByteString -> String
showBytes = show . BS.unpack


propBundleRoundTrip
  :: forall bundle. (Show bundle, Eq bundle, Encodable bundle)
  => bundle -> Property
propBundleRoundTrip b = let
    mbs = encode b
    result = mbs >>= decode :: Either String bundle
  in
    counterexample (show mbs) $
    counterexample (show $ showBytes <$> mbs) $
    counterexample (show result) $
    Right b == result


spec :: Spec
spec = do
  describe "ToRelayBundle" $
    it "should survive a round trip via binary" $ property $
      \(b :: ToRelayBundle) -> propBundleRoundTrip b

  describe "FromRelayBundle" $
    it "should survive a round trip via binary" $ property $
      \(b :: FromRelayBundle) -> propBundleRoundTrip b
