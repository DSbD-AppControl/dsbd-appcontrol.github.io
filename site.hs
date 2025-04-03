--------------------------------------------------------------------------------
{-# LANGUAGE OverloadedStrings #-}

import Hakyll
import Hakyll.Images ( ensureFitCompiler,loadImage)
import Text.Pandoc.Highlighting (Style, tango, styleToCss)
import Text.Pandoc
import Text.Pandoc.Walk ( walk )
import System.Process ( readProcess )
import System.IO.Unsafe ( unsafePerformIO )
import qualified Data.Text as T

--------------------------------------------------------------------------------

config :: Configuration
config =
  defaultConfiguration
    { destinationDirectory = "docs"
    }

pandocCodeStyle :: Style
pandocCodeStyle = tango

svg :: String -> String
svg contents = unsafePerformIO $ do
    svgData <- readProcess "dot" ["-Tsvg"] contents
    let svgText = T.pack svgData
        -- Remove unwanted lines (XML and DOCTYPE declarations)
        cleanedSvgText = T.unlines $  filter (not . isUnwantedLine) $  T.lines svgText
    return $ T.unpack cleanedSvgText

isUnwantedLine :: T.Text -> Bool
isUnwantedLine line = any (`T.isInfixOf` line) unwantedStrings
  where
    unwantedStrings = ["<?xml", "<!DOCTYPE svg", "http://www.w3.org/Graphics/SVG/1.1/DTD/svg11.dtd"]



--------------------------------------------------------------------------------
graphViz :: Pandoc -> Pandoc
graphViz = walk codeBlock

codeBlock :: Block -> Block
codeBlock cb@(CodeBlock (id, classes, namevals) contents) =
    case lookup "lang" namevals of
        Just f -> RawBlock (Format "html") $ T.pack $ svg $ T.unpack contents
        Nothing -> cb
codeBlock x = x
--------------------------------------------------------------------------------

readPandocBiblios' :: ReaderOptions
                  -> Item CSL
                  -> [Item Biblio]
                  -> (Item String)
                  -> Compiler (Item Pandoc)
readPandocBiblios' ropt csl biblios item = do
  pandoc <-readPandocWith ropt item
  processPandocBiblios csl biblios (fmap graphViz pandoc)


pandocCompilerStyled :: String -> String -> Compiler (Item String)
pandocCompilerStyled cslFileName bibFileName = do
    csl  <- load    $ fromFilePath cslFileName
    bibs <- loadAll $ fromGlob bibFileName 
    fmap (writePandocWith wopt)
         (getResourceBody
          >>= readPandocBiblios' ropt csl bibs
         )
    where
        ropt = defaultHakyllReaderOptions
          {
              readerExtensions = enableExtension Ext_citations $ readerExtensions defaultHakyllReaderOptions
          }
        wopt = defaultHakyllWriterOptions
          {
              writerHighlightStyle   = Just pandocCodeStyle
          }

pandocBibCompiler :: Compiler (Item String)
pandocBibCompiler =
  pandocCompilerStyled "style.csl" "bibliography.bib"

main :: IO ()
main = hakyllWith config $ do

  match "*.bib" $ compile biblioCompiler
  match "*.csl" $ compile cslCompiler
  match "tex/*.csl" $ compile cslCompiler

  create ["css/syntax.css"] $ do
    route idRoute
    compile $ do
        makeItem $ styleToCss pandocCodeStyle

  match "logos/**" $ do
    route idRoute
    compile $
      loadImage
        >>= ensureFitCompiler 512 512

  match "images/*" $ do
    route idRoute
    compile copyFileCompiler

  match "artwork/*" $ do
      route idRoute
      compile copyFileCompiler
  match "media/*" $ do
      route idRoute
      compile copyFileCompiler

  match "css/*" $ do
    route idRoute
    compile compressCssCompiler

  match "about.html" $ do
    route idRoute
    compile $ do
      let indexCtx = defaultContext

      getResourceBody
        >>= applyAsTemplate indexCtx
        >>= loadAndApplyTemplate "templates/default.html" indexCtx
        >>= relativizeUrls

  match (fromList ["contact.markdown"]) $ do
    route $ setExtension "html"
    compile $
      pandocCompiler
        >>= loadAndApplyTemplate "templates/default.html" defaultContext
        >>= relativizeUrls

  match "posts/*" $ do
    route $ setExtension "html"
    compile $
      pandocBiblioCompiler "tex/ieee.csl" "biblio.bib"
        >>= loadAndApplyTemplate "templates/post.html" postCtx
        >>= loadAndApplyTemplate "templates/default.html" postCtx
        >>= relativizeUrls

  create ["posts.html"] $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let archiveCtx =
            listField "posts" postCtx (return posts)
              `mappend` constField "title" "Posts"
              `mappend` defaultContext

      makeItem ""
        >>= loadAndApplyTemplate "templates/archive.html" archiveCtx
        >>= loadAndApplyTemplate "templates/default.html" archiveCtx
        >>= relativizeUrls

  match "index.html" $ do
    route idRoute
    compile $ do
      posts <- recentFirst =<< loadAll "posts/*"
      let indexCtx =
            listField "posts" postCtx (return posts)
              `mappend` defaultContext

      getResourceBody
        >>= applyAsTemplate indexCtx
        >>= loadAndApplyTemplate "templates/default.html" indexCtx
        >>= relativizeUrls

  match "publications.md" $ do
    route   $ setExtension "html"
    compile $ pandocBiblioCompiler "tex/fullcite.csl" "publications.bib"
          >>= loadAndApplyTemplate "templates/default.html" defaultContext
          >>= relativizeUrls

  match "*.md" $ do
    route   $ setExtension "html"
    compile $ pandocCompiler
          >>= applyAsTemplate defaultContext
          >>= loadAndApplyTemplate "templates/default.html" defaultContext
          >>= relativizeUrls

  match "templates/*" $ compile templateCompiler

--------------------------------------------------------------------------------
postCtx :: Context String
postCtx =
  dateField "date" "%B %e, %Y"
    `mappend` defaultContext
