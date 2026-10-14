# Moonglade's notch look, and what Verse took from it

Read 2026-10-14 in `~/Developer/Moonglade` (MIT, Copyright (c) 2026 Josemi Hernandez; the working tree has an
uncommitted local patch in `FocusService`, `ProcessScanner` and a test, none of which touch the files below). Files
read: `Sources/MoongladeApp/{NotchPanel,NotchGlassBackground,NotchWidgetView,RippleEffect}.swift`,
`Sources/MoongladeCore/Presentation/{HangingNotchGeometry,NotchGlassStyle,NotchLayout}.swift`. The installed
`/Applications/Moonglade.app` (0.1.0) was captured live over Verse's two test backdrops for
`app/build/screens/compare-moonglade.png`.

## How Moonglade builds it

| Part | Moonglade | Taken into Verse |
|---|---|---|
| Panel | Borderless non-activating `NSPanel`, `.statusBar` level, `[.canJoinAllSpaces, .fullScreenAuxiliary, .stationary]`, clear, no shadow. Fixed at the expanded size (800 x ~356 pt) so it never resizes while the shape animates; a hosting-view `hitTest` passes clicks outside the silhouette through. | Verse keeps its own panel (level above the menu bar, sized to content, grows on the next run-loop turn, shrinks after the morph). Taken: the silhouette `hitTest` (`OverlayHostingView`), no extra window margin (the window is exactly the surface), and centring on the camera housing (`auxiliaryTopLeftArea.maxX` / `auxiliaryTopRightArea.minX`) instead of the screen's middle. |
| Frame against the notch | `safeAreaInsets.top` is the band height; notch edges from the two auxiliary areas; top edge on the screen edge (zero gap). | Same: band = `safeAreaInsets.top` (32 pt here), top flush with the screen. |
| Shape | `HangingNotchGeometry`: concave top shoulders (radius 14) that flare into the screen edge, straight sides, round bottom corners (radius 20). Compact and expanded use the same curves; growing only lengthens the straight parts. A short rect shrinks both arcs evenly. | Ported as is (`HangingNotchGeometry.swift`), minus the pill/bubble style for screens without a notch and the `DisplayPoint` interaction-region type. |
| One shape | One view tree: the bar never leaves; expanding grows one silhouette out of the notch. | Same idea: `OverlayView` is one surface; the capsule row stays at its place in the band, the card/status/topics sit under it, the glass grows from capsule size to content size. This removes the old 8 pt gap between the black pill and the floating card. |
| Glass | Self-owned `CABackdropLayer` with the private `glassBackground` filter plus a `CASDFLayer`/`CASDFElementLayer` lens stack (the recipe inside `NSGlassEffectView`), masked to the silhouette. Reason given in the code, and true here: SwiftUI `glassEffect` samples only its own window (flat grey in a clear panel over other apps); `NSGlassEffectView` re-commits its filter values. Fallback: `NSVisualEffectView` behind-window blur with a stretchable silhouette mask. | Ported (`NotchGlass.swift`): same layer stack, system clear baseline, Moonglade's lens overrides (face wash 0, inner refraction -80 over 26 pt). Fallback ported. It also renders in Verse's `--render-screens` window: the backdrop layer samples the in-window test background. |
| Tint | `NotchGlassScrim`: an elliptical black gradient (centre 0.7 above the top) that is pure black through the band (+6 pt) and dissolves with a smootherstep to a floor (default 0.22), so the camera cutout never shows and the drop fades to smoked glass. Frost (blur) 1. | Same gradient and curve. **Floor 0.70 and frost 3 instead of 0.22 and 1**: Moonglade sits over the dark menu bar; Verse's card must stay readable over a white page and a busy video frame. Measured on the renders: white text >= 9.4:1 over the white page, 0.88-white points >= 7.8:1. At Moonglade's 0.22 its own lower rows are unreadable over the white page (see the comparison sheet). Frost barely changes contrast (the tint dominates), so it stays near Moonglade's clear lensing. |
| Motion | `.spring(response: 0.32, dampingFraction: 0.86)` on expand, plus a 0.9 s Metal ripple on the scrim. | **Not taken.** Verse's rules: morph <= 150 ms, no spring, no bounce. The glass size follows the content with `easeOut(0.14)`; text is placed at once at full opacity (never animated). The ripple runs 0.9 s and is decoration. |
| Sizing to content | Measures the card with a preference key and publishes the interactive region; the panel itself stays fixed. | Verse measures the content (`onGeometryChange`) and animates the glass to it; the panel follows the content size as before. Card width stays the user's 420-960 pt, text scale S/M/L as before. |

## Checked

- The AppKit glass view follows SwiftUI's animated frame: frames captured from a deliberately slowed (1.6 s) morph in
  the real panel show the surface growing out of the notch at intermediate sizes, centred on the camera.
- Moonglade's window captured on its own (`screencapture -l`) comes back black where the glass is: window-only captures
  do not include what the backdrop samples, so the comparison uses a region capture over a known backdrop.

## Left out

Pill/bubble presentation for screens without a notch (Verse keeps the hanging shape on every screen), hover
expansion, the session menu, settings sliders for tint/frost, the ripple shader, the spring.
