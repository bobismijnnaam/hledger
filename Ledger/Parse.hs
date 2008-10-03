{-|

A parser for standard ledger files.  Here's the grammar from the
ledger 2.5 manual:

@
The ledger file format is quite simple, but also very flexible. It supports
many options, though typically the user can ignore most of them. They are
summarized below.  The initial character of each line determines what the
line means, and how it should be interpreted. Allowable initial characters
are:

NUMBER      A line beginning with a number denotes an entry. It may be followed by any
            number of lines, each beginning with whitespace, to denote the entry’s account
            transactions. The format of the first line is:

                    DATE[=EDATE] [*|!] [(CODE)] DESC

            If ‘*’ appears after the date (with optional eﬀective date), it indicates the entry
            is “cleared”, which can mean whatever the user wants it t omean. If ‘!’ appears
            after the date, it indicates d the entry is “pending”; i.e., tentatively cleared from
            the user’s point of view, but not yet actually cleared. If a ‘CODE’ appears in
            parentheses, it may be used to indicate a check number, or the type of the
            transaction. Following these is the payee, or a description of the transaction.
            The format of each following transaction is:

                      ACCOUNT     AMOUNT    [; NOTE]

            The ‘ACCOUNT’ may be surrounded by parentheses if it is a virtual
            transactions, or square brackets if it is a virtual transactions that must
            balance. The ‘AMOUNT’ can be followed by a per-unit transaction cost,
            by specifying ‘ AMOUNT’, or a complete transaction cost with ‘\@ AMOUNT’.
            Lastly, the ‘NOTE’ may specify an actual and/or eﬀective date for the
            transaction by using the syntax ‘[ACTUAL_DATE]’ or ‘[=EFFECTIVE_DATE]’ or
            ‘[ACTUAL_DATE=EFFECtIVE_DATE]’.

=           An automated entry. A value expression must appear after the equal sign.
            After this initial line there should be a set of one or more transactions, just as
            if it were normal entry. If the amounts of the transactions have no commodity,
            they will be applied as modifiers to whichever real transaction is matched by
            the value expression.
 
~           A period entry. A period expression must appear after the tilde.
            After this initial line there should be a set of one or more transactions, just as
            if it were normal entry.

!           A line beginning with an exclamation mark denotes a command directive. It
            must be immediately followed by the command word. The supported commands
            are:

           ‘!include’
                        Include the stated ledger file.
           ‘!account’
                        The account name is given is taken to be the parent of all transac-
                        tions that follow, until ‘!end’ is seen.
           ‘!end’       Ends an account block.
 
;          A line beginning with a colon indicates a comment, and is ignored.
 
Y          If a line begins with a capital Y, it denotes the year used for all subsequent
           entries that give a date without a year. The year should appear immediately
           after the Y, for example: ‘Y2004’. This is useful at the beginning of a file, to
           specify the year for that file. If all entries specify a year, however, this command
           has no eﬀect.
           
 
P          Specifies a historical price for a commodity. These are usually found in a pricing
           history file (see the ‘-Q’ option). The syntax is:

                  P DATE SYMBOL PRICE

N SYMBOL   Indicates that pricing information is to be ignored for a given symbol, nor will
           quotes ever be downloaded for that symbol. Useful with a home currency, such
           as the dollar ($). It is recommended that these pricing options be set in the price
           database file, which defaults to ‘~/.pricedb’. The syntax for this command is:

                  N SYMBOL

        
D AMOUNT   Specifies the default commodity to use, by specifying an amount in the expected
           format. The entry command will use this commodity as the default when none
           other can be determined. This command may be used multiple times, to set
           the default flags for diﬀerent commodities; whichever is seen last is used as the
           default commodity. For example, to set US dollars as the default commodity,
           while also setting the thousands flag and decimal flag for that commodity, use:

                  D $1,000.00

C AMOUNT1 = AMOUNT2
           Specifies a commodity conversion, where the first amount is given to be equiv-
           alent to the second amount. The first amount should use the decimal precision
           desired during reporting:

                  C 1.00 Kb = 1024 bytes

i, o, b, h
           These four relate to timeclock support, which permits ledger to read timelog
           files. See the timeclock’s documentation for more info on the syntax of its
           timelog files.
@

See Tests.hs for sample data.
-}

module Ledger.Parse
where
import qualified Data.Map as Map
import Text.ParserCombinators.Parsec
import Text.ParserCombinators.Parsec.Language
import qualified Text.ParserCombinators.Parsec.Token as P
import System.IO

import Ledger.Utils
import Ledger.Types
import Ledger.Entry (autofillEntry)
import Ledger.Currency (getcurrency)
import Ledger.TimeLog (ledgerFromTimeLog)

-- utils

parseLedgerFile :: String -> IO (Either ParseError RawLedger)
parseLedgerFile "-" = fmap (parse ledgerfile "-") $ hGetContents stdin
parseLedgerFile f   = parseFromFile ledgerfile f
    
parseError :: (Show a) => a -> IO ()
parseError e = do putStr "ledger parse error at "; print e

-- set up token parsing, though we're not yet using these much
ledgerLanguageDef = LanguageDef {
   commentStart   = ""
   , commentEnd     = ""
   , commentLine    = ";"
   , nestedComments = False
   , identStart     = letter <|> char '_'
   , identLetter    = alphaNum <|> oneOf "_':"
   , opStart        = opLetter emptyDef
   , opLetter       = oneOf "!#$%&*+./<=>?@\\^|-~"
   , reservedOpNames= []
   , reservedNames  = []
   , caseSensitive  = False
   }
lexer      = P.makeTokenParser ledgerLanguageDef
whiteSpace = P.whiteSpace lexer
lexeme     = P.lexeme lexer
symbol     = P.symbol lexer
natural    = P.natural lexer
parens     = P.parens lexer
semi       = P.semi lexer
identifier = P.identifier lexer
reserved   = P.reserved lexer
reservedOp = P.reservedOp lexer

-- parsers

ledgerfile :: Parser RawLedger
ledgerfile = ledger <|> ledgerfromtimelog

ledger :: Parser RawLedger
ledger = do
  -- for now these must come first, unlike ledger
  modifier_entries <- many ledgermodifierentry
  periodic_entries <- many ledgerperiodicentry
  --
  entries <- (many ledgerentry) <?> "entry"
  final_comment_lines <- ledgernondatalines
  eof
  return $ RawLedger modifier_entries periodic_entries entries (unlines final_comment_lines)

ledgernondatalines :: Parser [String]
ledgernondatalines = many (ledgerdirective <|> -- treat as comments
                           commentline <|> 
                           blankline)

ledgerdirective :: Parser String
ledgerdirective = char '!' >> restofline <?> "directive"

blankline :: Parser String
blankline =
  do {s <- many1 spacenonewline; newline; return s} <|> 
  do {newline; return ""} <?> "blank line"

commentline :: Parser String
commentline = do
  char ';' <?> "comment line"
  l <- restofline
  return $ ";" ++ l

ledgercomment :: Parser String
ledgercomment = 
    try (do
          char ';'
          many spacenonewline
          many (noneOf "\n")
        ) 
    <|> return "" <?> "comment"

ledgermodifierentry :: Parser ModifierEntry
ledgermodifierentry = do
  char '=' <?> "entry"
  many spacenonewline
  valueexpr <- restofline
  transactions <- ledgertransactions
  return (ModifierEntry valueexpr transactions)

ledgerperiodicentry :: Parser PeriodicEntry
ledgerperiodicentry = do
  char '~' <?> "entry"
  many spacenonewline
  periodexpr <- restofline
  transactions <- ledgertransactions
  return (PeriodicEntry periodexpr transactions)

ledgerentry :: Parser Entry
ledgerentry = do
  preceding <- ledgernondatalines
  date <- ledgerdate <?> "entry"
  status <- ledgerstatus
  code <- ledgercode
-- ledger treats entry comments as part of the description, we will too
--   desc <- many (noneOf ";\n") <?> "description"
--   let description = reverse $ dropWhile (==' ') $ reverse desc
  description <- many (noneOf "\n") <?> "description"
  comment <- ledgercomment
  restofline
  transactions <- ledgertransactions
  return $ autofillEntry $ Entry date status code description comment transactions (unlines preceding)

ledgerdate :: Parser String
ledgerdate = do 
  y <- many1 digit
  char '/'
  m <- many1 digit
  char '/'
  d <- many1 digit
  many1 spacenonewline
  return $ printf "%04s/%02s/%02s" y m d

ledgerstatus :: Parser Bool
ledgerstatus = try (do { char '*'; many1 spacenonewline; return True } ) <|> return False

ledgercode :: Parser String
ledgercode = try (do { char '('; code <- anyChar `manyTill` char ')'; many1 spacenonewline; return code } ) <|> return ""

ledgertransactions :: Parser [RawTransaction]
ledgertransactions = (ledgertransaction <?> "transaction") `manyTill` (do {newline <?> "blank line"; return ()} <|> eof)

ledgertransaction :: Parser RawTransaction
ledgertransaction = do
  many1 spacenonewline
  account <- ledgeraccount
  amount <- ledgeramount
  many spacenonewline
  comment <- ledgercomment
  restofline
  return (RawTransaction account amount comment)

-- | account names may have single spaces in them, and are terminated by two or more spaces
ledgeraccount :: Parser String
ledgeraccount = 
    many1 ((alphaNum <|> char ':' <|> char '/' <|> char '_' <?> "account name") 
           <|> try (do {spacenonewline; do {notFollowedBy spacenonewline; return ' '}} <?> "double space"))

ledgeramount :: Parser Amount
ledgeramount = 
    try (do
          many1 spacenonewline
          c <- many (noneOf "-.0123456789;\n") <?> "currency"
          q <- many1 (oneOf "-.,0123456789") <?> "quantity"
          let q' = stripcommas $ striptrailingpoint q
          let (int,frac) = break (=='.') q'
          let precision = length $ dropWhile (=='.') frac
          return (Amount (getcurrency c) (read q') precision)
        ) 
    <|> return (Amount (Currency "AUTO" 0) 0 0)
    where 
      stripcommas = filter (',' /=)
      striptrailingpoint = reverse . dropWhile (=='.') . reverse

spacenonewline :: Parser Char
spacenonewline = satisfy (\c -> c `elem` " \v\f\t")

restofline :: Parser String
restofline = anyChar `manyTill` newline

whiteSpace1 :: Parser ()
whiteSpace1 = do space; whiteSpace


{-| timelog file parser 

Here is the timelog grammar, from timeclock.el 2.6:

@
A timelog contains data in the form of a single entry per line.
Each entry has the form:

  CODE YYYY/MM/DD HH:MM:SS [COMMENT]

CODE is one of: b, h, i, o or O.  COMMENT is optional when the code is
i, o or O.  The meanings of the codes are:

  b  Set the current time balance, or \"time debt\".  Useful when
     archiving old log data, when a debt must be carried forward.
     The COMMENT here is the number of seconds of debt.

  h  Set the required working time for the given day.  This must
     be the first entry for that day.  The COMMENT in this case is
     the number of hours in this workday.  Floating point amounts
     are allowed.

  i  Clock in.  The COMMENT in this case should be the name of the
     project worked on.

  o  Clock out.  COMMENT is unnecessary, but can be used to provide
     a description of how the period went, for example.

  O  Final clock out.  Whatever project was being worked on, it is
     now finished.  Useful for creating summary reports.

example:

i 2007/03/10 12:26:00 hledger
o 2007/03/10 17:26:02
@
-}
timelog :: Parser TimeLog
timelog = do
  entries <- many timelogentry
  eof
  return $ TimeLog entries

timelogentry :: Parser TimeLogEntry
timelogentry = do
  code <- oneOf "bhioO"
  many1 spacenonewline
  date <- ledgerdate
  time <- many $ oneOf "0123456789:"
  let datetime = date ++ " " ++ time
  many spacenonewline
  comment <- restofline
  return $ TimeLogEntry code datetime comment

ledgerfromtimelog :: Parser RawLedger
ledgerfromtimelog = do 
  tl <- timelog
  return $ ledgerFromTimeLog tl
