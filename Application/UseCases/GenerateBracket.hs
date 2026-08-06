module Application.UseCases.GenerateBracket
  ( generateBracket
  , GenerateBracketError(..)
  ) where

import Control.Exception (assert)
import Data.Bifunctor (first)

import Domain.Tournament (Tournament(..), TournamentId, TournamentState(RegistrationClosed))
import Domain.Bracket (Bracket(..), BracketId, BracketNode(..), MatchSlot(..))
import Domain.Match (MatchId)
import Domain.Participant (Participant)
import Domain.Registration (registrationParticipant)
import Domain.Ids (BracketNodeId(..), UserId)
import Data.List (find)
import Data.Maybe (mapMaybe)
import Data.Map.Strict (Map)
import qualified Data.Map.Strict as Map

import Shell.Persistence.Port
  ( BracketRepository
  , TournamentRepository
  , RegistrationRepository
  , MatchRepository
  , ParticipantRepository
  , Transactional(..)
  , NewMatch(..)
  )
import qualified Shell.Persistence.Port as Repo

import Engine.Error (EngineError)
import qualified Engine.Validation        as Validation
import qualified Engine.BracketGeneration as BracketGeneration
import qualified Engine.Seeding           as Seeding
import qualified Engine.ByeResolution     as ByeResolution
import qualified Engine.Materialization   as Materialization
import Application.Internal.MatchCreation (createMatchForReadyNode)
import Application.Internal.Authorization (AuthorizationError, requireTournamentOwner)
import Application.Internal.LifecycleTransition (LifecycleError, requireTournamentState)
import Domain.TournamentHistory (TournamentHistoryEvent(BracketGenerated))
import Shell.Persistence.Port (TournamentHistoryRepository)

data GenerateBracketError
  = Unauthorized AuthorizationError
  | InvalidBracket EngineError
  | InvalidLifecycle LifecycleError
  deriving (Eq, Show)

generateBracket
  :: ( BracketRepository m
     , TournamentRepository m
     , RegistrationRepository m
     , MatchRepository m
     , ParticipantRepository m
     , Transactional m
     , TournamentHistoryRepository m
     )
  => UserId
  -> TournamentId
  -> m (Either GenerateBracketError BracketId)
generateBracket currentUser tid = do
  tournament <- Repo.getTournament tid

  case first Unauthorized (requireTournamentOwner currentUser tournament) of
    Left err -> pure (Left err)
    Right () ->
      case first InvalidLifecycle (requireTournamentState RegistrationClosed tournament) of
        Left err -> pure (Left err)
        Right () -> do

          registrations <- Repo.listRegistrations tid
          let participants = map registrationParticipant registrations

          case first InvalidBracket (Validation.validateParticipants tournament participants) of
            Left err -> pure (Left err)
            Right validParticipants -> do

              let size          = BracketGeneration.bracketSize (length validParticipants)
                  topology      = BracketGeneration.buildTopology size
                  seeded        = Seeding.seedParticipants validParticipants topology
                  resolvedNodes = ByeResolution.resolveAutomaticAdvancements seeded

              withTxN $ do
                  bracketId <- Repo.createBracket tid
                  nodeIdMap <- Repo.saveBracket
                      Bracket { bracketId = bracketId, bracketTournament = tid }
                      resolvedNodes

                  let readyIds = Materialization.readyNodes resolvedNodes
                      ready     = mapMaybe (\nid -> find (\n -> nodeId n == nid) resolvedNodes) readyIds

                  let storageNodeId n = case Map.lookup (nodeId n) nodeIdMap of
                          Just sid -> sid
                          Nothing  -> error ("generateBracket: BracketNodeId " ++ show (nodeId n) ++ " not found in idMap")

                  matchIds <- mapM (\n -> createMatchForReadyNode tid bracketId (storageNodeId n) n) ready

                  let newMatches =
                          Materialization.materializeReadyMatches
                              matchIds tid bracketId nodeIdMap ready

                  mapM_ Repo.saveMatch newMatches

                  Repo.saveTournament tournament { tournamentBracket = Just bracketId }

                  Repo.recordHistoryEvent tid BracketGenerated

                  pure (Right bracketId)

-- | Resolves a ready node's two competitors to ParticipantIds and mints a
-- MatchId for it via MatchRepository.createMatch. DI-12: the node's own
-- identity is threaded through as newMatchBracketNode so the persisted
-- Match retains a deterministic link back to its originating BracketNode.
--
-- assert documents that "not fully filled" here is an invariant violation
-- (DI-09/readyNodes), not a recoverable business outcome -- distinct from
-- MatchError-style Either failures, which represent expected outcomes.