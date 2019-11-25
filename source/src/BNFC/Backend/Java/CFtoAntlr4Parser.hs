{-
    BNF Converter: Antlr4 Java 1.8 Generator
    Copyright (C) 2004  Author:  Markus Forsberg, Michael Pellauer,
                                 Bjorn Bringert

    This program is free software; you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation; either version 2 of the License, or
    (at your option) any later version.

    This program is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with this program; if not, write to the Free Software
    Foundation, 51 Franklin Street, Fifth Floor, Boston, MA 02110-1335, USA
-}

{-
   **************************************************************
    BNF Converter Module

    Description   : This module generates the ANTLR .g4 input file. It
                    follows the same basic structure of CFtoHappy.

    Author        : Gabriele Paganelli (gapag@distruzione.org),


    License       : GPL (GNU General Public License)

    Created       : 15 Oct, 2015

    Modified      :


   **************************************************************
-}
module BNFC.Backend.Java.CFtoAntlr4Parser ( cf2AntlrParse ) where

import Data.List     ( intercalate )
import Data.Maybe

import BNFC.CF
import BNFC.Backend.Java.Utils
import BNFC.Backend.Common.NamedVariables
import BNFC.Options ( RecordPositions(..) )
import BNFC.Utils   ( (+++), (+.+), for, applyWhen )

-- Type declarations

-- | A definition of a non-terminal by all its rhss,
--   together with parse actions.
data PDef = PDef
  { pdNT   :: Maybe String
      -- ^ If given, the name of the lhss.  Usually computed from 'pdCat'.
  , pdCat  :: Cat
      -- ^ The category to parse.
  , pdAlts :: [(Pattern, Fun, Action)]
      -- ^ The possible rhss with actions.  If 'null', skip this 'PDef'.
  }
type Rules       = [PDef]
type Pattern     = String
type Action      = String
type MetaVar     = (String, Cat)

-- | Creates the ANTLR parser grammar for this CF.
--The environment comes from CFtoAntlr4Lexer
cf2AntlrParse :: String -> String -> CF -> RecordPositions -> SymEnv -> String
cf2AntlrParse packageBase packageAbsyn cf _ env = unlines
    [ header
    , tokens
    , prRules packageAbsyn (rulesForAntlr4 packageAbsyn cf env)
    ]
  where
    header :: String
    header = unlines
        [ "// -*- Java -*- This ANTLRv4 file was machine-generated by BNFC"
        , "parser grammar" +++ identifier ++ "Parser;"
        ]
    tokens :: String
    tokens = unlines
        [ "options {"
        , "  tokenVocab = "++identifier++"Lexer;"
        , "}"
        ]
    identifier = getLastInPackage packageBase

--The following functions are a (relatively) straightforward translation
--of the ones in CFtoHappy.hs
rulesForAntlr4 :: String -> CF -> SymEnv -> Rules
rulesForAntlr4 packageAbsyn cf env = map mkOne getrules
  where
    getrules          = ruleGroups cf
    mkOne (cat,rules) = constructRule packageAbsyn cf env rules cat

-- | For every non-terminal, we construct a set of rules. A rule is a sequence of
-- terminals and non-terminals, and an action to be performed.
constructRule :: String -> CF -> SymEnv -> [Rule] -> NonTerminal -> PDef
constructRule packageAbsyn cf env rules nt =
  PDef Nothing nt $
    [ ( p
      , funRule r
      , generateAction packageAbsyn nt (funRule r) m b
      )
    | (index, r0) <- zip [1..] rules
    , let b      = isConsFun (funRule r0) && elem (valCat r0) (cfgReversibleCats cf)
    , let r      = applyWhen b revSepListRule r0
    , let (p,m0) = generatePatterns index env r
    , let m      = applyWhen b reverse m0
    ]

-- Generates a string containing the semantic action.
generateAction :: String -> NonTerminal -> Fun -> [MetaVar]
               -> Bool   -- ^ Whether the list should be reversed or not.
                         --   Only used if this is a list rule.
               -> Action
generateAction packageAbsyn nt f ms rev
    | isNilFun f = "$result = new " ++ c ++ "();"
    | isOneFun f = "$result = new " ++ c ++ "(); $result.addLast("
        ++ p_1 ++ ");"
    | isConsFun f = "$result = " ++ p_2 ++ "; "
                           ++ "$result." ++ add ++ "(" ++ p_1 ++ ");"
    | isCoercion f = "$result = " ++  p_1 ++ ";"
    | isDefinedRule f = "$result = parser." ++ f ++ "_"
                        ++ "(" ++ intercalate "," (map resultvalue ms) ++ ");"
    | otherwise = "$result = new " ++ c
                  ++ "(" ++ intercalate "," (map resultvalue ms) ++ ");"
   where
     c                 = packageAbsyn ++ "." ++
                            if isNilFun f || isOneFun f || isConsFun f
                            then identCat (normCat nt) else f
     p_1               = resultvalue $ ms!!0
     p_2               = resultvalue $ ms!!1
     add               = if rev then "addLast" else "addFirst"
     gettext           = "getText()"
     removeQuotes x    = "substring(1, "++ x +.+ gettext +.+ "length()-1)"
     parseint x        = "Integer.parseInt("++x++")"
     parsedouble x     = "Double.parseDouble("++x++")"
     charat            = "charAt(1)"
     resultvalue (n,c) = case c of
                          TokenCat "Ident"   -> n'+.+gettext
                          TokenCat "Integer" -> parseint $ n'+.+gettext
                          TokenCat "Char"    -> n'+.+gettext+.+charat
                          TokenCat "Double"  -> parsedouble $ n'+.+gettext
                          TokenCat "String"  -> n'+.+gettext+.+removeQuotes n'
                          _         -> (+.+) n' (if isTokenCat c then gettext else "result")
                          where n' = '$':n

-- | Generate patterns and a set of metavariables indicating
-- where in the pattern the non-terminal
-- >>> generatePatterns 2 [] $ Rule "myfun" (Cat "A") [] Parsable
-- (" /* empty */ ",[])
-- >>> generatePatterns 3 [("def", "_SYMB_1")] $ Rule "myfun" (Cat "A") [Right "def", Left (Cat "B")] Parsable
-- ("_SYMB_1 p_3_2=b ",[("p_3_2",B)])
generatePatterns :: Int -> SymEnv -> Rule -> (Pattern,[MetaVar])
generatePatterns ind env r = case rhsRule r of
    []  -> (" /* empty */ ",[])
    its -> (mkIt 1 its, metas its)
 where
    mkIt _ [] = []
    mkIt n (i:is) = case i of
        Left c -> "p_" ++show ind++"_"++ show (n :: Int) ++ "="++ c'
            +++ mkIt (n+1) is
          where
              c' = case c of
                  TokenCat "Ident"   -> "IDENT"
                  TokenCat "Integer" -> "INTEGER"
                  TokenCat "Char"    -> "CHAR"
                  TokenCat "Double"  -> "DOUBLE"
                  TokenCat "String"  -> "STRING"
                  _                  -> if isTokenCat c
                                          then identCat c
                                          else firstLowerCase
                                                (getRuleName (identCat c))
        Right s -> case lookup s env of
            (Just x) -> x +++ mkIt (n+1) is
            (Nothing) -> mkIt n is
    metas its = [("p_" ++ show ind ++"_"++ show i, category)
                    | (i,Left category) <- zip [1 :: Int ..] its]

-- | Puts together the pattern and actions and returns a string containing all
-- the rules.
prRules :: String -> Rules -> String
prRules packabs = concatMap $ \case

  -- No rules: skip.
  PDef _mlhs _nt []         -> ""

  -- At least one rule: print!
  PDef mlhs nt (rhs : rhss) -> unlines $ concat

    -- The definition header: lhs and type.
    [ [ unwords [ fromMaybe nt' mlhs
                , "returns" , "[" , packabs+.+normcat , "result" , "]"
                ]
      ]
    -- The first rhs.
    , alternative "  :" rhs
    -- The other rhss.
    , concatMap (alternative "  |") rhss
    -- The definition footer.
    , [ ";" ]
    ]
    where
    alternative sep (p, fun, a) =
      [ unwords [ sep , p ]
      , unwords [ "    {" , a , "}" ]
      , unwords [ "    #" , antlrRuleLabel fun ]
      ]
    catid              = identCat nt
    normcat            = identCat (normCat nt)
    nt'                = getRuleName $ firstLowerCase catid
    antlrRuleLabel fnc
      | isNilFun fnc   = catid ++ "_Empty"
      | isOneFun fnc   = catid ++ "_AppendLast"
      | isConsFun fnc  = catid ++ "_PrependFirst"
      | isCoercion fnc = "Coercion_" ++ catid
      | otherwise      = getLabelName fnc
