{-|

A 'RawTransaction' represents a single transaction line within a ledger
entry. We call it raw to distinguish from the cached 'Transaction'.

-}

module Ledger.RawTransaction
where
import Ledger.Utils
import Ledger.Types
import Ledger.Amount


rawtransactiontests = TestList [
                      ]

instance Show RawTransaction where show = showLedgerTransaction

showLedgerTransaction :: RawTransaction -> String
showLedgerTransaction t = (showaccountname $ taccount t) ++ " " ++ (showamount $ tamount t) 
    where
      showaccountname = printf "%-22s" . elideRight 22
      showamount = printf "%12s" . showAmountRoundedOrZero

elideRight width s =
    case length s > width of
      True -> take (width - 2) s ++ ".."
      False -> s

autofillTransactions :: [RawTransaction] -> [RawTransaction]
autofillTransactions ts =
    case (length blanks) of
      0 -> ts
      1 -> map balance ts
      otherwise -> error "too many blank transactions in this entry"
    where 
      (normals, blanks) = partition isnormal ts
      isnormal t = (symbol $ currency $ tamount t) /= "AUTO"
      balance t = if isnormal t then t else t{tamount = -(sumLedgerTransactions normals)}

sumLedgerTransactions :: [RawTransaction] -> Amount
sumLedgerTransactions = sum . map tamount

ledgerTransactionSetPrecision :: Int -> RawTransaction -> RawTransaction
ledgerTransactionSetPrecision p (RawTransaction a amt c) = RawTransaction a amt{precision=p} c
