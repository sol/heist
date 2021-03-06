{-# LANGUAGE GeneralizedNewtypeDeriving #-}
{-# LANGUAGE OverloadedStrings #-}
{-# LANGUAGE PackageImports #-}
{-# LANGUAGE ScopedTypeVariables #-}

module Text.Templating.Heist.Internal where

------------------------------------------------------------------------------
import             Blaze.ByteString.Builder
import             Control.Applicative
import             Control.Exception (SomeException)
import             Control.Monad
import             Control.Monad.CatchIO
import             Control.Monad.Trans
import qualified   Data.Attoparsec.Text as AP
import             Data.ByteString (ByteString)
import qualified   Data.ByteString as B
import qualified   Data.ByteString.Char8 as BC
import             Data.Either
import qualified   Data.Foldable as F
import             Data.List
import qualified   Data.Map as Map
import             Data.Maybe
import             Data.Monoid
import qualified   Data.Text as T
import             Data.Text (Text)
import             Prelude hiding (catch)
import             System.Directory.Tree hiding (name)
import             System.FilePath
import qualified   Text.XmlHtml as X

------------------------------------------------------------------------------
import             Text.Templating.Heist.Types


------------------------------------------------------------------------------
-- | Mappends a doctype to the state.
addDoctype :: Monad m => [X.DocType] -> TemplateMonad m ()
addDoctype dt = do
    modifyTS (\s -> s { _doctypes = _doctypes s `mappend` dt })


------------------------------------------------------------------------------
-- TemplateState functions
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | Adds an on-load hook to a `TemplateState`.
addOnLoadHook :: (Monad m) =>
                 (Template -> IO Template)
              -> TemplateState m
              -> TemplateState m
addOnLoadHook hook ts = ts { _onLoadHook = _onLoadHook ts >=> hook }


------------------------------------------------------------------------------
-- | Adds a pre-run hook to a `TemplateState`.
addPreRunHook :: (Monad m) =>
                 (Template -> m Template)
              -> TemplateState m
              -> TemplateState m
addPreRunHook hook ts = ts { _preRunHook = _preRunHook ts >=> hook }


------------------------------------------------------------------------------
-- | Adds a post-run hook to a `TemplateState`.
addPostRunHook :: (Monad m) =>
                  (Template -> m Template)
               -> TemplateState m
               -> TemplateState m
addPostRunHook hook ts = ts { _postRunHook = _postRunHook ts >=> hook }


------------------------------------------------------------------------------
-- | Binds a new splice declaration to a tag name within a 'TemplateState'.
bindSplice :: Monad m =>
              Text              -- ^ tag name
           -> Splice m          -- ^ splice action
           -> TemplateState m   -- ^ source state
           -> TemplateState m
bindSplice n v ts = ts {_spliceMap = Map.insert n v (_spliceMap ts)}


------------------------------------------------------------------------------
-- | Binds a set of new splice declarations within a 'TemplateState'.
bindSplices :: Monad m =>
               [(Text, Splice m)] -- ^ splices to bind
            -> TemplateState m    -- ^ start state
            -> TemplateState m
bindSplices ss ts = foldl' (flip id) ts acts
  where
    acts = map (uncurry bindSplice) ss


------------------------------------------------------------------------------
-- | Convenience function for looking up a splice.
lookupSplice :: Monad m =>
                Text
             -> TemplateState m
             -> Maybe (Splice m)
lookupSplice nm ts = Map.lookup nm $ _spliceMap ts


------------------------------------------------------------------------------
-- | Converts a path into an array of the elements in reverse order.  If the
-- path is absolute, we need to remove the leading slash so the split doesn't
-- leave @\"\"@ as the last element of the TPath.
--
-- FIXME @\"..\"@ currently doesn't work in paths, the solution is non-trivial
splitPathWith :: Char -> ByteString -> TPath
splitPathWith s p = if BC.null p then [] else (reverse $ BC.split s path)
  where
    path = if BC.head p == s then BC.tail p else p

-- | Converts a path into an array of the elements in reverse order using the
-- path separator of the local operating system. See 'splitPathWith' for more
-- details.
splitLocalPath :: ByteString -> TPath
splitLocalPath = splitPathWith pathSeparator

-- | Converts a path into an array of the elements in reverse order using a
-- forward slash (/) as the path separator. See 'splitPathWith' for more
-- details.
splitTemplatePath :: ByteString -> TPath
splitTemplatePath = splitPathWith '/'


------------------------------------------------------------------------------
-- | Does a single template lookup without cascading up.
singleLookup :: TemplateMap
             -> TPath
             -> ByteString
             -> Maybe (X.Document, TPath)
singleLookup tm path name = fmap (\a -> (a,path)) $ Map.lookup (name:path) tm


------------------------------------------------------------------------------
-- | Searches for a template by looking in the full path then backing up into
-- each of the parent directories until the template is found.
traversePath :: TemplateMap
             -> TPath
             -> ByteString
             -> Maybe (X.Document, TPath)
traversePath tm [] name = fmap (\a -> (a,[])) (Map.lookup [name] tm)
traversePath tm path name =
    singleLookup tm path name `mplus`
    traversePath tm (tail path) name


------------------------------------------------------------------------------
-- | Returns 'True' if the given template can be found in the template state.
hasTemplate :: Monad m =>
               ByteString
            -> TemplateState m
            -> Bool
hasTemplate nameStr ts = isJust $ lookupTemplate nameStr ts


------------------------------------------------------------------------------
-- | Convenience function for looking up a template.
lookupTemplate :: Monad m =>
                  ByteString
               -> TemplateState m
               -> Maybe (X.Document, TPath)
lookupTemplate nameStr ts =
    f (_templateMap ts) path name
  where (name:p) = case splitTemplatePath nameStr of
                       [] -> [""]
                       ps -> ps
        path = p ++ (_curContext ts)
        f = if '/' `BC.elem` nameStr
                then singleLookup
                else traversePath


------------------------------------------------------------------------------
-- | Sets the templateMap in a TemplateState.
setTemplates :: Monad m => TemplateMap -> TemplateState m -> TemplateState m
setTemplates m ts = ts { _templateMap = m }


------------------------------------------------------------------------------
-- | Adds a template to the template state.
insertTemplate :: Monad m =>
               TPath
            -> X.Document
            -> TemplateState m
            -> TemplateState m
insertTemplate p t st =
    setTemplates (Map.insert p t (_templateMap st)) st


------------------------------------------------------------------------------
-- | Adds an HTML format template to the template state.
addTemplate :: Monad m =>
               ByteString
            -> Template
            -> TemplateState m
            -> TemplateState m
addTemplate n t st = insertTemplate (splitTemplatePath n)
                                    (X.HtmlDocument X.UTF8 Nothing t) st


------------------------------------------------------------------------------
-- | Adds an XML format template to the template state.
addXMLTemplate :: Monad m =>
                  ByteString
               -> Template
               -> TemplateState m
               -> TemplateState m
addXMLTemplate n t st = insertTemplate (splitTemplatePath n)
                                       (X.XmlDocument X.UTF8 Nothing t) st


------------------------------------------------------------------------------
-- | Stops the recursive processing of splices.  Consider the following
-- example:
--
--   > <foo>
--   >   <bar>
--   >     ...
--   >   </bar>
--   > </foo>
--
-- Assume that @\"foo\"@ is bound to a splice procedure. Running the @foo@
-- splice will result in a list of nodes @L@.  Normally @foo@ will recursively
-- scan @L@ for splices and run them.  If @foo@ calls @stopRecursion@, @L@
-- will be included in the output verbatim without running any splices.
stopRecursion :: Monad m => TemplateMonad m ()
stopRecursion = modifyTS (\st -> st { _recurse = False })


------------------------------------------------------------------------------
-- | Sets the current context
setContext :: Monad m => TPath -> TemplateMonad m ()
setContext c = modifyTS (\st -> st { _curContext = c })


------------------------------------------------------------------------------
-- | Gets the current context
getContext :: Monad m => TemplateMonad m TPath
getContext = getsTS _curContext


------------------------------------------------------------------------------
-- | Performs splice processing on a single node.
runNode :: Monad m => X.Node -> Splice m
runNode (X.Element nm at ch) = do
    newAtts <- mapM attSubst at
    let n = X.Element nm newAtts ch
    s <- liftM (lookupSplice nm) getTS
    maybe (runChildren newAtts) (recurseSplice n) s
  where
    runChildren newAtts = do
        newKids <- runNodeList ch
        return [X.Element nm newAtts newKids]
runNode n                    = return [n]


------------------------------------------------------------------------------
-- | Helper function for substituting a parsed attribute into an attribute
-- tuple.
attSubst :: (Monad m) => (t, Text) -> TemplateMonad m (t, Text)
attSubst (n,v) = do
    v' <- parseAtt v
    return (n,v')


------------------------------------------------------------------------------
-- | Parses an attribute for any identifier expressions and performs
-- appropriate substitution.
parseAtt :: (Monad m) => Text -> TemplateMonad m Text
parseAtt bs = do
    let ast = case AP.feed (AP.parse attParser bs) "" of
            (AP.Fail _ _ _) -> []
            (AP.Done _ res) -> res
            (AP.Partial _)  -> []
    chunks <- mapM cvt ast
    return $ T.concat chunks
  where
    cvt (Literal x) = return x
    cvt (Ident x)   = getAttributeSplice x


------------------------------------------------------------------------------
-- | AST to hold attribute parsing structure.  This is necessary because
-- attoparsec doesn't support parsers running in another monad.
data AttAST = Literal Text |
              Ident   Text
    deriving (Show)


------------------------------------------------------------------------------
-- | Parser for attribute variable substitution.
attParser :: AP.Parser [AttAST]
attParser = AP.many1 (identParser <|> litParser)
  where
    escChar = (AP.char '\\' *> AP.anyChar) <|>
              AP.satisfy (AP.notInClass "\\$")
    litParser = Literal <$> (T.pack <$> AP.many1 escChar)
    identParser = AP.string "$(" *>
        (Ident <$> AP.takeWhile (/=')')) <* AP.string ")"


------------------------------------------------------------------------------
-- | Get's the attribute value.  If the splice's result list contains non-text
-- nodes, this will translate them into text nodes with nodeText and
-- concatenate them together.
--
-- Originally, this only took the first node from the splices's result list,
-- and only if it was a text node. This caused problems when the splice's
-- result contained HTML entities, as they would split a text node. This was
-- then fixed to take the first consecutive bunch of text nodes, and return
-- their concatenation. This was seen as more useful than throwing an error,
-- and more intuitive than trying to render all the nodes as text.
--
-- However, it was decided in the end to render all the nodes as text, and
-- then concatenate them. If a splice returned
-- \"some \<b\>text\<\/b\> foobar\", the user would almost certainly want
-- \"some text foobar\" to be rendered, and Heist would probably seem
-- annoyingly limited for not being able to do this. If the user really did
-- want it to render \"some \", it would probably be easier for them to
-- accept that they were silly to pass more than that to be substituted than
-- it would be for the former user to accept that
-- \"some \<b\>text\<\/b\> foobar\" is being rendered as \"some \" because
-- it's \"more intuitive\".
getAttributeSplice :: Monad m => Text -> TemplateMonad m Text
getAttributeSplice name = do
    s <- liftM (lookupSplice name) getTS
    nodes <- maybe (return []) id s
    return $ T.concat $ map X.nodeText nodes

------------------------------------------------------------------------------
-- | Performs splice processing on a list of nodes.
runNodeList :: Monad m => [X.Node] -> Splice m
runNodeList nodes = liftM concat $ sequence (map runNode nodes)


------------------------------------------------------------------------------
-- | The maximum recursion depth.  (Used to prevent infinite loops.)
mAX_RECURSION_DEPTH :: Int
mAX_RECURSION_DEPTH = 50


------------------------------------------------------------------------------
-- | Checks the recursion flag and recurses accordingly.  Does not recurse
-- deeper than mAX_RECURSION_DEPTH to avoid infinite loops.
recurseSplice :: Monad m => X.Node -> Splice m -> Splice m
recurseSplice node splice = do
    result <- localParamNode (const node) splice
    ts' <- getTS
    if _recurse ts' && _recursionDepth ts' < mAX_RECURSION_DEPTH
        then do modRecursionDepth (+1)
                res <- runNodeList result
                restoreTS ts'
                return res
        else return result
  where
    modRecursionDepth :: Monad m => (Int -> Int) -> TemplateMonad m ()
    modRecursionDepth f =
        modifyTS (\st -> st { _recursionDepth = f (_recursionDepth st) })


------------------------------------------------------------------------------
-- | Looks up a template name runs a TemplateMonad computation on it.
lookupAndRun :: Monad m
             => ByteString
             -> ((X.Document, TPath) -> TemplateMonad m (Maybe a))
             -> TemplateMonad m (Maybe a)
lookupAndRun name k = do
    ts <- getTS
    maybe (return Nothing) k
          (lookupTemplate name ts)


------------------------------------------------------------------------------
-- | Looks up a template name evaluates it by calling runNodeList.
evalTemplate :: Monad m
            => ByteString
            -> TemplateMonad m (Maybe Template)
evalTemplate name = lookupAndRun name
    (\(t,ctx) -> do
        ts <- getTS
        putTS (ts {_curContext = ctx})
        res <- runNodeList $ X.docContent t
        restoreTS ts
        return $ Just res)


------------------------------------------------------------------------------
-- | Sets the document type of a 'X.Document' based on the 'TemplateMonad'
-- value.
fixDocType :: Monad m => X.Document -> TemplateMonad m X.Document
fixDocType d = do
    dts <- getsTS _doctypes
    return $ d { X.docType = listToMaybe dts }


------------------------------------------------------------------------------
-- | Same as evalWithHooks, but returns the entire 'X.Document' rather than
-- just the nodes.  This is the right thing to do if we are starting at the
-- top level.
evalWithHooksInternal :: Monad m
                      => ByteString
                      -> TemplateMonad m (Maybe X.Document)
evalWithHooksInternal name = lookupAndRun name $ \(t,ctx) -> do
    addDoctype $ maybeToList $ X.docType t
    ts <- getTS
    nodes <- lift $ _preRunHook ts $ X.docContent t
    putTS (ts {_curContext = ctx})
    res <- runNodeList nodes
    restoreTS ts
    newNodes <- lift (_postRunHook ts res)
    newDoc   <- fixDocType $ t { X.docContent = newNodes }
    return (Just newDoc)


------------------------------------------------------------------------------
-- | Looks up a template name evaluates it by calling runNodeList.  This also
-- executes pre- and post-run hooks and adds the doctype.
evalWithHooks :: Monad m
            => ByteString
            -> TemplateMonad m (Maybe Template)
evalWithHooks name = liftM (liftM X.docContent) (evalWithHooksInternal name)


------------------------------------------------------------------------------
-- | Binds a list of constant string splices.
bindStrings :: Monad m
            => [(Text, Text)]
            -> TemplateState m
            -> TemplateState m
bindStrings pairs ts = foldr (uncurry bindString) ts pairs


------------------------------------------------------------------------------
-- | Binds a single constant string splice.
bindString :: Monad m
            => Text
            -> Text
            -> TemplateState m
            -> TemplateState m
bindString n v = bindSplice n $ return [X.TextNode v]


------------------------------------------------------------------------------
-- | Renders a template with the specified parameters.  This is the function
-- to use when you want to "call" a template and pass in parameters from
-- inside a splice.
callTemplate :: Monad m
             => ByteString     -- ^ The name of the template
             -> [(Text, Text)] -- ^ Association list of
                               -- (name,value) parameter pairs
             -> TemplateMonad m (Maybe Template)
callTemplate name params = do
    modifyTS $ bindStrings params
    evalTemplate name


------------------------------------------------------------------------------
-- Gives the MIME type for a 'X.Document'
mimeType :: X.Document -> ByteString
mimeType d = case d of
    (X.HtmlDocument e _ _) -> "text/html;charset=" `BC.append` enc e
    (X.XmlDocument  e _ _) -> "text/xml;charset="  `BC.append` enc e
  where
    enc X.UTF8    = "utf-8"
    -- Should not include byte order designation for UTF-16 since
    -- rendering will include a byte order mark. (RFC 2781, Sec. 3.3)
    enc X.UTF16BE = "utf-16"
    enc X.UTF16LE = "utf-16"


------------------------------------------------------------------------------
-- | Renders a template from the specified TemplateState to a 'Builder'.  The
-- MIME type returned is based on the detected character encoding, and whether
-- the root template was an HTML or XML format template.  It will always be
-- @text/html@ or @text/xml@.  If a more specific MIME type is needed for a
-- particular XML application, it must be provided by the application.
renderTemplate :: Monad m
               => TemplateState m
               -> ByteString
               -> m (Maybe (Builder, MIMEType))
renderTemplate ts name = evalTemplateMonad tpl (X.TextNode "") ts
  where tpl = do mt <- evalWithHooksInternal name
                 case mt of
                    Nothing  -> return Nothing
                    Just doc -> return $ Just $ (X.render doc, mimeType doc)


------------------------------------------------------------------------------
-- | Renders a template with the specified arguments passed to it.  This is a
-- convenience function for the common pattern of calling renderTemplate after
-- using bindString, bindStrings, or bindSplice to set up the arguments to the
-- template.
renderWithArgs :: Monad m
                   => [(Text, Text)]
                   -> TemplateState m
                   -> ByteString
                   -> m (Maybe (Builder, MIMEType))
renderWithArgs args ts = renderTemplate (bindStrings args ts)


------------------------------------------------------------------------------
-- Template loading
------------------------------------------------------------------------------


------------------------------------------------------------------------------
-- | Type synonym for parsers.
type ParserFun = String -> ByteString -> Either String X.Document


------------------------------------------------------------------------------
-- | Reads an HTML or XML template from disk.
getDocWith :: ParserFun -> String -> IO (Either String X.Document)
getDocWith parser f = do
    bs <- catch (liftM Right $ B.readFile f)
                (\(e::SomeException) -> return $ Left $ show e)

    let d = either Left (parser f) bs
    return $ mapLeft (\s -> f ++ " " ++ s) d


------------------------------------------------------------------------------
-- | Reads an HTML template from disk.
getDoc :: String -> IO (Either String X.Document)
getDoc = getDocWith X.parseHTML


------------------------------------------------------------------------------
-- | Reads an XML template from disk.
getXMLDoc :: String -> IO (Either String X.Document)
getXMLDoc = getDocWith X.parseHTML


------------------------------------------------------------------------------
mapLeft :: (a -> b) -> Either a c -> Either b c
mapLeft g = either (Left . g) Right
mapRight :: (b -> c) -> Either a b -> Either a c
mapRight g = either Left (Right . g)


------------------------------------------------------------------------------
-- | Loads a template with the specified path and filename.  The
-- template is only loaded if it has a ".tpl" or ".xtpl" extension.
loadTemplate :: String -- ^ path of the template root
             -> String -- ^ full file path (includes the template root)
             -> IO [Either String (TPath, X.Document)] --TemplateMap
loadTemplate templateRoot fname
    | isHTMLTemplate = do
        c <- getDoc fname
        return [fmap (\t -> (splitLocalPath $ BC.pack tName, t)) c]
    | isXMLTemplate = do
        c <- getXMLDoc fname
        return [fmap (\t -> (splitLocalPath $ BC.pack tName, t)) c]
    | otherwise = return []
  where -- tName is path relative to the template root directory
        isHTMLTemplate = ".tpl"  `isSuffixOf` fname
        isXMLTemplate  = ".xtpl" `isSuffixOf` fname
        correction = if last templateRoot == '/' then 0 else 1
        extLen     = if isHTMLTemplate then 4 else 5
        tName = drop ((length templateRoot)+correction) $
                -- We're only dropping the template root, not the whole path
                take ((length fname) - extLen) fname


------------------------------------------------------------------------------
-- | Traverses the specified directory structure and builds a
-- TemplateState by loading all the files with a ".tpl" or ".xtpl" extension.
loadTemplates :: Monad m => FilePath -> TemplateState m
              -> IO (Either String (TemplateState m))
loadTemplates dir ts = do
    d <- readDirectoryWith (loadTemplate dir) dir
    let tlist = F.fold (free d)
        errs = lefts tlist
    case errs of
        [] -> liftM Right $ foldM loadHook ts $ rights tlist
        _  -> return $ Left $ unlines errs


------------------------------------------------------------------------------
-- | Reversed list of directories.  This holds the path to the template
runHook :: Monad m => (Template -> m Template)
        -> X.Document
        -> m X.Document
runHook f t = do
    n <- f $ X.docContent t
    return $ t { X.docContent = n }


------------------------------------------------------------------------------
-- | Runs the onLoad hook on the template and returns the `TemplateState`
-- with the result inserted.
loadHook :: Monad m => TemplateState m -> (TPath, X.Document)
         -> IO (TemplateState m)
loadHook ts (tp, t) = do
    t' <- runHook (_onLoadHook ts) t
    return $ insertTemplate tp t' ts


