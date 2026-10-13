module Application.UseCases.GetBracket
  ( getBracket
  , GetBracketError(..)
  , BracketView(..)
  ) where

import Data.Bifunctor (first)

import Domain.Bracket (Bracket, BracketNode)
import Domain.BracketLinks (BracketLinks)
import Domain.Match (Match)
import Domain.Tournament (Tournament(..), TournamentId)
import Domain.Ids (UserId)

import Shell.Persistence.Port (TournamentRepository, BracketRepository, MatchRepository)
import qualified Shell.Persistence.Port as Repo

import Application.Internal.Authorization (AuthorizationError, requireVisibleToViewer)

data GetBracketError
  = Unauthorized AuthorizationError
  | BracketNotGenerated
  deriving (Eq, Show)

data BracketView = BracketView
  { viewTournament :: Tournament
  , viewBracket    :: Bracket
  , viewNodes      :: [BracketNode]
  , viewMatches    :: [Match]
  , viewLinks      :: Maybe BracketLinks
  } deriving (Eq, Show)

getBracket
  :: (TournamentRepository m, BracketRepository m, MatchRepository m)
  => Maybe UserId
  -> TournamentId
  -> m (Either GetBracketError BracketView)
getBracket viewer tid = do
  tournament <- Repo.getTournament tid
  case first Unauthorized (requireVisibleToViewer viewer tournament) of
    Left err -> pure (Left err)
    Right () ->
      case tournamentBracket tournament of
        Nothing  -> pure (Left BracketNotGenerated)
        Just bid -> do
          (bracket, nodes) <- Repo.getBracket bid
          
          matches <- Repo.listMatchesForBracket bid
          links <- Repo.getBracketLinks bid
          pure (Right (BracketView tournament bracket nodes matches links))

          