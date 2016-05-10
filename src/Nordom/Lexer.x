{
{-# LANGUAGE OverloadedStrings #-}

-- | Lexing logic for the Nordom language
module Nordom.Lexer (
    -- * Lexer
    lexExpr,

    -- * Types
    Token(..),
    Position(..),
    LocatedToken(..)
    ) where

import Control.Monad.Trans.State.Strict (State)
import Data.Bits (shiftR, (.&.))
import Data.Char (ord, digitToInt, isDigit)
import Data.Int (Int64)
import Data.Text.Lazy (Text)
import Data.Word (Word8)
import Filesystem.Path.CurrentOS (FilePath, fromText)
import Lens.Family.State.Strict ((.=), (+=))
import Pipes (Producer, for, lift, yield)
import Prelude hiding (FilePath)

import qualified Control.Monad.Trans.State.Strict as State
import qualified Data.Text.Lazy                   as Text

}

$digit = 0-9

-- Same as Haskell
$opchar = [\!\#\$\%\&\*\+\.\/\<\=\>\?\@\\\^\|\-\~]

$fst   = [A-Za-z_]
$label = [A-Za-z0-9_]

$nonwhite       = ~$white
$whiteNoNewline = $white # \n

$path = [$label \\\/\.]

tokens :-

    $whiteNoNewline+                  ;
    \n                              { \_    -> lift (do
                                        line   += 1
                                        column .= 0 )                          }
    "--".*                          ;
    "("                             { \_    -> yield OpenParen                 }
    ")"                             { \_    -> yield CloseParen                }
    "{"                             { \_    -> yield OpenBrace                 }
    "}"                             { \_    -> yield CloseBrace                }
    "[nil"                          { \_    -> yield OpenList                  }
    "[id"                           { \_    -> yield OpenPath                  }
    "]"                             { \_    -> yield CloseBracket              }
    ","                             { \_    -> yield Comma                     }
    ":"                             { \_    -> yield Colon                     }
    ";"                             { \_    -> yield Semicolon                 }
    "@"                             { \_    -> yield At                        }
    "*"                             { \_    -> yield Star                      }
    "BOX" | "□"                     { \_    -> yield Box                       }
    "->" | "→"                      { \_    -> yield Arrow                     }
    "<-" | "←"                      { \_    -> yield LArrow                    }
    "\/" | "|~|" | "forall" | "∀" | "Π" { \_ -> yield Pi                       }
    "\" | "λ"                       { \_    -> yield Lambda                    }
    "="                             { \_    -> yield Equals                    }
    "in"                            { \_    -> yield In                        }
    "do"                            { \_    -> yield Do                        }
    "#Nat"                          { \_    -> yield Nat                       }
    "#List"                         { \_    -> yield List                      }
    "#Cmd"                          { \_    -> yield Cmd                       }
    "#Path"                         { \_    -> yield Path                      }
    $digit+                         { \text -> yield (Number (toInt text))     }
    $fst $label* | "(" $opchar+ ")" { \text -> yield (Label text)              }
    "https://" $nonwhite+           { \text -> yield (URL text)                }
    "http://" $nonwhite+            { \text -> yield (URL text)                }
    "/" $nonwhite+                  { \text -> yield (File (toFile 0 text))    }
    "./" $nonwhite+                 { \text -> yield (File (toFile 2 text))    }
    "../" $nonwhite+                { \text -> yield (File (toFile 0 text))    }

{
toInt :: Text -> Int
toInt = Text.foldl' (\x c -> 10 * x + digitToInt c) 0

toFile :: Int64 -> Text -> FilePath
toFile n = fromText . Text.toStrict . Text.drop n

trim :: Text -> Text
trim = Text.init . Text.tail

-- This was lifted almost intact from the @alex@ source code
encode :: Char -> (Word8, [Word8])
encode c = (fromIntegral h, map fromIntegral t)
  where
    (h, t) = go (ord c)

    go n
        | n <= 0x7f   = (n, [])
        | n <= 0x7ff  = (0xc0 + (n `shiftR` 6), [0x80 + n .&. 0x3f])
        | n <= 0xffff =
            (   0xe0 + (n `shiftR` 12)
            ,   [   0x80 + ((n `shiftR` 6) .&. 0x3f)
                ,   0x80 + n .&. 0x3f
                ]
            )
        | otherwise   =
            (   0xf0 + (n `shiftR` 18)
            ,   [   0x80 + ((n `shiftR` 12) .&. 0x3f)
                ,   0x80 + ((n `shiftR` 6) .&. 0x3f)
                ,   0x80 + n .&. 0x3f
                ]
            )

-- | The cursor's location while lexing the text
data Position = P
    { lineNo    :: {-# UNPACK #-} !Int
    , columnNo  :: {-# UNPACK #-} !Int
    } deriving (Show)

-- line :: Lens' Position Int
line :: Functor f => (Int -> f Int) -> Position -> f Position
line k (P l c) = fmap (\l' -> P l' c) (k l)

-- column :: Lens' Position Int
column :: Functor f => (Int -> f Int) -> Position -> f Position
column k (P l c) = fmap (\c' -> P l c') (k c)

{- @alex@ does not provide a `Text` wrapper, so the following code just modifies
   the code from their @basic@ wrapper to work with `Text`

   I could not get the @basic-bytestring@ wrapper to work; it does not correctly
   recognize Unicode regular expressions.
-}
data AlexInput = AlexInput
    { prevChar  :: Char
    , currBytes :: [Word8]
    , currInput :: Text
    }

alexGetByte :: AlexInput -> Maybe (Word8,AlexInput)
alexGetByte (AlexInput c bytes text) = case bytes of
    b:ytes -> Just (b, AlexInput c ytes text)
    []     -> case Text.uncons text of
        Nothing       -> Nothing
        Just (t, ext) -> case encode t of
            (b, ytes) -> Just (b, AlexInput t ytes ext)

alexInputPrevChar :: AlexInput -> Char
alexInputPrevChar = prevChar

{-| Convert a text representation of an expression into a stream of tokens

    `lexExpr` keeps track of position and returns the remainder of the input if
    lexing fails.
-}
lexExpr :: Text -> Producer LocatedToken (State Position) (Maybe Text)
lexExpr text = for (go (AlexInput '\n' [] text)) tag
  where
    tag token = do
        pos <- lift State.get
        yield (LocatedToken token pos)

    go input = case alexScan input 0 of
        AlexEOF                        -> return Nothing
        AlexError (AlexInput _ _ text) -> return (Just text)
        AlexSkip  input' len           -> do
            lift (column += len)
            go input'
        AlexToken input' len act       -> do
            act (Text.take (fromIntegral len) (currInput input))
            lift (column += len)
            go input'

-- | A `Token` augmented with `Position` information
data LocatedToken = LocatedToken
    { token    ::                !Token
    , position :: {-# UNPACK #-} !Position
    } deriving (Show)

-- | Token type, used to communicate between the lexer and parser
data Token
    = OpenParen
    | CloseParen
    | OpenBrace
    | CloseBrace
    | OpenList
    | OpenPath
    | CloseBracket
    | Period
    | Comma
    | Colon
    | Semicolon
    | At
    | Star
    | Box
    | Arrow
    | LArrow
    | Lambda
    | Pi
    | Equals
    | In
    | Do
    | Nat
    | List
    | Cmd
    | Path
    | Label Text
    | Number Int
    | File FilePath
    | URL Text
    | EOF
    deriving (Eq, Show)
}
