{-# LANGUAGE DeriveGeneric #-}

module TPar.JobMatch where

import Data.Foldable (traverse_)
import Control.Monad (void)
import Control.Applicative ((<|>))
import Data.Binary
import GHC.Generics
import Text.Trifecta

import TPar.Types

data GlobAtom = WildCard
              | Literal String
          deriving (Generic, Show)

instance Binary GlobAtom

type Glob = [GlobAtom]

globAtomToParser :: GlobAtom -> Parser ()
globAtomToParser WildCard    = void anyChar
globAtomToParser (Literal a) = void $ string a

globToParser :: Glob -> Parser ()
globToParser atoms = traverse_ globAtomToParser atoms >> eof

globMatches :: Glob -> String -> Bool
globMatches glob str =
    case parseString (globToParser glob) mempty str of
        Success () -> True
        Failure _  -> False

parseGlob :: Parser Glob
parseGlob = many $ wildCard <|> literal
  where
    wildCard = char '*' >> pure WildCard
    literal  = Literal <$> some (noneOf reserved)

    reserved = "*\""

data JobMatch = NoMatch
              | AllMatch
              | NegMatch JobMatch
              | NameMatch Glob
              | JobIdMatch JobId
              | AltMatch [JobMatch]
              deriving (Generic, Show)

instance Binary JobMatch

jobMatches :: JobMatch -> Job -> Bool
jobMatches NoMatch            _   = False
jobMatches AllMatch           _   = True
jobMatches (NameMatch glob)   job = globMatches glob name
  where JobName name = jobName $ jobRequest job
jobMatches (JobIdMatch jobid) job = jobId job == jobid
jobMatches (AltMatch alts)    job = any (`jobMatches` job) alts

parseJobMatch :: Parser JobMatch
parseJobMatch =
    AltMatch <$> (negMatch <|> nameMatch <|> jobIdMatch) `sepBy1` char ','
  where
    allMatch :: Parser JobMatch
    allMatch = char '*' >> pure AllMatch

    nameMatch :: Parser JobMatch
    nameMatch = do
        string "name="
        NameMatch <$> between (char '"') (char '"') parseGlob

    jobIdMatch :: Parser JobMatch
    jobIdMatch = do
        string "id="
        JobIdMatch . JobId . fromIntegral <$> integer

    negMatch = do
        char '!'
        NegMatch <$> between (char '(') (char ')') parseJobMatch
