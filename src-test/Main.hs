{-# LANGUAGE LambdaCase        #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE RecordWildCards   #-}

-- |
-- Copyright: © Herbert Valerio Riedel 2018
-- SPDX-License-Identifier: GPL-2.0-or-later
--
module Main where

import           Control.Monad
import           Control.Monad.Identity
import qualified Data.ByteString.Char8      as BS
import qualified Data.ByteString.Lazy.Char8 as BS.L
import           Data.Int                   (Int64)
import           Data.List                  (groupBy)
import           Data.Maybe
import           System.Directory
import           System.Environment
import           System.Exit
import           System.FilePath
import           System.IO
import           Text.Printf                (printf)
import           Text.Read

import qualified Data.Aeson.Micro           as J
import           Data.Map                   (Map)
import qualified Data.Map                   as Map
import           Data.Text                  (Text)
import qualified Data.Text                  as T
import qualified Data.Text.Encoding         as T
import qualified Data.Text.IO               as T

import           Data.YAML                  as Y
import           Data.YAML.Event            as YE
import qualified Data.YAML.Token            as YT

import qualified TML

main :: IO ()
main = do
  args <- getArgs

  case args of
    ("yaml2event":args')
      | null args' -> cmdYaml2Event
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2event sub-command"
          exitFailure

    ("yaml2event0":args')
      | null args' -> cmdYaml2Event0
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2event0 sub-command"
          exitFailure

    ("yaml2token":args')
      | null args' -> cmdYaml2Token
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2token sub-command"
          exitFailure

    ("yaml2token0":args')
      | null args' -> cmdYaml2Token0
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2token0 sub-command"
          exitFailure

    ("yaml2json":args')
      | null args' -> cmdYaml2Json
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2json sub-command"
          exitFailure

    ("yaml2yaml":args')
      | null args' -> cmdYaml2Yaml
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2yaml sub-command"
          exitFailure

    ("yaml2yaml-":args')
      | null args' -> cmdYaml2Yaml'
      | otherwise -> do
          hPutStrLn stderr "unexpected arguments passed to yaml2yaml- sub-command"
          exitFailure

    ("run-tml":args') -> cmdRunTml args'

    ("testml-compiler":args') -> cmdTestmlCompiler args'

    _ -> do
      hPutStrLn stderr "usage: yaml-test <command> [<args>]"
      hPutStrLn stderr ""
      hPutStrLn stderr "Commands:"
      hPutStrLn stderr ""
      hPutStrLn stderr "  yaml2token       reads YAML stream from STDIN and dumps tokens to STDOUT"
      hPutStrLn stderr "  yaml2token0      reads YAML stream from STDIN and prints count of tokens to STDOUT"
      hPutStrLn stderr "  yaml2event       reads YAML stream from STDIN and dumps events to STDOUT"
      hPutStrLn stderr "  yaml2event0      reads YAML stream from STDIN and prints count of events to STDOUT"
      hPutStrLn stderr "  yaml2json        reads YAML stream from STDIN and dumps JSON to STDOUT"
      hPutStrLn stderr "  yaml2yaml        reads YAML stream from STDIN and dumps YAML to STDOUT (non-streaming version)"
      hPutStrLn stderr "  yaml2yaml-       reads YAML stream from STDIN and dumps YAML to STDOUT (streaming version)"
      hPutStrLn stderr "  run-tml          run/validate YAML-specific .tml file(s)"
      hPutStrLn stderr "  testml-compiler  emulate testml-compiler"

      exitFailure



cmdYaml2Token :: IO ()
cmdYaml2Token = do
  inYamlDat <- BS.L.getContents
  forM_ (groupBy (\x y -> YT.tLine x == YT.tLine y) $  YT.tokenize inYamlDat False) $ \lgrp -> do
    forM_  lgrp $ \YT.Token{..} -> do
      let tText' | null tText = ""
                 | any (== ' ') tText = replicate tLineChar ' ' ++ show tText
                 | otherwise  = replicate (tLineChar+1) ' ' ++ tail (init (show tText))
      hPutStrLn stdout $ printf "<stdin>:%d:%d: %-15s| %s" tLine tLineChar (show tCode) tText'
    hPutStrLn stdout ""
  hFlush stdout

cmdYaml2Token0 :: IO ()
cmdYaml2Token0 = do
  inYamlDat <- BS.L.getContents
  print (length (YT.tokenize inYamlDat False))

cmdYaml2Yaml :: IO ()
cmdYaml2Yaml = do
  inYamlDat <- BS.L.getContents
  case (sequence $ parseEvents inYamlDat) of
    Left (ofs,msg) -> do
      case msg of
        "" -> hPutStrLn stderr ("parsing error near byte offset " ++ show ofs)
        _  -> hPutStrLn stderr ("parsing error near byte offset " ++ show ofs ++ " (" ++ msg ++ ")")
      exitFailure
    Right events -> do
      BS.L.hPutStr stdout (writeEvents YT.UTF8 events)
      hFlush stdout

-- lazy streaming version
cmdYaml2Yaml' :: IO ()
cmdYaml2Yaml' = do
    inYamlDat <- BS.L.getContents
    BS.L.hPutStr stdout $ writeEvents YT.UTF8 $ parseEvents' inYamlDat
    hFlush stdout
  where
    parseEvents' = map (either (\(ofs,msg) -> error ("parsing error near byte offset " ++ show ofs ++ " (" ++ msg ++ ")")) id) . parseEvents

cmdYaml2Event :: IO ()
cmdYaml2Event = do
  inYamlDat <- BS.L.getContents
  forM_ (parseEvents inYamlDat) $ \ev -> case ev of
    Left (ofs,msg) -> do
      case msg of
        "" -> hPutStrLn stderr ("parsing error near byte offset " ++ show ofs)
        _  -> hPutStrLn stderr ("parsing error near byte offset " ++ show ofs ++ " (" ++ msg ++ ")")
      exitFailure
    Right event -> do
      hPutStrLn stdout (ev2str True event)
      hFlush stdout


cmdYaml2Event0 :: IO ()
cmdYaml2Event0 = do
    inYamlDat <- BS.L.getContents
    print (length (parseEvents' inYamlDat))
  where
    parseEvents' = map (either (\(ofs,msg) -> error ("parsing error near byte offset " ++ show ofs ++ " (" ++ msg ++ ")")) id) . parseEvents

-- | 'J.Value' look-alike
data Value' = Object'  (Map Text Value')
            | Array'   [Value']
            | String'  !Text
            | NumberD' !Double
            | NumberI' !Integer
            | Bool'    !Bool
            | Null'
            deriving Show

toProperValue :: Value' -> J.Value
toProperValue v = case v of
  Null'      -> J.Null
  String' t  -> J.String t
  NumberD' x -> J.Number x
  NumberI' x -> J.Number (fromInteger x)
  Bool' b    -> J.Bool b
  Array' xs  -> J.Array (map toProperValue xs)
  Object' xs -> J.Object (fmap toProperValue xs)

instance FromYAML Value' where
  parseYAML (Y.Scalar s) = case s of
    SNull        -> pure Null'
    SBool b      -> pure (Bool' b)
    SFloat x     -> pure (NumberD' x)
    SInt x       -> pure (NumberI' x)
    SStr t       -> pure (String' t)
    SUnknown _ t -> pure (String' t) -- HACK

  parseYAML (Y.Sequence _ xs) = Array' <$> mapM parseYAML xs

  parseYAML (Y.Mapping _ m) = Object' . Map.fromList <$> mapM parseKV (Map.toList m)
    where
      parseKV :: (Y.Node,Y.Node) -> Parser (Text,Value')
      parseKV (k,v) = (,) <$> parseK k <*> parseYAML v

      -- for numbers and !!null we apply implicit conversions
      parseK n = do
        k <- parseYAML n
        case k of
          NumberI' t -> pure (T.pack (show t))
          NumberD' t -> pure (T.pack (show t))
          String' t  -> pure t
          Null'      -> pure ""
          -- we stringify the key with an added risk of nameclashing
          _          -> pure $ T.decodeUtf8 $ J.encodeStrict $ toProperValue k
--        _          -> fail ("dictionary entry had non-string key " ++ show k)

decodeAeson :: BS.L.ByteString -> Either String [J.Value]
decodeAeson = fmap (map toProperValue) . decode

-- | Try to convert 'Double' into 'Int64', return 'Nothing' if not
-- representable loss-free as integral 'Int64' value.
doubleToInt64 :: Double -> Maybe Int64
doubleToInt64 x
  | fromInteger x' == x
  , x' <= toInteger (maxBound :: Int64)
  , x' >= toInteger (minBound :: Int64)
    = Just (fromIntegral x')
  | otherwise = Nothing
  where
    x' = round x


decodeNumber :: T.Text -> Maybe Double
decodeNumber = readMaybe . T.unpack -- fixme

cmdYaml2Json :: IO ()
cmdYaml2Json = do
  inYamlDat <- BS.L.getContents

  case decodeAeson inYamlDat of
    Left e -> fail e
    Right vs -> do
      forM_ vs $ \v -> BS.L.putStrLn (J.encode v)

  return ()

unescapeSpcTab :: T.Text -> T.Text
unescapeSpcTab = T.replace "<SPC>" " " . T.replace "<TAB>" "\t"


data TestPass = PassExpErr   -- ^ expected parse fail
              | PassEvs      -- ^ events ok
              | PassEvsJson  -- ^ events+json ok
              | PassEvsJsonYaml
              deriving (Eq,Ord,Show)

data TestFail = FailParse    -- ^ unexpected parse fail
              | FailSuccess  -- ^ unexpected parse success
              | FailEvs      -- ^ events wrong/mismatched
              | FailJson     -- ^ JSON wrong/mismatched
              | FailYaml     -- ^ YAML wrong/mismatched
              deriving (Eq,Ord,Show)

data TestRes
  = Pass !TestPass
  | Fail !TestFail
  deriving (Eq,Ord,Show)

cmdRunTml :: [FilePath] -> IO ()
cmdRunTml args = do
  results <- forM args $ \fn -> do
    tml <- BS.readFile fn

    hPutStr stdout (fn ++ " : ")
    hFlush stdout

    TML.Document _ blocks <- either (fail . T.unpack) pure $ TML.parse fn (T.decodeUtf8 tml)

    forM blocks $ \(TML.Block label points) -> do

      let dats = [ (k,v) | TML.PointStr k v <- points ]

      let isErr = isJust (lookup "error" dats)

          Just inYamlDat = BS.L.fromStrict . T.encodeUtf8 . unescapeSpcTab <$> lookup "in-yaml" dats
          Just testEvDat = lines . T.unpack . unescapeSpcTab <$> lookup "test-event" dats

          mInJsonDat :: Maybe [J.Value]
          mInJsonDat = (maybe (error ("invalid JSON in " ++ show fn)) id . J.decodeStrictN . T.encodeUtf8) <$> lookup "in-json" dats

          mOutYamlDat = BS.L.fromStrict . T.encodeUtf8 . unescapeSpcTab <$> lookup "out-yaml" dats

      case sequence (parseEvents inYamlDat) of
        Left err
          | isErr -> do
              putStrLn "OK! (error)"
              pure (Pass PassExpErr)
          | otherwise -> do
              putStrLn "FAIL!"
              putStrLn ""
              putStrLn "----------------------------------------------------------------------------"
              putStrLn' (T.unpack label)
              putStrLn ""
              putStrLn' (show err)
              putStrLn ""
              putStrLn' (show testEvDat)
              putStrLn ""
              BS.L.putStr inYamlDat
              putStrLn ""
              testParse inYamlDat
              putStrLn ""
              -- forM_ (parseEvents inYamlDat) (putStrLn' . show)
              putStrLn ""
              putStrLn "----------------------------------------------------------------------------"
              putStrLn ""
              pure (Fail FailParse)

        Right evs' -> do
          let evs'' = map (ev2str False) evs'
          if evs'' == testEvDat
             then do

               let outYamlDatIut = writeEvents YT.UTF8 evs'
                   outYamlEvsIut = either (const []) (map (ev2str False)) $ sequence $ parseEvents outYamlDatIut

               unless (outYamlEvsIut == evs'') $ do
                 putStrLn' ("\nWARNING: (iut /= ref)")

                 putStrLn' ("iut[yaml] = " ++ show outYamlDatIut)
                 putStrLn' ("ref[raw-evs] = " ++ show evs')
                 putStrLn' ("ref[evs] = " ++ show evs'')
                 putStrLn' ("iut[evs] = " ++ show outYamlEvsIut)

                 putStrLn ""


               case mInJsonDat of
                 Nothing -> do
                   putStrLn "OK!"
                   pure (Pass PassEvs)
                 Just inJsonDat -> do
                   iutJson <- either fail pure $ decodeAeson inYamlDat

                   if iutJson == inJsonDat
                     then do
                       case mOutYamlDat of
                         Nothing -> do
                           putStrLn "OK! (+JSON)"
                           pure (Pass PassEvsJson)
                         Just outYamlDat -> do
                           case () of
                             _ | outYamlDat == outYamlDatIut -> do
                                   putStrLn "OK! (+JSON+YAML)"
                                   pure (Pass PassEvsJsonYaml)

                               | otherwise -> do

                                   putStrLn $ if outYamlEvsIut == evs'' then "OK (+JSON-YAML)" else "FAIL! (bad out-YAML)"

                                   putStrLn' ("ref = " ++ show outYamlDat)
                                   putStrLn' ("iut = " ++ show outYamlDatIut)
                                   putStrLn ""
                                   putStrLn' ("ref = " ++ show evs'')
                                   putStrLn' ("iut = " ++ show outYamlEvsIut)

                                   case outYamlEvsIut == evs'' of
                                     True -> do
                                       putStrLn' ("(iut == ref)")
                                       pure (Pass PassEvsJson)
                                     False -> pure (Fail FailYaml)


                     else do
                       putStrLn "FAIL! (bad JSON)"

                       putStrLn' ("ref = " ++ show inJsonDat)
                       putStrLn' ("iut = " ++ show iutJson)

                       pure (Fail FailJson)

             else do
               if isErr
                 then putStrLn "FAIL! (unexpected parser success)"
                 else putStrLn "FAIL!"

               putStrLn ""
               putStrLn "----------------------------------------------------------------------------"
               putStrLn' (T.unpack label)
               putStrLn ""
               putStrLn' ("ref = " ++ show testEvDat)
               putStrLn' ("iut = " ++ show evs'')
               putStrLn ""
               BS.L.putStr inYamlDat
               putStrLn ""
               testParse inYamlDat
               putStrLn ""
               -- forM_ (parseEvents inYamlDat) (putStrLn' . show)
               putStrLn ""
               putStrLn "----------------------------------------------------------------------------"
               putStrLn ""
               pure (Fail (if isErr then FailSuccess else FailEvs))

  putStrLn ""

  let ok = length [ () | Pass _ <- results' ]
      nok = length [ () | Fail _ <- results' ]

      stat j = show $ Map.findWithDefault 0 j $ Map.fromListWith (+) [ (k,1::Int) | k <- results' ]

      results' = concat results

  putStrLn $ concat
    [ "done -- passed: ", show ok
    , " (ev: ", stat (Pass PassEvs), ", ev+json: ", stat (Pass PassEvsJson), ", ev+json+yaml: ", stat (Pass PassEvsJsonYaml), ", err: ", stat (Pass PassExpErr), ") / "
    , "failed: ", show nok
    , " (err: ", stat (Fail FailParse), ", ev:", stat (Fail FailEvs), ", json:", stat (Fail FailJson), ", yaml:", stat (Fail FailYaml), ", ok:", stat (Fail FailSuccess), ")"
    ]


-- | Incomplete proof-of-concept 'testml-compiler' operation
cmdTestmlCompiler :: [FilePath] -> IO ()
cmdTestmlCompiler [fn0] = do
  (fn,raw) <- case fn0 of
    "-" -> (,) "<stdin>" <$> T.getContents
    _   -> (,) fn0 <$> T.readFile fn0

  case TML.parse fn raw of
    Left e    -> T.hPutStrLn stderr e >> exitFailure
    Right doc -> BS.putStrLn (J.encodeStrict doc)
cmdTestmlCompiler _ = do
  hPutStrLn stderr ("Usage: yaml-test testml-compiler [ <testml-file-name> | - ]")
  exitFailure


putStrLn' :: String -> IO ()
putStrLn' msg = putStrLn ("  " ++ msg)

ev2str :: Bool -> Event -> String
ev2str withColSty = \case
    StreamStart                 -> "+STR"
    DocumentStart True          -> "+DOC ---"
    DocumentStart False         -> "+DOC"
    MappingEnd                  -> "-MAP"
    (MappingStart manc mtag Flow)
      | withColSty              -> "+MAP {}" ++ ancTagStr manc mtag
    (MappingStart manc mtag _)  -> "+MAP"    ++ ancTagStr manc mtag
    SequenceEnd                 -> "-SEQ"
    (SequenceStart manc mtag Flow)
      | withColSty              -> "+SEQ []" ++ ancTagStr manc mtag
    SequenceStart manc mtag _   -> "+SEQ"    ++ ancTagStr manc mtag
    DocumentEnd True            -> "-DOC ..."
    DocumentEnd False           -> "-DOC"
    StreamEnd                   -> "-STR"
    Alias a                     -> "=ALI *"  ++ T.unpack a
    YE.Scalar manc mtag sty v   -> "=VAL"    ++ ancTagStr manc mtag ++ styStr sty ++ quote2 v
  where
    styStr = \case
           Plain        -> " :"
           DoubleQuoted -> " \""
           Literal      -> " |"
           Folded       -> " >"
           SingleQuoted -> " '"

    ancTagStr manc mtag = anc' ++ tag'
      where
        anc' = case manc of
                 Nothing  -> ""
                 Just anc -> " &" ++ T.unpack anc

        tag' = case tagToText mtag of
                 Nothing -> ""
                 Just t  -> " <" ++ T.unpack t ++ ">"


    quote2 :: T.Text -> String
    quote2 = concatMap go . T.unpack
      where
        go c | c == '\n' = "\\n"
             | c == '\t' = "\\t"
             | c == '\b' = "\\b"
             | c == '\r' = "\\r"
             | c == '\\' = "\\\\"
             | otherwise = [c]



testParse :: BS.L.ByteString -> IO ()
testParse bs0 = mapM_  (putStrLn' . showT) $ YT.tokenize bs0 False
  where
    showT :: YT.Token -> String
    showT t = replicate (YT.tLineChar t) ' ' ++ show (YT.tText t) ++ "  " ++ show (YT.tCode t)
