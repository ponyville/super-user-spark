module Compiler where

import           Data.Aeson                 (eitherDecode)
import           Data.Aeson.Encode.Pretty   (encodePretty)
import           Data.Binary                (decodeFileOrFail, encode,
                                             encodeFile)
import           Data.ByteString.Lazy.Char8 (unpack)
import qualified Data.ByteString.Lazy.Char8 as BS
import           Data.List                  (find, isPrefixOf)
import           System.Directory           (getCurrentDirectory,
                                             getHomeDirectory)
import           System.FilePath            (takeDirectory, (</>))

import qualified Parser                     as P
import           Types
import           Utils

compile :: Card -> [Card] -> Sparker [Deployment]
compile card allCards = do
    initial <- initialState card allCards
    ((_,_),dps) <- runSparkCompiler initial compileDeployments
    return dps

outputCompiled :: [Deployment] -> Sparker ()
outputCompiled deps = do
    form <- asks conf_compile_format
    out <- asks conf_compile_output
    case form of
        FormatBinary -> do
            case out of
                Nothing -> liftIO $ putStrLn $ unpack $ encode deps
                Just fp -> liftIO $ encodeFile fp deps
        FormatText -> do
            let str = unlines $ map show deps
            case out of
                Nothing -> liftIO $ putStrLn str
                Just fp -> liftIO $ writeFile fp str
        FormatJson -> do
            let bs = encodePretty deps
            case out of
                Nothing -> liftIO $ BS.putStrLn bs
                Just fp -> liftIO $ BS.writeFile fp bs

        FormatStandalone -> notImplementedYet

inputCompiled :: FilePath -> Sparker [Deployment]
inputCompiled fp = do
    form <- asks conf_compile_format
    case form of
        FormatBinary -> do
            o <- liftIO $ decodeFileOrFail fp
            case o of
                Left (_,err)    -> throwError $ CompileError $ "Something went wrong while deserialising binary data:" ++ err
                Right deps      -> return deps
        FormatText -> do
            str <- liftIO $ readFile fp
            return $ read str
        FormatJson -> do
            bs <- liftIO $ BS.readFile fp
            case eitherDecode bs of
                Left err        -> throwError $ CompileError $ "Something went wrong while deserialising json data" ++ err
                Right ds        -> return ds

        FormatStandalone -> throwError $ CompileError "You're not supposed to use standalone compiled deployments in any other way than by executing it."


initialState :: Card -> [Card] -> Sparker CompilerState
initialState c@(Card _ fp ds) cds = do
    currentDir <- liftIO getCurrentDirectory
    override <- asks conf_compile_kind
    return $ CompilerState {
        state_current_card = c
    ,   state_current_directory = currentDir </> takeDirectory fp
    ,   state_all_cards = cds
    ,   state_declarations_left = ds
    ,   state_deployment_kind_override = override
    ,   state_into_prefix = ""
    ,   state_outof_prefix = ""
    ,   state_alternatives = [""]
    }

-- Compiler

pop :: SparkCompiler Declaration
pop = do
    dec <- gets state_declarations_left
    modify (\s -> s {state_declarations_left = tail dec})
    return $ head dec

done :: SparkCompiler Bool
done = fmap null $ gets state_declarations_left

compileDeployments :: SparkCompiler ()
compileDeployments = do
    d <- done
    if d
    then return ()
    else processDeclaration >> compileDeployments

add :: Deployment -> SparkCompiler ()
add dep = tell [dep]

addAll :: [Deployment] -> SparkCompiler ()
addAll = tell

replaceHome :: FilePath -> SparkCompiler FilePath
replaceHome path = do
    home <- liftIO getHomeDirectory
    return $ if "~" `isPrefixOf` path
        then home </> drop 2 path
        else path

processDeclaration :: SparkCompiler ()
processDeclaration = do
    dec <- pop
    case dec of
        Deploy src dst kind -> do
            override <- gets state_deployment_kind_override
            superOverride <- asks conf_compile_override
            let resultKind = case (superOverride, override, kind) of
                    (Nothing, Nothing, Nothing) -> LinkDeployment
                    (Nothing, Nothing, Just k ) -> k
                    (Nothing, Just o , _      ) -> o
                    (Just o , _      , _      ) -> o

            alternates <- gets state_alternatives
            dir <- gets state_current_directory

            outof <- gets state_outof_prefix
            into <- gets state_into_prefix

            let alts = map (\alt -> dir </> alt </> outof </> src) alternates
            destination <- replaceHome $ into </> dst

            add $ Put alts destination resultKind

        SparkOff st -> do
            case st of
                CardRepo _ -> lift $ lift notImplementedYet

                CardFile (CardFileReference file mn) -> do
                    dir <- gets state_current_directory
                    newCards <- liftSparker $ P.parseFile $ dir </> file
                    oldCards <- gets state_all_cards
                    let allCards = oldCards ++ newCards
                    nextCard <- case mn of
                                    Nothing -> return $ head newCards
                                    Just (CardNameReference name) ->
                                        case find (\c -> card_name c == name) allCards of
                                            Nothing -> throwError $ CompileError "card not found" -- FIXME this is unsafe.
                                            Just c -> return c
                    newDeclarations <- liftSparker $ compile nextCard newCards
                    modify (\s -> s {state_all_cards = allCards})
                    addAll newDeclarations

                CardName (CardNameReference name) -> do
                    allCards <- gets state_all_cards
                    case find (\c -> card_name c == name) allCards of
                        Nothing -> throwError $ CompileError "card not found" -- FIXME this is unsafe.
                        Just c@(Card _ _ dcs) -> do
                            before <- get
                            modify (\s -> s {state_declarations_left = dcs
                                            ,state_current_card = c})
                            compileDeployments
                            put before



        IntoDir dir -> do
            ip <- gets state_into_prefix
            if null ip
            then modify (\s -> s {state_into_prefix = dir} )
            else modify (\s -> s {state_into_prefix = ip </> dir} )
        OutofDir dir -> do
            op <- gets state_outof_prefix
            if null op
            then modify (\s -> s {state_outof_prefix = dir} )
            else modify (\s -> s {state_outof_prefix = op </> dir} )
        DeployKindOverride kind -> modify (\s -> s {state_deployment_kind_override = Just kind })
        Block ds -> do
            before <- get
            modify (\s -> s {state_declarations_left = ds})
            compileDeployments
            put before
        Alternatives ds -> modify (\s -> s {state_alternatives = ds})

liftSparker :: Sparker a -> SparkCompiler a
liftSparker = lift . lift
