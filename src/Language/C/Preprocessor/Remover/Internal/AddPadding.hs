{-# LANGUAGE ViewPatterns #-}

{-|
Module      : Language.C.Preprocessor.Remover.Internal.AddPadding
Description : Padding of the Cpp output
Copyright   : (c) Carlo Nucera, 2016
License     : BSD3
Maintainer  : meditans@gmail.com
Stability   : experimental
Portability : POSIX

After cpp preprocessing, the file is left by the compilation pipeline in the
output format of the @cpp@ program, described in
<https://gcc.gnu.org/onlinedocs/cpp/Preprocessor-Output.html this section> of
the C Preprocessor manual.

By default, the @cpp@ program inserts blank lines to preserve line numbering,
but only if the number of blank lines to be created is not too high (<6 or so).
Otherwise a linemarker is created, to reduce the size of the generated file, of
the form:

@
# linenum filename flags
@

As cpp doesn't have an option to output only blank lines and keeping the line
numbering, the following functions parse a file with linemarkers separating it
in `CppOutputComponents` (the source chunks between the linemarkers), and pad
them with the appropriate amount of blank lines.
-}

module Language.C.Preprocessor.Remover.Internal.AddPadding
  (
  -- * Entry point for padding
    addPadding
  -- * Data Types
  , LineMarker (..)
  , isLineMarker
  , parseLineMarker
  , CppOutputComponent (..)
  -- * Stages of padding
  , parseCppOutputComponents
  , discardUnusefulComponents
  , reconstructSource
  ) where

import Data.Char       (isDigit)
import Data.List       (isPrefixOf, isSuffixOf)
import Data.List.Extra (repeatedly)

--------------------------------------------------------------------------------
-- Entry point for padding
--------------------------------------------------------------------------------

-- | Substitutes the lineMarker in the content of a file with the appropriate
-- blank line padding.
addPadding :: FilePath -> String -> String
addPadding fp = unlines
              . reconstructSource
              . discardUnusefulComponents fp
              . parseCppOutputComponents
              . lines

--------------------------------------------------------------------------------
-- Data Types
--------------------------------------------------------------------------------

-- | A 'LineMarker' follows the structure described
-- <https://gcc.gnu.org/onlinedocs/cpp/Preprocessor-Output.html here>. We only
-- retain the linenumber and the file the line is referring to. Note that the
-- filename is surrounded by quotation marks in the cpp output, but not in this
-- representation.
data LineMarker = LineMarker { beginsAtLine :: Int
                             , filePath     :: FilePath
                             } deriving (Show)
-- |
-- >>> isLineMarker "# 42 \"/path/to/file\""
-- True
isLineMarker :: String -> Bool
isLineMarker (words -> hash:number:fp:_) = hash == "#"
                                        && all isDigit number
                                        && isPrefixOf "\"" fp
                                        && isSuffixOf "\"" fp
isLineMarker _                           = False

-- |
-- >>> parseLineMarker "# 42 \"/path/to/file\""
-- LineMarker {beginsAtLine = 42, filePath = "/path/to/file"}
parseLineMarker :: String -> LineMarker
parseLineMarker s = LineMarker (read $ words s !! 1) (unquote $ words s !! 2)
  where
    unquote = tail . init

-- | A 'CppOutputComponent' is constituted by a 'LineMarker' and the block of
-- code till the next 'LineMarker'.
data CppOutputComponent = CppOutputComponent { lineMarker  :: LineMarker
                                             , sourceBlock :: [String]
                                             } deriving (Show)

--------------------------------------------------------------------------------
-- Stages of padding
--------------------------------------------------------------------------------

-- | Given the lines of a file, parses the CppOutputComponents. Note that a file
-- that doesn't need cpp preprocessing doesn't have any 'LineMarker'. In that
-- case a dummy component is created, with an empty path.

parseCppOutputComponents :: [String] -> [CppOutputComponent]
parseCppOutputComponents ss
  | any isLineMarker ss =
    flip repeatedly ss $
    \ls ->
       let (content, rest) = span (not . isLineMarker) (tail ls)
           cppComponent = CppOutputComponent (parseLineMarker $ head ls) content
       in (cppComponent, rest)
  | otherwise = [CppOutputComponent (LineMarker 1 "") ss]

-- | Discard the parts of cpp output which correspond to cpp include files. If
-- there's a unique component then we return that one, otherwise we return all
-- the components relative to our file other than the first (which has no real
-- meaning).
discardUnusefulComponents :: FilePath -> [CppOutputComponent] -> [CppOutputComponent]
discardUnusefulComponents _ [] =
  error
    "The function discardUnusefulComponents expects a non-empty list of components"
discardUnusefulComponents _ [c] = [c]
discardUnusefulComponents fp cs = filter ((== fp) . filePath . lineMarker) cs

-- | Adds padding to the source blocks to mantain the correct line numbers of
-- the source code.
reconstructSource :: [CppOutputComponent] -> [String]
reconstructSource = sourceBlock . foldr1 combine
  where
    combine (CppOutputComponent lm1 c1) (CppOutputComponent lm2 c2) =
      let padding = (beginsAtLine lm2 - beginsAtLine lm1 - length c1)
      in CppOutputComponent lm1 (c1 ++ replicate padding "" ++ c2)

