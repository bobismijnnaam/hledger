{-|
Convert account data in CSV format (eg downloaded from a bank) to ledger
format, and print it on stdout. See the manual for more details.
-}

module Commands.Convert where
import Options (Opt(Debug))
import Ledger.Types (Ledger,AccountName,LedgerTransaction(..),Posting(..),PostingType(..))
import Ledger.Utils (strip, spacenonewline, restofline)
import Ledger.Parse (someamount, emptyCtx, ledgeraccountname)
import Ledger.Amount (nullmixedamt)
import System.IO (stderr)
import Text.CSV (parseCSVFromFile, printCSV)
import Text.Printf (hPrintf)
import Text.RegexPR (matchRegexPR)
import Data.Maybe
import Ledger.Dates (firstJust, showDate, parsedate)
import Locale (defaultTimeLocale)
import Data.Time.Format (parseTime)
import Control.Monad (when, guard)
import Safe (readDef, readMay)
import System.FilePath.Posix (takeBaseName)
import Text.ParserCombinators.Parsec


convert :: [Opt] -> [String] -> Ledger -> IO ()
convert opts args _ = do
  when (length args /= 2) (error "please specify a csv data file and conversion rules file.")
  let debug = Debug `elem` opts
      [csvfile,rulesfile] = args
  csvparse <- parseCSVFromFile csvfile
  let records = case csvparse of
                  Left e -> error $ show e
                  Right rs -> reverse $ filter (/= [""]) rs
  rulesstr <- readFile rulesfile
  let rules = case parseCsvRules (takeBaseName csvfile) rulesstr of
                  Left e -> error $ show e
                  Right r -> r
  when debug $ hPrintf stderr "using csv conversion rules file %s\n" rulesfile
  when debug $ hPrintf stderr "%s\n" (show rules)
  mapM_ (printTxn debug rules) records

{- |
A set of data definitions and account-matching patterns sufficient to
convert a particular CSV data file into meaningful ledger transactions. See above.
-}
data CsvRules = CsvRules {
      dateField :: Maybe FieldPosition,
      statusField :: Maybe FieldPosition,
      codeField :: Maybe FieldPosition,
      descriptionField :: Maybe FieldPosition,
      amountField :: Maybe FieldPosition,
      currencyField :: Maybe FieldPosition,
      baseCurrency :: Maybe String,
      baseAccount :: AccountName,
      accountRules :: [AccountRule]
} deriving (Show)

nullrules = CsvRules {
      dateField=Nothing,
      statusField=Nothing,
      codeField=Nothing,
      descriptionField=Nothing,
      amountField=Nothing,
      currencyField=Nothing,
      baseCurrency=Nothing,
      baseAccount="unknown",
      accountRules=[]
}

type FieldPosition = Int

type AccountRule = (
   [(String, Maybe String)] -- list of regex match patterns with optional replacements
  ,AccountName              -- account name to use for a transaction matching this rule
  )

type CsvRecord = [String]

-- rules file parser

parseCsvRules :: String -> String -> Either ParseError CsvRules
parseCsvRules basefilename s = runParser csvrulesP nullrules{baseAccount=basefilename} "" s

csvrulesP :: GenParser Char CsvRules CsvRules
csvrulesP = do
  optional blanklines
  many definitions
  r <- getState
  ars <- many accountrule
  optional blanklines
  eof
  return r{accountRules=ars}

-- | Real independent parser choice, even when alternative matches share a prefix.
choice' parsers = choice $ map try (init parsers) ++ [last parsers]

definitions :: GenParser Char CsvRules ()
definitions = do
  choice' [
    datefield
   ,statusfield
   ,codefield
   ,descriptionfield
   ,amountfield
   ,currencyfield
   ,basecurrency
   ,baseaccount
   ] <?> "definition"
  return ()

datefield = do
  string "date-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{dateField=readMay v}

codefield = do
  string "code-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{codeField=readMay v}

statusfield = do
  string "status-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{statusField=readMay v}

descriptionfield = do
  string "description-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{descriptionField=readMay v}

amountfield = do
  string "amount-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{amountField=readMay v}

currencyfield = do
  string "currency-field"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{currencyField=readMay v}

basecurrency = do
  string "currency"
  many1 spacenonewline
  v <- restofline
  r <- getState
  setState r{baseCurrency=Just v}

baseaccount = do
  string "base-account"
  many1 spacenonewline
  v <- ledgeraccountname
  optional newline
  r <- getState
  setState r{baseAccount=v}

accountrule :: GenParser Char CsvRules AccountRule
accountrule = do
  blanklines
  pats <- many1 matchreplacepattern
  guard $ length pats >= 2
  let pats' = init pats
      acct = either (fail.show) id $ runParser ledgeraccountname () "" $ fst $ last pats
  return (pats',acct)

blanklines = many1 blankline >> return ()

blankline = many spacenonewline >> newline >> return () <?> "blank line"

matchreplacepattern = do
  matchpat <- many1 (noneOf "=\n")
  replpat <- optionMaybe $ do {char '='; many $ noneOf "\n"}
  newline
  return (matchpat,replpat)

printTxn :: Bool -> CsvRules -> CsvRecord -> IO ()
printTxn debug rules rec = do
  when debug $ hPrintf stderr "csv: %s" (printCSV [rec])
  putStr $ show $ transactionFromCsvRecord rules rec

-- csv record conversion

transactionFromCsvRecord :: CsvRules -> CsvRecord -> LedgerTransaction
transactionFromCsvRecord rules fields =
  let 
      date = parsedate $ normaliseDate $ maybe "1900/1/1" (fields !!) (dateField rules)
      status = maybe False (null . strip . (fields !!)) (statusField rules)
      code = maybe "" (fields !!) (codeField rules)
      desc = maybe "" (fields !!) (descriptionField rules)
      comment = ""
      precomment = ""
      amountstr = maybe "" (fields !!) (amountField rules)
      amountstr' = strnegate amountstr where strnegate ('-':s) = s
                                             strnegate s = '-':s
      currency = maybe (fromMaybe "" $ baseCurrency rules) (fields !!) (currencyField rules)
      amountstr'' = currency ++ amountstr'
      amountparse = runParser someamount emptyCtx "" amountstr''
      amount = either (const nullmixedamt) id amountparse
      unknownacct | (readDef 0 amountstr' :: Double) < 0 = "income:unknown"
                  | otherwise = "expenses:unknown"
      (acct,newdesc) = identify (accountRules rules) unknownacct desc
  in
    LedgerTransaction {
              ltdate=date,
              lteffectivedate=Nothing,
              ltstatus=status,
              ltcode=code,
              ltdescription=newdesc,
              ltcomment=comment,
              ltpreceding_comment_lines=precomment,
              ltpostings=[
                   Posting {
                     pstatus=False,
                     paccount=acct,
                     pamount=amount,
                     pcomment="",
                     ptype=RegularPosting
                   },
                   Posting {
                     pstatus=False,
                     paccount=baseAccount rules,
                     pamount=(-amount),
                     pcomment="",
                     ptype=RegularPosting
                   }
                  ]
            }

-- | Convert some date string with unknown format to YYYY/MM/DD.
normaliseDate :: String -> String
normaliseDate s = maybe "0000/00/00" showDate $
              firstJust
              [parseTime defaultTimeLocale "%Y/%m/%e" s
               -- can't parse a month without leading 0, try adding one
              ,parseTime defaultTimeLocale "%Y/%m/%e" (take 5 s ++ "0" ++ drop 5 s)
              ,parseTime defaultTimeLocale "%Y-%m-%e" s
              ,parseTime defaultTimeLocale "%Y-%m-%e" (take 5 s ++ "0" ++ drop 5 s)
              ,parseTime defaultTimeLocale "%m/%e/%Y" s
              ,parseTime defaultTimeLocale "%m/%e/%Y" ('0':s)
              ,parseTime defaultTimeLocale "%m-%e-%Y" s
              ,parseTime defaultTimeLocale "%m-%e-%Y" ('0':s)
              ]

-- | Apply account matching rules to a transaction description to obtain
-- the most appropriate account and a new description.
identify :: [AccountRule] -> String -> String -> (String,String)
identify rules defacct desc | null matchingrules = (defacct,desc)
                            | otherwise = (acct,newdesc)
    where
      matchingrules = filter ismatch rules :: [AccountRule]
          where ismatch = any (isJust . flip matchregex desc . fst) . fst
      (prs,acct) = head matchingrules
      mrs = filter (isJust . fst) $ map (\(p,r) -> (matchregex p desc, r)) prs
      (m,repl) = head mrs
      matched = fst $ fst $ fromJust m
      newdesc = fromMaybe matched repl

matchregex = matchRegexPR . ("(?i)" ++)

