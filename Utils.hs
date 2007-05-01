module Utils (
              module Utils,
              module Data.List,
              module Data.Tree,
              module Text.Printf,
              module Text.Regex,
              module Debug.Trace,
              module Test.QuickCheck,
              module Test.HUnit
             )
where
import Data.List
import Data.Tree
import Text.Printf
import Text.Regex
import Debug.Trace
import Test.QuickCheck hiding (test, Testable)
import Test.HUnit


splitAtElement :: Eq a => a -> [a] -> [[a]]
splitAtElement e l = 
    case dropWhile (e==) l of
      [] -> []
      l' -> first : splitAtElement e rest
        where
          (first,rest) = break (e==) l'

-- testing support


-- tree tools

root = rootLabel
branches = subForest

-- remove all nodes past a certain depth
treeprune :: Int -> Tree a -> Tree a
treeprune 0 t = Node (root t) []
treeprune d t = 
    Node (root t) (map (treeprune $ d-1) $ branches t)

-- apply f to all tree nodes
treemap :: (a -> b) -> Tree a -> Tree b
treemap f t = Node (f $ root t) (map (treemap f) $ branches t)

-- remove all subtrees whose nodes do not fulfill predicate
treefilter :: (a -> Bool) -> Tree a -> Tree a
treefilter f t = Node 
                 (root t) 
                 (map (treefilter f) $ filter (treeany f) $ branches t)
    
-- is predicate true in any node of tree ?
treeany :: (a -> Bool) -> Tree a -> Bool
treeany f t = (f $ root t) || (any (treeany f) $ branches t)
    
-- treedrop -- remove the leaves which do fulfill predicate. 
-- treedropall -- do this repeatedly.
