# Codenotch UI Documentation

Frontend interface implementation for Codenotch on Windows, built with HTML5, CSS3, SVG, and WebView2.

## Structure

- **notch.html**: Main floating notch UI, provider usage rings, card hover flyout, settings orb (`#orb`), and drag handle dots (`#grip`).
- **settings.html**: Multi-tab settings panel (Appearance, Accounts, About).
- **taskbar.html**: Taskbar usage strip rendering when configured in taskbar mode.
- **carry.html**: Interactive screen-edge snapping and drag handle preview.
- **reset-alert.html**: Floating notification card displayed when a quota window renews.

## Anti-Aliasing and Edge Smoothing

The UI supports separate anti-aliasing modes configured through Settings:

### Borders Anti-Aliasing (`antialias_border`)
- **Off**: Standard CSS borders and SVG strokes.
- **Subpixel**: Subpixel edge feathering (`--aa-feather: 0.7px`) and subpixel shadow smoothing on `.h-disc`, `.h-rest`, and `#grip`.
- **Vector SVG**: Replaces CSS border fillets with open SVG vector contour paths (`#pillContourStroke`), leaving the screen-touching edge unbordered.
- **SSAA 4x**: Vector path rendering combined with an SVG convolution filter (`#ssaaSmooth`) applied to border strokes, fillets, `.h-disc`, `.h-rest`, and `#grip`.

### Content Anti-Aliasing (`antialias_internal`)
- **Off**: Standard vector rendering.
- **Subpixel**: Applies geometric precision and subtle subpixel drop-shadow feathering to internal glyphs and meters.
- **SSAA 4x**: Applies `#ssaaSmooth` convolution (`stdDeviation="0.38"`) to provider ring arcs, brand logos (`.glyph svg`), percentage readouts (`.pct`), settings gear glyph (`.h-glyph`), the six drag handle dots (`#grip`), and hover card elements.
- **SSAA 8x**: Aggressive multisample convolution (`#ssaa8x`, `stdDeviation="0.62"`) that thoroughly eliminates stair-stepping on 1080p diagonal lines, complex logos (DeepSeek whale, OpenAI spiral, Antigravity chevron), and ring tracks.
- **Ultra**: Maximum aggressive smoothing (`#ssaaUltra`, `stdDeviation="0.90"`, slope 1.30) designed for 1080p displays to completely eliminate all visible aliasing while preserving edge sharpness and contrast.

### Border Styling
- **Defaults**: Borders anti-aliasing defaults to `ssaa` (`SSAA 4x`), Content anti-aliasing defaults to `ssaa` (`SSAA 4x`), Border thickness defaults to `2.5 px`, and Border opacity defaults to `15%`.
- **Thickness**: Configurable from 0.0 px to 3.0 px via `--edge-w`. Setting to 0 px removes all borders.
- **Opacity**: Configurable from 0% to 100%.
- **Colour**: Native colour picker (`picker-border-color`) driving `--edge` and `--rest-edge`.
- **Open Edge**: The side of the pill meeting the display edge never renders a stroke.
- **Contour Guard**: `#pill` retains its native CSS fill until `#pillContour` has valid measured dimensions (`body.contour-ready`), and SVG filters (`#ssaaSmooth`, `#ssaa8x`, `#ssaaUltra`) reside in an always-mounted `#aaDefs` container so the notch background is always visible from the first frame across all anti-aliasing modes.

## Antigravity Composite Calculation

The overall Antigravity percentage in `headlineOf` is computed using weighted quotas:
- 25% Argon
- 25% Claude and GPT (5h)
- 50% Gemini Models (5h)

