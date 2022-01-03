{-# LANGUAGE DataKinds #-}
{-# LANGUAGE GADTs #-}
{-# LANGUAGE NamedFieldPuns #-}
{-# LANGUAGE RankNTypes #-}
{-# LANGUAGE RecordWildCards #-}
{-# LANGUAGE ScopedTypeVariables #-}

-- | This module implements a secure and efficient way to temporarily store
-- webauthn options for the create/register and get/login webauthn operations
-- along with generating the challenge needed for them.
module PendingOps
  ( PendingOpsConfig (..),
    defaultPendingOpsConfig,
    newPendingOps,
    PendingOps,
    insertPendingOptions,
    getPendingOptions,
  )
where

import Control.Concurrent (forkIO, threadDelay)
import qualified Control.Concurrent.STM as STM
import Control.Monad (forever, unless, when)
import qualified Crypto.WebAuthn.Model as M
import Crypto.WebAuthn.Model.Kinds (SWebauthnKind (SCreate, SGet))
import Data.Binary (Binary (get, put))
import qualified Data.Binary as Binary
import Data.Binary.Get as Binary (getInt64le, getRemainingLazyByteString)
import Data.Binary.Put as Binary (putInt64le, putLazyByteString)
import qualified Data.ByteString.Lazy as LBS
import Data.Int (Int64)
import Data.Map (Map)
import qualified Data.Map as Map
import Data.Singletons (SingI, sing)
import System.Clock (Clock (Realtime), TimeSpec (sec), getTime)

-- | Configuration for the pending operation management
data PendingOpsConfig = PendingOpsConfig
  { -- | The minimum time in seconds that a pending operation should be waited for to complete
    validTime :: Int64,
    -- | The interval in seconds at which pending operations should be checked for expiration
    expireInterval :: Int,
    -- | The number of random bytes the challenge should contain. Should be at least 16
    challengeBytes :: Int
  }

-- | The default config: Operations are expired after 5 minutes, they get
-- cleaned up every 10 seconds, and challenges are 16 bytes long
defaultPendingOpsConfig :: PendingOpsConfig
defaultPendingOpsConfig =
  PendingOpsConfig
    { validTime = 5 * 60,
      expireInterval = 10,
      challengeBytes = 16
    }

-- | An 'M.Challenge' that expires after a certain time.
data ExpiringChallenge = ExpiringChallenge
  { -- | The unix epoch seconds after which this challenge is expired
    -- This is exposed to the clients, but this is not a vulnerability, see
    -- <https://security.stackexchange.com/questions/187316/is-exposing-the-server-time-a-security-risk>.
    -- This field intentionally comes _before_ the 'randomness' field, such that
    -- the derived 'Ord' instance orders challenges according to their expiration
    -- time, which allows much faster periodic expiration
    expiredAfter :: Int64,
    -- | The random part of the challenge
    randomness :: M.Challenge
  }
  deriving (Show, Eq, Ord)

-- | The current time in seconds for challenge expiration
getNow :: IO Int64
getNow =
  -- We're only interested in second-resolution, this is also why we use the Coarse clock version
  sec
    -- While realtime can have backwards jumps with leap seconds, that's not a
    -- problem since our expiration times are on the order of minutes, and it's
    -- pretty clear that realtime isn't a security problem, see
    -- <https://security.stackexchange.com/questions/187316/is-exposing-the-server-time-a-security-risk>
    <$> getTime Realtime

isExpired :: Int64 -> ExpiringChallenge -> Bool
isExpired now challenge = expiredAfter challenge < now

-- | This instance is used to turn an 'ExpiringChallenge' into an 'M.Challenge' and back
instance Binary ExpiringChallenge where
  put ExpiringChallenge {expiredAfter, randomness} = do
    Binary.putInt64le expiredAfter
    Binary.putByteString (M.unChallenge randomness)
  get =
    ExpiringChallenge
      <$> Binary.getInt64le
      <*> (M.Challenge . LBS.toStrict <$> Binary.getRemainingLazyByteString)

type Pendings t = STM.TVar (Map ExpiringChallenge (M.PublicKeyCredentialOptions t))

-- | The data structure that stores pending operations in memory
data PendingOps = PendingOps
  { pendingRegisters :: Pendings 'M.Create,
    pendingLogins :: Pendings 'M.Get,
    pendingConfig :: PendingOpsConfig
  }

-- | Stores a new pending operation in memory along with its 'M.PublicKeyCredentialOptions' options.
-- The challenge to be used for the options is generated by this function.
-- This function can be used for both register and login webauthn operations
insertPendingOptions ::
  forall t.
  SingI t =>
  PendingOps ->
  -- | Given a generated challenge, what are the complete options. The challenge
  -- needs to be used for the options 'M.pkcocChallenge'/'M.pkcogChallenge' field
  (M.Challenge -> M.PublicKeyCredentialOptions t) ->
  IO (M.PublicKeyCredentialOptions t)
insertPendingOptions pendingOps = case sing @t of
  SCreate -> insert (pendingRegisters pendingOps)
  SGet -> insert (pendingLogins pendingOps)
  where
    insert ::
      Pendings t ->
      (M.Challenge -> M.PublicKeyCredentialOptions t) ->
      IO (M.PublicKeyCredentialOptions t)
    insert pending create = do
      expiringChallenge <- generateExpiringChallenge
      let challenge = M.Challenge $ LBS.toStrict $ Binary.encode expiringChallenge
          value = create challenge
      STM.atomically $ STM.modifyTVar pending $ Map.insert expiringChallenge value
      pure value

    generateExpiringChallenge :: IO ExpiringChallenge
    generateExpiringChallenge = do
      now <- getNow
      -- We only look at seconds, not nanoseconds
      -- 1 hour expiration time, no real reason
      let expiredAfter = now + validTime (pendingConfig pendingOps)

      randomness <- M.generateChallenge

      pure $ ExpiringChallenge {..}

-- | Gets a pending operation in memory along with its 'M.PublicKeyCredentialOptions',
-- given a 'M.PublicKeyCredential' which contains the challenge previously generated by 'insertPendingOptions'.
-- This deletes the options from memory again. If the challenge is expired an error is returned
-- This function can be used for both register and login webauthn operations
getPendingOptions ::
  forall t raw.
  SingI t =>
  PendingOps ->
  -- The credential that was received as a reply
  M.PublicKeyCredential t raw ->
  IO (Either String (M.PublicKeyCredentialOptions t))
getPendingOptions pending cred = case sing @t of
  -- We extract the challenge from the response credential that was sent back
  SCreate -> get (pendingRegisters pending) (M.ccdChallenge $ M.arcClientData $ M.pkcResponse cred)
  SGet -> get (pendingLogins pending) (M.ccdChallenge $ M.argClientData $ M.pkcResponse cred)
  where
    get ::
      Pendings t ->
      M.Challenge ->
      IO (Either String (M.PublicKeyCredentialOptions t))
    get pending (M.Challenge challenge) = case Binary.decodeOrFail (LBS.fromStrict challenge) of
      Left (_, _, err) -> pure $ Left $ "Decoding challenge failed: " <> err
      Right (_, _, expiringChallenge) -> do
        now <- getNow
        -- The client has to send back the correct expired time, so we don't
        -- even need to do an STM action if it's expired already
        -- This is safe because if the expired time is wrong for a specific
        -- challenge, it would just not be found in the map in the following step
        if isExpired now expiringChallenge
          then pure $ Left "Challenge expired"
          else STM.atomically $ do
            contents <- STM.readTVar pending
            let result = Map.lookup expiringChallenge contents
            -- Delete the challenge, it should only be usable a single time
            STM.writeTVar pending $ Map.delete expiringChallenge contents
            pure $ case result of
              Just options -> Right options
              Nothing -> Left "Challenge not known or expired"

-- | Creates a new managed 'PendingOps' value that tracks pending webauthn
-- operations according to the given 'PendingOpsConfig'.
-- The result can be used with functions 'insertPendingOptions' and 'getPendingOptions'
newPendingOps ::
  PendingOpsConfig ->
  IO PendingOps
newPendingOps pendingConfig = do
  -- [(spec)](https://www.w3.org/TR/webauthn-2/#sctn-cryptographic-challenges)
  -- In order to prevent replay attacks, the challenges MUST contain enough entropy
  -- to make guessing them infeasible. Challenges SHOULD therefore be at least 16 bytes long.
  when (challengeBytes pendingConfig < 16) $ fail "newPendingOps: challengeBytes needs to be at least 16 [bytes]"
  pendingRegisters <- STM.newTVarIO Map.empty
  pendingLogins <- STM.newTVarIO Map.empty
  let pendings = PendingOps {..}
  -- Clean up pending operations over time to prevent leaking memory for
  -- operations that are only started but never finished
  _ <- forkIO $ expireLoop pendings
  pure pendings
  where
    expireLoop :: PendingOps -> IO ()
    expireLoop pending = forever $ do
      now <- getNow
      expireChallenges now (pendingRegisters pending)
      expireChallenges now (pendingLogins pending)
      threadDelay (1000 * 1000 * expireInterval pendingConfig)

    expireChallenges ::
      Int64 ->
      Pendings t ->
      IO ()
    expireChallenges now pendings = do
      expired <- STM.atomically $ do
        ops <- STM.readTVar pendings
        -- 'Map.spanAntitone' is an efficient (O(log n)) way to split the map into a
        -- set of expired and a set of still valid operations, this is only
        -- possible because 'ExpiringChallenge's 'Ord' instance orders according
        -- to 'expiredAfter' time first
        let (expired, valid) = Map.spanAntitone (isExpired now) ops
        STM.writeTVar pendings valid
        pure expired
      -- TODO: Do something less invasive than printing the removed options
      unless (Map.null expired) $ putStrLn $ "Removed these expired pending operations: " <> show expired
