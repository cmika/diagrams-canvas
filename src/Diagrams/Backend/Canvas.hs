{-# LANGUAGE TypeFamilies          #-}
{-# LANGUAGE MultiParamTypeClasses #-}
{-# LANGUAGE FlexibleInstances     #-}
{-# LANGUAGE FlexibleContexts      #-}
{-# LANGUAGE GADTs                 #-}
{-# LANGUAGE TypeSynonymInstances  #-}
{-# LANGUAGE DeriveDataTypeable    #-}
{-# LANGUAGE ViewPatterns          #-}
{-# LANGUAGE InstanceSigs          #-}
{-# LANGUAGE OverloadedStrings     #-}
{-# LANGUAGE ScopedTypeVariables   #-}
{-# LANGUAGE TemplateHaskell       #-}

-------------------------------------------------------------------------------
-- |
-- Module      :  Diagrams.Backend.Canvas
-- Copyright   :  (c) 2010 - 2014 diagrams-canvas team (see LICENSE)
-- License     :  BSD-style (see LICENSE)
-- Maintainer  :  diagrams-discuss@googlegroups.com
--
-- A full-featured rendering backend for diagrams using Canvas.
-- Implemented using the blank-canvas platform.
--
-- To invoke the Canvas backend, you have three options.
--
-- * You can use the "Diagrams.Backend.Canvas.CmdLine" module to create
--   standalone executables which will display the diagram in a browser
--   using a web service.
--
-- * You can use the 'renderCanvas' function provided by this module,
--   which gives you more programmatic control over when and
--   how images are displayed (making it east to, for example, write a
--   single program that displays multiple images, or one that diaplays
--   images dynamically based on user input, and so on).
--
-- * For the most flexiblity you can invoke the 'renderDia' method from
--   'Diagrams.Core.Types.Backend' instance for @Canvas@. In particular,
--   'Diagrams.Core.Types.renderDia' has the generic type
--
-- > renderDia :: b -> Options b v -> QDiagram b v m -> Result b v
--
-- (omitting a few type class contraints). @b@ represents the
-- backend type, @v@ the vector space, and @m@ the type of monoidal
-- query annotations on the diagram. 'Options' and 'Result' are
-- associated data and type families, respectively, which yield the
-- type of option records and rendering results specific to any
-- particular backend. For @b ~ Canvas@ and @v ~ R2@, we have
--
-- > data Options Canvas R2 = CanvaseOptions
-- >  { _size :: SizeSpec2D -- ^^ The requested size
-- >  }
--
-- @
-- data family Render Canvas R2 = C (RenderM ())
-- @
--
-- @
-- type family Result Canvas R2 = Canvas ()
-- @
--
-- So the type of 'renderDia' resolves to
--
-- @
-- renderDia :: Canvas -> Options Canvas R2 -> QDiagram Canvas R2 m ->
-- Canvas()
-- @
--
-- which you could call like @renderDia Canvas (CanvaseOptions (width 250))
-- myDiagram@
--
------------------------------------------------------------------------------

module Diagrams.Backend.Canvas

  ( Canvas(..) -- rendering token
  , B
  , Options(..) -- for rendering options specific to Canvas

  , renderCanvas

  ) where

import           Control.Arrow                ((***))
import           Control.Lens                 hiding (transform, (#))
import           Control.Monad.State          (when, State, evalState)
import qualified Control.Monad.StateStack     as SS
import           Control.Monad.Trans          (lift)

import           Data.Default.Class
import qualified Data.Foldable                as F
import           Data.Maybe                   (catMaybes, isJust, fromJust, fromMaybe)
import           Data.NumInstances            ()
import qualified Data.Text                    as T
import           Data.Tree                    (Tree(Node))
import           Data.Typeable                (Typeable)
import           Data.Word                    (Word8)

import           Diagrams.Attributes
import           Diagrams.Prelude             hiding (fillTexture, moveTo, stroke)
import           Diagrams.TwoD.Adjust         (adjustDia2D)
import           Diagrams.TwoD.Attributes     (splitTextureFills)
import           Diagrams.TwoD.Path           (Clip (Clip))
import           Diagrams.TwoD.Text
import           Diagrams.TwoD.Types          (R2(..))

import           Diagrams.Core.Compile
import           Diagrams.Core.Transform      (matrixHomRep)
import           Diagrams.Core.Types          (Annotation (..))

import qualified Graphics.Blank               as BC
import qualified Graphics.Blank.Style         as S

-- | This data declaration is simply used as a token to distinguish
--   this rendering engine.
data Canvas = Canvas
    deriving (Eq, Ord, Read, Show, Typeable)

type B = Canvas

data CanvasState = CanvasState { _accumStyle :: Style R2
                               , _csPos :: (Double, Double) }

makeLenses ''CanvasState

instance Default CanvasState where
  def = CanvasState { _accumStyle = mempty
                    , _csPos = (0,0) }

type RenderM a = SS.StateStackT CanvasState BC.Canvas a

liftC :: BC.Canvas a -> RenderM a
liftC = lift

runRenderM :: RenderM a -> BC.Canvas a
runRenderM = flip SS.evalStateStackT def

instance Monoid (Render Canvas R2) where
  mempty  = C $ return ()
  (C c1) `mappend` (C c2) = C (c1 >> c2)

instance Backend Canvas R2 where
  data Render  Canvas R2 = C (RenderM ())
  type Result  Canvas R2 = BC.Canvas ()
  data Options Canvas R2 = CanvasOptions
          { _canvasSize   :: SizeSpec2D   -- ^ the requested size
          }

  renderRTree :: Canvas -> Options Canvas R2 -> RTree Canvas R2 Annotation
                        -> Result Canvas R2
  renderRTree _ _ rt = evalState canvasOutput initialCanvasRenderState
    where
      canvasOutput :: State CanvasRenderState (BC.Canvas ())
      canvasOutput = do
        let C r = toRender rt
        return $ runRenderM $ r

  adjustDia c opts d = adjustDia2D size c opts (d # reflectY)

runC :: Render Canvas R2 -> RenderM ()
runC (C r) = r

toRender :: RTree Canvas R2 Annotation -> Render Canvas R2
toRender = fromRTree
  . Node (RStyle (mempty # recommendFillColor (transparent :: AlphaColour Double)))
  . (:[])
  . splitTextureFills
    where
      fromRTree (Node (RPrim p) _) = render Canvas p
      fromRTree (Node (RStyle sty) rs) = C $ do
        save
        canvasStyle sty
        accumStyle %= (<> sty)
        runC $ F.foldMap fromRTree rs
        restore
      fromRTree (Node _ rs) = F.foldMap fromRTree rs

data CanvasRenderState = CanvasRenderState

initialCanvasRenderState :: CanvasRenderState
initialCanvasRenderState = CanvasRenderState

getSize :: Options Canvas R2 -> SizeSpec2D
getSize (CanvasOptions {_canvasSize = s}) = s

setSize :: Options Canvas R2 -> SizeSpec2D -> Options Canvas R2
setSize o s = o {_canvasSize = s}

size :: Lens' (Options Canvas R2) SizeSpec2D
size = lens getSize setSize

move :: (Double, Double) -> RenderM ()
move p = do csPos .= p

save :: RenderM ()
save = SS.save >> liftC (BC.save ())

restore :: RenderM ()
restore = liftC (BC.restore ()) >> SS.restore

newPath :: RenderM ()
newPath = liftC $ BC.beginPath ()

closePath :: RenderM ()
closePath = liftC $ BC.closePath ()

moveTo :: Double -> Double -> RenderM ()
moveTo x y = do
  let x' = realToFrac x
      y' = realToFrac y
  liftC $ BC.moveTo (x', y')
  move (x', y')

relLineTo :: Double -> Double -> RenderM ()
relLineTo x y = do
  p <- use csPos
  let p' = p + (realToFrac x, realToFrac y)
  liftC $ BC.lineTo p'
  move p'

relCurveTo :: Double -> Double -> Double -> Double -> Double -> Double -> RenderM ()
relCurveTo ax ay bx by cx cy = do
  p <- use csPos
  let [(ax',ay'),(bx',by'),(cx',cy')] = map ((p +) . (realToFrac *** realToFrac))
                                          [(ax,ay),(bx,by),(cx,cy)]
  liftC $ BC.bezierCurveTo (ax',ay',bx',by',cx',cy')
  move (cx', cy')

-- | Get an accumulated style attribute from the render monad state.
getStyleAttrib :: AttributeClass a => (a -> b) -> RenderM (Maybe b)
getStyleAttrib f = (fmap f . getAttr) <$> use accumStyle

-- | From the HTML5 canvas specification regarding line width:
--
--     "On setting, zero, negative, infinite, and NaN values must be
--     ignored, leaving the value unchanged; other values must change
--     the current value to the new value.
--
--   Hence we must implement a line width of zero by simply not
--   sending a stroke command.
stroke :: RenderM ()
stroke = do
  -- The default value of 0.5 is somewhat arbitary since lineWidth should neve
  -- be 'Nothing'. 0.5 is choose since it is the lower bound of the
  -- default.
  w <- fromMaybe 0.5 <$> getStyleAttrib (fromOutput . getLineWidth)
  when (w > 0) (liftC $ BC.stroke ())

fill :: RenderM ()
fill = liftC $ BC.fill ()

clip :: RenderM ()
clip = liftC $ BC.clip ()

byteRange :: Double -> Word8
byteRange d = floor (d * 255)

data TextureUse = Fill | Strk

texture :: TextureUse -> Texture -> Double -> RenderM()
texture u (SC (SomeColor c))  o = case u of
    Fill -> liftC . S.fillStyle   $ s
    Strk -> liftC . S.strokeStyle $ s
  where s = showColorJS c o

texture u (LG g) _ = liftC $ do
  grd <- BC.createLinearGradient (x0, y0, x1, y1)
  mapM_ (flip BC.addColorStop $ grd) stops
  case u of
    Fill -> S.fillStyle grd
    Strk -> S.strokeStyle grd
  where
    (x0', y0') = unp2 $ transform (g^.lGradTrans) (g^.lGradStart)
    (x1', y1') = unp2 $ transform (g^.lGradTrans) (g^.lGradEnd)
    (x0, y0, x1, y1) = ( realToFrac x0', realToFrac y0'
                       , realToFrac x1', realToFrac y1')
    stops = map (\s -> ( realToFrac (s^.stopFraction)
                       , showColorJS (s^.stopColor) 1)) (g^.lGradStops)

texture u (RG g) _ = liftC $ do
  grd <- BC.createRadialGradient (x0, y0, r0, x1, y1, r1)
  mapM_ (flip BC.addColorStop $ grd) stops
  case u of
    Fill -> S.fillStyle grd
    Strk -> S.strokeStyle grd
  where
    (r0, r1) = (s * realToFrac (g^.rGradRadius0), s * realToFrac  (g^.rGradRadius1))
    (x0', y0') = unp2 $ transform (g^.rGradTrans) (g^.rGradCenter0)
    (x1', y1') = unp2 $ transform (g^.rGradTrans) (g^.rGradCenter1)
    (x0, y0, x1, y1) = ( realToFrac x0', realToFrac y0'
                       , realToFrac x1', realToFrac y1')
    stops = map (\st -> ( realToFrac (st^.stopFraction)
                        , showColorJS (st^.stopColor) 1)) (g^.rGradStops)
    s = realToFrac . avgScale $ (g^.rGradTrans)

showColorJS :: (Color c) => c -> Double  -> T.Text
showColorJS c o = T.concat
    [ "rgba("
    , s r, ","
    , s g, ","
    , s b, ","
    , T.pack (show $ a * o)
    , ")"
    ]
  where s :: Double -> T.Text
        s = T.pack . show . byteRange
        (r,g,b,a) = colorToSRGBA . toAlphaColour $  c

canvasTransform :: T2 -> RenderM ()
canvasTransform tr = liftC $ BC.transform vs
    where
      [[ax, ay], [bx, by], [tx, ty]] = matrixHomRep tr
      vs = (realToFrac ax,realToFrac ay
           ,realToFrac bx,realToFrac by
           ,realToFrac tx,realToFrac ty)

strokeTexture :: Texture -> Double  -> RenderM ()
strokeTexture = texture Strk

fillTexture :: Texture -> Double  -> RenderM ()
fillTexture = texture Fill

fromLineCap :: LineCap -> BC.LineEndCap
fromLineCap LineCapRound  = BC.RoundCap
fromLineCap LineCapSquare = BC.SquareCap
fromLineCap _             = BC.ButtCap

fromLineJoin :: LineJoin -> BC.LineJoinCorner
fromLineJoin LineJoinRound = BC.RoundCorner
fromLineJoin LineJoinBevel = BC.BevelCorner
fromLineJoin _             = BC.MiterCorner

showFontJS :: FontWeight -> FontSlant -> Double -> String -> T.Text
showFontJS wgt slant sz fnt = T.concat [a, " ", b, " ", c, " ", d]
  where
    a = case wgt of
          FontWeightNormal -> ""
          FontWeightBold   -> "bold"
    b = case slant of
          FontSlantNormal  -> ""
          FontSlantItalic  -> "italic"
          FontSlantOblique -> "oblique"
    c = T.concat [T.pack $ show sz, "pt"]
    d = T.pack fnt

renderC :: (Renderable a Canvas, V a ~ R2) => a -> RenderM ()
renderC a = case (render Canvas a) of C r -> r

canvasStyle :: Style v -> RenderM ()
canvasStyle s = sequence_
              . catMaybes $ [ handle clip'
                            , handle lWidth
                            , handle lCap
                            , handle lJoin
                            ]
  where handle :: (AttributeClass a) => (a -> RenderM ()) -> Maybe (RenderM ())
        handle f = f `fmap` getAttr s
        clip'    = mapM_ (\p -> canvasPath p >> clip) . op Clip
        lWidth   = liftC . BC.lineWidth . realToFrac . fromOutput . getLineWidth
        lCap     = liftC . BC.lineCap . fromLineCap . getLineCap
        lJoin    = liftC .  BC.lineJoin . fromLineJoin . getLineJoin

instance Renderable (Segment Closed R2) Canvas where
  render _ (Linear (OffsetClosed (R2 x y))) = C $ relLineTo x y
  render _ (Cubic (R2 x1 y1)
                  (R2 x2 y2)
                  (OffsetClosed (R2 x3 y3)))
    = C $ relCurveTo x1 y1 x2 y2 x3 y3

instance Renderable (Trail R2) Canvas where
  render _ = withTrail renderLine renderLoop
    where
      renderLine ln = C $ do
        mapM_ renderC (lineSegments ln)
      renderLoop lp = C $ do
        case loopSegments lp of
          (segs, Linear _) -> mapM_ renderC segs
          _ -> mapM_ renderC (lineSegments . cutLoop $ lp)
        closePath

instance Renderable (Path R2) Canvas where
  render _ p = C $ do
    canvasPath p
    f <- getStyleAttrib getFillTexture
    s <- getStyleAttrib getLineTexture
    o <- fromMaybe 1 <$> getStyleAttrib getOpacity
    save
    when (isJust f) (fillTexture (fromJust f) o >> fill)
    strokeTexture (fromMaybe (SC (SomeColor (black :: Colour Double))) s) o
    stroke
    restore

-- Add a path to the Canvas context, without stroking or filling it.
canvasPath :: Path R2 -> RenderM ()
canvasPath (Path trs) = do
    newPath
    F.mapM_ renderTrail trs
  where
    renderTrail (viewLoc -> (unp2 -> p, tr)) = do
      uncurry moveTo p
      renderC tr

instance Renderable Text Canvas where
  render _ (Text tt tn al str) = C $ do
    isLocal <- fromMaybe True <$> getStyleAttrib getFontSizeIsLocal
    tf      <- fromMaybe "Calibri" <$> getStyleAttrib getFont
    sz      <- fromMaybe 12 <$> getStyleAttrib (fromOutput . getFontSize)
    slant   <- fromMaybe FontSlantNormal <$> getStyleAttrib getFontSlant
    fw      <- fromMaybe FontWeightNormal <$> getStyleAttrib getFontWeight
    tx      <- fromMaybe (SC (SomeColor (black :: Colour Double)))
               <$> getStyleAttrib getFillTexture
    o       <- fromMaybe 1 <$> getStyleAttrib getOpacity
    let fSize = if isLocal
                        then avgScale tt * sz
                        else sz
        fnt = showFontJS fw slant fSize tf
        vAlign = case al of
                   BaselineText -> BC.AlphabeticBaseline
                   BoxAlignedText _ h -> case h of
                     h' | h' <= 0.25 -> BC.BottomBaseline
                     h' | h' >= 0.75 -> BC.TopBaseline
                     _ -> BC.MiddleBaseline
        hAlign = case al of
                   BaselineText -> BC.StartAnchor
                   BoxAlignedText w _ -> case w of
                     w' | w' <= 0.25 -> BC.StartAnchor
                     w' | w' >= 0.75 -> BC.EndAnchor
                     _ -> BC.CenterAnchor
    save
    liftC $ BC.textBaseline vAlign
    liftC $ BC.textAlign hAlign
    liftC $ BC.font fnt
    fillTexture tx o
    canvasTransform (tn <> reflectionY)
    liftC $ BC.fillText (T.pack str, 0, 0)
    restore

instance Renderable (DImage External) Canvas where
  render _ (DImage path w h tr) = C $ do
    let ImageRef file = path
    save
    canvasTransform (tr <> reflectionY)
    img <- liftC $ BC.newImage (T.pack file)
    liftC $ BC.drawImage (img, [fromIntegral (-w) / 2, fromIntegral (-h) / 2, fromIntegral w, fromIntegral h])
    restore

renderCanvas :: Int -> SizeSpec2D -> Diagram Canvas R2 -> IO ()
renderCanvas port sizeSpec d = BC.blankCanvas (fromIntegral port) . flip BC.send $ img
    where
      img = renderDia Canvas (CanvasOptions sizeSpec) d
