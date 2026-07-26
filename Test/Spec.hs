module Main (main) where

import Test.Hspec
import Control.Monad (forM_)
import Control.Monad.IO.Class (liftIO)
import Control.Monad.Reader (ask)
import System.Directory (doesFileExist, removeFile)

import Shell.Persistence.SQLite.Connection (SQLiteM, SQLiteEnv(envConnection), runSQLiteM)
import Shell.Persistence.SQLite.Schema (initializeSchema)
import qualified Shell.Persistence.Port as Repo
import Shell.Persistence.Port (NewTournament(..))

-- Bringing SQLiteM's repository instances into scope (unused import list
-- is fine -- instances aren't named, so they come in regardless).
import Shell.Persistence.SQLite.ParticipantRepository ()
import Shell.Persistence.SQLite.TournamentRepository ()
import Shell.Persistence.SQLite.RegistrationRepository ()
import Shell.Persistence.SQLite.BracketRepository ()
import Shell.Persistence.SQLite.MatchRepository ()

import Domain.Participant (Participant(..), Player(..), PlayerName(..))
import Domain.Tournament
  ( TournamentName(..), OrganizerName(..), TournamentFormat(..)
  , Visibility(..), TournamentState(..), Tournament(..)
  )
import Domain.Match (Match(..), MatchStatus(Scheduled), MatchOutcome(..))

import Application.UseCases.CreateTournament (createTournament)
import Application.UseCases.RegisterParticipant (registerParticipant)
import Application.UseCases.GenerateBracket (generateBracket)
import Application.UseCases.StartMatch (startMatch)
import Application.UseCases.RecordMatchResult (recordMatchResult)
import Application.UseCases.CompleteTournament (completeTournament)
import Data.Either (isLeft)

testDbPath :: FilePath
testDbPath = "test/arenaos-test.db"

resetTestDb :: IO ()
resetTestDb = do
  exists <- doesFileExist testDbPath
  if exists then removeFile testDbPath else pure ()

setupSchema :: SQLiteM ()
setupSchema = do
  env <- ask
  liftIO $ initializeSchema (envConnection env)

-- Unwraps a use-case's Either result inside SQLiteM, failing the hspec
-- example with a readable message if it's a Left.
unwrap :: Show e => Either e a -> SQLiteM a
unwrap (Right a) = pure a
unwrap (Left e)  = liftIO $ do
  expectationFailure (show e)
  error "unreachable"

main :: IO ()
main = hspec spec



spec :: Spec
spec = before_ resetTestDb $ do
  describe "Tournament Lifecycle (4-participant golden scenario)" $
    it "runs the full pipeline from creation to completion" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
  

        let participants =
              [ Individual (Player (PlayerName "Alice"))
              , Individual (Player (PlayerName "Bob"))
              , Individual (Player (PlayerName "Carol"))
              , Individual (Player (PlayerName "Dave"))
              ]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Golden Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 4
          }

        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team

        forM_ participants (registerParticipant tid)

        bracketId <- unwrap =<< generateBracket tid
        liftIO $ putStrLn "after generateBracket" 

        -- Semifinals: GenerateBracket should have materialized exactly two.
        semiMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ putStrLn "after listMatchesForBracket" 
        liftIO $ length semiMatches `shouldBe` 2

        forM_ semiMatches $ \m -> do
          _ <- unwrap =<< startMatch (matchId m)
          liftIO $ putStrLn "after startMatch" 
          _ <- unwrap =<< recordMatchResult (matchId m) (Winner (matchCompetitorA m))
          liftIO $ putStrLn "after recordMatchResult" 
          pure ()

        -- The final should now exist, materialized by RecordMatchResult's
        -- advancement logic once both semifinals are complete.
        allMatches <- Repo.listMatchesForBracket bracketId
        let finalMatches = filter (\m -> matchStatus m == Scheduled) allMatches
        liftIO $ length finalMatches `shouldBe` 1
        let finalMatch = head finalMatches

        _ <- unwrap =<< startMatch (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        unwrap =<< completeTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

  describe "Bye-path scenario (3 participants)" $
    it "gives the earliest-registered participant a bye and completes the tournament" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema

        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            carol = Individual (Player (PlayerName "Carol"))
            participants = [alice, bob, carol]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Bye Test Cup"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 3
          }

        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team

        forM_ participants (registerParticipant tid)

        bracketId <- unwrap =<< generateBracket tid

        -- Only Bob-vs-Carol should ever get materialized as a real Match --
        -- Alice's bye node has (Filled Alice, ByeSlot) and never satisfies
        -- readyNodes' both-slots-Filled check.
        semiMatches <- Repo.listMatchesForBracket bracketId
        liftIO $ length semiMatches `shouldBe` 1
        let semiMatch = head semiMatches
        liftIO $ matchCompetitorA semiMatch `shouldBe` bob
        liftIO $ matchCompetitorB semiMatch `shouldBe` carol

        _ <- unwrap =<< startMatch (matchId semiMatch)
        -- Carol wins -- deliberately the "B slot" competitor, not "A".
        _ <- unwrap =<< recordMatchResult (matchId semiMatch) (Winner (matchCompetitorB semiMatch))

        -- The final should now exist, holding Alice (pre-filled by
        -- ByeResolution at generation time) and Carol (just propagated).
        allMatches <- Repo.listMatchesForBracket bracketId
        let finalMatches = filter (\m -> matchStatus m == Scheduled) allMatches
        liftIO $ length finalMatches `shouldBe` 1
        let finalMatch = head finalMatches
        liftIO $ [matchCompetitorA finalMatch, matchCompetitorB finalMatch]
          `shouldMatchList` [alice, carol]

        _ <- unwrap =<< startMatch (matchId finalMatch)
        _ <- unwrap =<< recordMatchResult (matchId finalMatch) (Winner (matchCompetitorA finalMatch))

        unwrap =<< completeTournament tid

      case result of
        Left err         -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right tournament -> tournamentState tournament `shouldBe` Completed

  describe "Error paths" $ do
    it "rejects starting a match that's already been started" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup A"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        forM_ participants (registerParticipant tid)
        bracketId <- unwrap =<< generateBracket tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        _ <- unwrap =<< startMatch (matchId m)
        secondStart <- startMatch (matchId m)
        pure secondStart

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects recording a result before the match is started" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup B"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        forM_ participants (registerParticipant tid)
        bracketId <- unwrap =<< generateBracket tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        recordMatchResult (matchId m) (Winner (matchCompetitorA m))

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects a winner who isn't a competitor in the match" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            eve   = Individual (Player (PlayerName "Eve"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup C"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        case eve of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        forM_ participants (registerParticipant tid)
        otherTid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Unrelated Tournament"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        _ <- registerParticipant otherTid eve
        bracketId <- unwrap =<< generateBracket tid
        matches <- Repo.listMatchesForBracket bracketId
        let m = head matches

        _ <- unwrap =<< startMatch (matchId m)
        recordMatchResult (matchId m) (Winner eve)

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft

    it "rejects completing a tournament with a match still pending" $ do
      result <- runSQLiteM testDbPath $ do
        setupSchema
        let alice = Individual (Player (PlayerName "Alice"))
            bob   = Individual (Player (PlayerName "Bob"))
            participants = [alice, bob]

        tid <- createTournament NewTournament
          { newTournamentName            = TournamentName "Error Test Cup D"
          , newTournamentOrganizer       = OrganizerName "Test Organizer"
          , newTournamentFormat          = SingleElimination
          , newTournamentVisibility      = Public
          , newTournamentMaxParticipants = 2
          }
        forM_ participants $ \p -> case p of
          Individual player -> Repo.savePlayer player
          Squad team         -> Repo.saveTeam team
        forM_ participants (registerParticipant tid)
        _ <- unwrap =<< generateBracket tid

        completeTournament tid

      case result of
        Left err     -> expectationFailure ("runSQLiteM failed: " ++ show err)
        Right inner  -> inner `shouldSatisfy` isLeft