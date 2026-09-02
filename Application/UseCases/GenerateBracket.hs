module Application.UseCases.GenerateBracket
  ( generateBracket
  , GenerateBracketError(..)
  ) where

import Control.Exception (assert)
import Data.Bifunctor (first)

import Domain.Tournament
  ( Tournament(..), TournamentId, TournamentFormat(..)
  , TournamentState(RegistrationClosed)
  )
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
  | InvalidLifecycle LifecycleError
  | UnsupportedFormat TournamentFormat
  | InvalidBracket EngineError
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
        Right () ->
          case requireSupportedFormat tournament of
            Left err -> pure (Left err)
            Right () -> do

              registrations <- Repo.listRegistrations tid
              let participants = map registrationParticipant registrations

              case first InvalidBracket (Validation.validateParticipants tournament participants) of
                Left err -> pure (Left err)
                Right validParticipants -> do

                  case tournamentFormat tournament of
                    DoubleElimination -> do
                      let size          = BracketGeneration.bracketSize (length validParticipants)
                          wbNodes       = BracketGeneration.buildTopology size
                          seededWB      = Seeding.seedParticipants validParticipants wbNodes
                          (otherNodes, gf1Id, resetId) =
                             BracketGeneration.buildDoubleEliminationTopology seededWB size
                          resolvedNodes = ByeResolution.resolveAutomaticAdvancements (seededWB ++ otherNodes)

                      withTxN $ do
                          bracketId <- Repo.createBracket tid
                          nodeIdMap <- Repo.saveBracket
                              Bracket { bracketId = bracketId, bracketTournament = tid
                                      , bracketGF1NodeId = Just gf1Id, bracketResetNodeId = Just resetId }
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

                    RoundRobin -> do
                      let resolvedNodes = BracketGeneration.buildRoundRobinTopology validParticipants

                      withTxN $ do
                          bracketId <- Repo.createBracket tid
                          nodeIdMap <- Repo.saveBracket
                              Bracket { bracketId = bracketId, bracketTournament = tid
                                      , bracketGF1NodeId = Nothing, bracketResetNodeId = Nothing }
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

                    SingleElimination -> do
                      let size          = BracketGeneration.bracketSize (length validParticipants)
                          topology      = BracketGeneration.buildTopology size
                          seeded        = Seeding.seedParticipants validParticipants topology
                          resolvedNodes = ByeResolution.resolveAutomaticAdvancements seeded

                      withTxN $ do
                          bracketId <- Repo.createBracket tid
                          nodeIdMap <- Repo.saveBracket
                              Bracket { bracketId = bracketId, bracketTournament = tid
                                      , bracketGF1NodeId = Nothing, bracketResetNodeId = Nothing }
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

-- | All three TournamentFormat constructors are matched explicitly
-- (no catch-all) so GHC's exhaustiveness checking itself guards
-- against a future format being silently mishandled here.
requireSupportedFormat :: Tournament -> Either GenerateBracketError ()
requireSupportedFormat tournament =
  case tournamentFormat tournament of
    SingleElimination -> Right ()
    DoubleElimination -> Right ()
    RoundRobin        -> Right ()