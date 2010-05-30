{-|
Convert account data in CSV format (eg downloaded from a bank) to ledger
format, and print it on stdout. See the manual for more details.
-}

module Hledger.Cli.Commands.Convert where
import Hledger.Cli.Options (Opt(Debug))
import Hledger.Cli.Version (versionstr)
import Hledger.Data.Types (Journal,AccountName,Transaction(..),Posting(..),PostingType(..))
import Hledger.Data.Utils (strip, spacenonewline, restofline, parseWithCtx, assertParse, assertParseEqual)
import Hledger.Read.Common (emptyCtx)
import Hledger.Read.Journal (someamount,ledgeraccountname)
import Hledger.Data.Amount (nullmixedamt)
import Safe (atDef, maximumDef)
import System.IO (stderr)
import Text.CSV (parseCSVFromFile, printCSV)
import Text.Printf (hPrintf)
import Text.RegexPR (matchRegexPR, gsubRegexPR)
import Data.Maybe
import Hledger.Data.Dates (firstJust, showDate, parsedate)
import System.Locale (defaultTimeLocale)
import Data.Time.Format (parseTime)
import Control.Monad (when, guard, liftM)
import Safe (readDef, readMay)
import System.Directory (doesFileExist)
import System.Exit (exitFailure)
import System.FilePath.Posix (takeBaseName, replaceExtension)
import Text.ParserCombinators.Parsec
import Test.HUnit


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
} deriving (Show, Eq)

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


-- | Read the CSV file named as an argument and print equivalent journal transactions,
-- using/creating a .rules file.
convert :: [Opt] -> [String] -> Journal -> IO ()
convert opts args _ = do
  when (null args) $ error "please specify a csv data file."
  let csvfile = head args
  csvparse <- parseCSVFromFile csvfile
  let records = case csvparse of
                  Left e -> error $ show e
                  Right rs -> reverse $ filter (/= [""]) rs
  let debug = Debug `elem` opts
      rulesfile = rulesFileFor csvfile
  exists <- doesFileExist rulesfile
  if (not exists) then do
                  hPrintf stderr "creating conversion rules file %s, edit this file for better results\n" rulesfile
                  writeFile rulesfile initialRulesFileContent
   else
      hPrintf stderr "using conversion rules file %s\n" rulesfile
  rules <- liftM (either (error.show) id) $ parseCsvRulesFile rulesfile
  when debug $ hPrintf stderr "rules: %s\n" (show rules)
  let requiredfields = max 2 (maxFieldIndex rules + 1)
      badrecords = take 1 $ filter ((< requiredfields).length) records
  if null badrecords
   then mapM_ (printTxn debug rules) records
   else do
     hPrintf stderr (unlines [
                      "Warning, at least one CSV record does not contain a field referenced by the"
                     ,"conversion rules file, or has less than two fields. Are you converting a"
                     ,"valid CSV file ? First bad record:\n%s"
                     ]) (show $ head badrecords)
     exitFailure

-- | The highest (0-based) field index referenced in the field
-- definitions, or -1 if no fields are defined.
maxFieldIndex :: CsvRules -> Int
maxFieldIndex r = maximumDef (-1) $ catMaybes [
                   dateField r
                  ,statusField r
                  ,codeField r
                  ,descriptionField r
                  ,amountField r
                  ,currencyField r
                  ]

rulesFileFor :: FilePath -> FilePath
rulesFileFor csvfile = replaceExtension csvfile ".rules"

initialRulesFileContent :: String
initialRulesFileContent =
    "# csv conversion rules file generated by hledger "++versionstr++"\n" ++
    "# Add rules to this file for more accurate conversion, see\n"++
    "# http://hledger.org/MANUAL.html#convert\n" ++
    "\n" ++
    "base-account assets:bank:checking\n" ++
    "date-field 0\n" ++
    "description-field 4\n" ++
    "amount-field 1\n" ++
    "currency $\n" ++
    "\n" ++
    "# account-assigning rules\n" ++
    "\n" ++
    "SPECTRUM\n" ++
    "expenses:health:gym\n" ++
    "\n" ++
    "ITUNES\n" ++
    "BLKBSTR=BLOCKBUSTER\n" ++
    "expenses:entertainment\n" ++
    "\n" ++
    "(TO|FROM) SAVINGS\n" ++
    "assets:bank:savings\n"

-- rules file parser

parseCsvRulesFile :: FilePath -> IO (Either ParseError CsvRules)
parseCsvRulesFile f = do
  s <- readFile f
  return $ parseCsvRules f s

parseCsvRules :: FilePath -> String -> Either ParseError CsvRules
parseCsvRules rulesfile s = runParser csvrulesfile nullrules{baseAccount=takeBaseName rulesfile} rulesfile s

csvrulesfile :: GenParser Char CsvRules CsvRules
csvrulesfile = do
  many blankorcommentline
  many definitions
  r <- getState
  ars <- many accountrule
  many blankorcommentline
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
   ,commentline
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
  many blankorcommentline
  pats <- many1 matchreplacepattern
  guard $ length pats >= 2
  let pats' = init pats
      acct = either (fail.show) id $ runParser ledgeraccountname () "" $ fst $ last pats
  many blankorcommentline
  return (pats',acct)
 <?> "account rule"

blanklines = many1 blankline >> return ()

blankline = many spacenonewline >> newline >> return () <?> "blank line"

commentchar = oneOf ";#"

commentline = many spacenonewline >> commentchar >> restofline >> return () <?> "comment line"

blankorcommentline = choice' [blankline, commentline]

matchreplacepattern = do
  notFollowedBy commentchar
  matchpat <- many1 (noneOf "=\n")
  replpat <- optionMaybe $ do {char '='; many $ noneOf "\n"}
  newline
  return (matchpat,replpat)

printTxn :: Bool -> CsvRules -> CsvRecord -> IO ()
printTxn debug rules rec = do
  when debug $ hPrintf stderr "record: %s" (printCSV [rec])
  putStr $ show $ transactionFromCsvRecord rules rec

-- csv record conversion

transactionFromCsvRecord :: CsvRules -> CsvRecord -> Transaction
transactionFromCsvRecord rules fields =
  let 
      date = parsedate $ normaliseDate $ maybe "1900/1/1" (atDef "" fields) (dateField rules)
      status = maybe False (null . strip . (atDef "" fields)) (statusField rules)
      code = maybe "" (atDef "" fields) (codeField rules)
      desc = maybe "" (atDef "" fields) (descriptionField rules)
      comment = ""
      precomment = ""
      amountstr = maybe "" (atDef "" fields) (amountField rules)
      amountstr' = strnegate amountstr where strnegate ('-':s) = s
                                             strnegate s = '-':s
      currency = maybe (fromMaybe "" $ baseCurrency rules) (atDef "" fields) (currencyField rules)
      amountstr'' = currency ++ amountstr'
      amountparse = runParser someamount emptyCtx "" amountstr''
      amount = either (const nullmixedamt) id amountparse
      unknownacct | (readDef 0 amountstr' :: Double) < 0 = "income:unknown"
                  | otherwise = "expenses:unknown"
      (acct,newdesc) = identify (accountRules rules) unknownacct desc
      t = Transaction {
              tdate=date,
              teffectivedate=Nothing,
              tstatus=status,
              tcode=code,
              tdescription=newdesc,
              tcomment=comment,
              tpreceding_comment_lines=precomment,
              tpostings=[
                   Posting {
                     pstatus=False,
                     paccount=acct,
                     pamount=amount,
                     pcomment="",
                     ptype=RegularPosting,
                     ptransaction=Just t
                   },
                   Posting {
                     pstatus=False,
                     paccount=baseAccount rules,
                     pamount=(-amount),
                     pcomment="",
                     ptype=RegularPosting,
                     ptransaction=Just t
                   }
                  ]
            }
  in t

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
          where ismatch = any (isJust . flip matchRegexPR (caseinsensitive desc) . fst) . fst
      (prs,acct) = head matchingrules
      p_ms_r = filter (\(_,m,_) -> isJust m) $ map (\(p,r) -> (p, matchRegexPR (caseinsensitive p) desc, r)) prs
      (p,_,r) = head p_ms_r
      newdesc = case r of Just rpat -> gsubRegexPR (caseinsensitive p) rpat desc
                          Nothing   -> desc

caseinsensitive = ("(?i)"++)

tests_Convert = TestList [

   "convert rules parsing: empty file" ~: do
     -- let assertMixedAmountParse parseresult mixedamount =
     --         (either (const "parse error") showMixedAmountDebug parseresult) ~?= (showMixedAmountDebug mixedamount)
    assertParseEqual (parseCsvRules "unknown" "") nullrules

  ,"convert rules parsing: accountrule" ~: do
     assertParseEqual (parseWithCtx nullrules accountrule "A\na\n") -- leading blank line required
                 ([("A",Nothing)], "a")

  ,"convert rules parsing: trailing comments" ~: do
     assertParse (parseWithCtx nullrules csvrulesfile "A\na\n# \n#\n")

  ,"convert rules parsing: trailing blank lines" ~: do
     assertParse (parseWithCtx nullrules csvrulesfile "A\na\n\n  \n")

  -- not supported
  -- ,"convert rules parsing: no final newline" ~: do
  --    assertParse (parseWithCtx nullrules csvrulesfile "A\na")
  --    assertParse (parseWithCtx nullrules csvrulesfile "A\na\n# \n#")
  --    assertParse (parseWithCtx nullrules csvrulesfile "A\na\n\n  ")

                 -- (nullrules{
                 --   -- dateField=Maybe FieldPosition,
                 --   -- statusField=Maybe FieldPosition,
                 --   -- codeField=Maybe FieldPosition,
                 --   -- descriptionField=Maybe FieldPosition,
                 --   -- amountField=Maybe FieldPosition,
                 --   -- currencyField=Maybe FieldPosition,
                 --   -- baseCurrency=Maybe String,
                 --   -- baseAccount=AccountName,
                 --   accountRules=[
                 --        ([("A",Nothing)], "a")
                 --       ]
                 --  })

  ]