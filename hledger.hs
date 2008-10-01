#!/usr/bin/env runhaskell
{-|
hledger - a ledger-compatible text-based accounting tool.

Copyright (c) 2007-2008 Simon Michael <simon@joyful.com>
Released under GPL version 3 or later.

This is a minimal haskell clone of John Wiegley's ledger
<http://newartisans.com/software/ledger.html>.  hledger generates
simple ledger-compatible register & balance reports from a standard
ledger file, and demonstrates a (naive) purely functional
implementation of ledger.

Code overview: 

The early code defined types in each module and so was very strictly
layered. Since then, all data types have been moved to "Types" at the
bottom, but the original modules are still used to group related
functions/methods. Here is the approximate module hierarchy:

@
hledger ("Main")
 "Options"
 "Tests"
  "Parse"
   "Models"
    "TimeLog"
    "Ledger"
     "Account"
      "Transaction"
     "LedgerFile"
      "LedgerEntry"
       "LedgerTransaction"
        "AccountName"
        "Amount"
         "Currency"
          "Types"
           "Utils"
@
-}

module Main
where
import System
import Text.ParserCombinators.Parsec (ParseError)
import qualified Data.Map as Map (lookup)

import Options
import Models
import Parse
import Tests
import Utils hiding (test)


main :: IO ()
main = do
  (opts, (cmd:args)) <- getArgs >>= parseOptions
  let pats = parsePatternArgs args
  run cmd opts pats
  where run cmd opts pats
            | Help `elem` opts            = putStr usage
            | cmd `isPrefixOf` "test"     = test     opts pats
            | cmd `isPrefixOf` "print"    = doWithFilteredLedger opts pats printentries
            | cmd `isPrefixOf` "register" = doWithFilteredLedger opts pats printregister
            | cmd `isPrefixOf` "balance"  = balance  opts pats
            | otherwise                   = putStr usage

doWithFilteredLedger :: [Flag] -> FilterPatterns -> (Ledger -> IO ()) -> IO ()
doWithFilteredLedger opts pats cmd = do
    ledgerFilePath opts >>= parseLedgerFile >>= doWithParsed pats cmd

doWithParsed :: FilterPatterns -> (Ledger -> IO ()) -> (Either ParseError LedgerFile) -> IO ()
doWithParsed pats cmd parsed = do
  case parsed of Left e -> parseError e
                 Right l -> cmd $ cacheLedger pats l 

type Command = [Flag] -> FilterPatterns -> IO ()

test :: Command
test opts pats = do 
  Tests.hunit
  Tests.quickcheck
  return ()

printentries l = putStr $ showEntries $ setprecisions $ entries $ rawledger l
    where setprecisions = map (entrySetPrecision (lprecision l))
      
printregister l = putStr $ showTransactionsWithBalances 
                  (sortBy (comparing date) $ ledgerTransactions l)
                  nullamt{precision=lprecision l}

balance :: Command
balance opts pats = do
  doWithFilteredLedger opts pats printbalance
    where
      printbalance l =
          putStr $ showLedgerAccounts l depth
              where 
                showsubs = (ShowSubs `elem` opts)
                depth = case (pats, showsubs) of
                          -- when there are no account patterns and no -s,
                          -- show only to depth 1. (This was clearer and more
                          -- correct when FilterPatterns used maybe.)
                          ((wildcard,_), False) -> 1
                          otherwise  -> 9999

-- helpers for interacting in ghci

-- | return a Ledger parsed from the file your LEDGER environment variable
-- points to or (WARNING) an empty one if there was a problem.
myledger :: IO Ledger
myledger = do
  parsed <- ledgerFilePath [] >>= parseLedgerFile
  let ledgerfile = either (\_ -> LedgerFile [] [] [] "") id parsed
  return $ cacheLedger (parsePatternArgs []) ledgerfile

-- | return a Ledger parsed from the given file path
ledgerfromfile :: String -> IO Ledger
ledgerfromfile f = do
  parsed <- ledgerFilePath [File f] >>= parseLedgerFile
  let ledgerfile = either (\_ -> LedgerFile [] [] [] "") id parsed
  return $ cacheLedger (parsePatternArgs []) ledgerfile

accountnamed :: AccountName -> IO Account
accountnamed a = myledger >>= (return . fromMaybe nullacct . Map.lookup a . accounts)


--clearedBalanceToDate :: String -> Amount

{-
ghci examples:

$ ghci hledger.hs
GHCi, version 6.8.2: http://www.haskell.org/ghc/  :? for help
Loading package base ... linking ... done.
Ok, modules loaded: Utils, Main, Tests, Parse, Models, Ledger, LedgerFile, LedgerEntry, Amount, Currency, Types, LedgerTransaction, AccountName, Transaction, Account, TimeLog, Options.
Prelude Main> l <- myledger
<..snip..>
Ledger with 628 entries, 128 accounts
Prelude Main> 

$ ghci hledger.hs
> l <- myledger
> putStr $ drawTree $ treemap show $ accountnametree l
> putStr $ showLedgerAccounts l 1
> printregister l
> import Types
> accounts l
> accountnamed "assets"


-}
