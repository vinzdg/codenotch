# Provider asset sources

## Ollama

`Sources/Assets.xcassets/glyph-ollama.imageset/ollama.svg` is the unchanged
[Ollama documentation mark](https://github.com/ollama/ollama/blob/83ed7d9965b1ee07e0f0b29fd46e47c31f0fcab8/docs/ollama-logo.svg),
retrieved on 2026-09-07. Its original 17:25 aspect ratio is preserved.

The asset catalog preserves its vector representation and marks it as a
template. `ProviderGlyphView` applies the same foreground color, fixed frame
and asset lookup used by the other providers, so the mark works on both the
dark notch and the Settings background.

## Devin

`glyph-devin` uses the current Devin Desktop mark — the three connected
hexagons — extracted from the installed app icon
(`/Applications/Devin.app/Contents/Resources/Devin.default.png`) on
2026-09-10. The white rounded-square plate was removed; the remaining black
mark was isolated on a transparent background and stored as
`devin.png`. The image set is marked as a template so
`ProviderGlyphView` tints it like the other provider glyphs.

## QianwenAI

`Sources/Assets.xcassets/glyph-qianwenai.imageset/qianwenai.png` is the
QianwenAI / Qwen star, supplied by the maintainer on 2026-09-18 as a colour
PNG (a purple star crossed by three white bands). `ProviderGlyphView` tints
everything it draws in one colour, so the colour art cannot be used as is:
the purple was kept as the mark and the white bands became cut-outs,
thresholded on saturation so the anti-aliased edges stay soft. The result
was centred in a 512 px transparent square and stored as a template PNG
(no vector tracer was available). The earlier favicon-derived SVG it
replaces is in the git history.

## MiniMax

`Sources/Assets.xcassets/glyph-minimax.imageset/minimax.svg` is Lobe Icons'
monochrome MiniMax mark, supplied by the maintainer on 2026-09-18, adapted the
same way as the other marks: `fill="#000"`, numeric `width="24"` /
`height="24"`, the title and web-only style removed. It is drawn in place of
the geometric `GlyphOutline.minimax`, which stays as the fallback.

## Z.ai (GLM), Kimi, OpenCode and Command Code

`glyph-glm.imageset/zai.svg`, `glyph-kimi.imageset/kimi.svg` and
`glyph-opencode.imageset/opencode.svg` are Lobe Icons' monochrome Z.ai, Kimi
and OpenCode marks, supplied by the maintainer on 2026-09-18 and
adapted like MiniMax's. `glyph-commandcode.imageset/commandcode.svg` is taken
from Command Code's own "Logo Mark – Light" (via zonalogo.com): only its ⌘
path is kept — the black rounded plate and the thin white ring round its edge
are dropped, since `ProviderGlyphView` tints everything one colour and the
plate would come out as a solid square — with the `viewBox` cropped to the ⌘
(`26.18 26.18 84.64 84.64`). The traced `GlyphOutline` shapes stay as
fallbacks for all four.

## LM Studio

`Sources/Assets.xcassets/glyph-lmstudio.imageset/lmstudio.svg` is Lobe Icons'
monochrome LM Studio mark (`packages/static-svg/icons/lmstudio.svg`) from the
same pinned commit `a94750e3f5f8fc33757b839d85030e742284e43a`, retrieved
2026-09-10, adapted the same way as the brand marks below: `fill="#000"`,
numeric `width="24"` / `height="24"`, web-only style removed. The mark's
lighter second layer is a `fill-opacity` on the path and survives template
rendering as partial alpha, which is how the original reads too.
`LMStudioProviderTests.testTheGlyphAssetRendersAsAMarkNotASquare` checks the
native render.

## oMLX

`Sources/Assets.xcassets/glyph-omlx.imageset/omlx.svg` is oMLX's own
`menubar-filled.svg`, taken from
`/Applications/oMLX.app/Contents/Resources/omlx/admin/static/` (oMLX 0.7.0,
package licensed Apache-2.0 per its SPDX headers), retrieved 2026-10-08. It is
a single black potrace path in a 497×497 viewBox, adapted like the LM Studio
mark: XML declaration, DOCTYPE and `<metadata>` dropped, numeric
`width="24"` / `height="24"`, a `<title>`, and the `<g>` and `<path>` left
unchanged. `OMLXProviderTests.testTheGlyphAssetRendersAsAMarkNotASquare`
checks the native render.

## Local model brands

Qwen, Gemma, Meta (for Llama), DeepSeek and Mistral use monochrome vectors from
[Lobe Icons](https://github.com/lobehub/lobe-icons/tree/a94750e3f5f8fc33757b839d85030e742284e43a/packages/static-svg/icons),
pinned to commit `a94750e3f5f8fc33757b839d85030e742284e43a` and retrieved
2026-09-07. These are Lobe Icons' brand representations, not files claimed to
have been published directly by each model vendor.

| Local image set | Upstream file |
| --- | --- |
| `glyph-qwen` | `packages/static-svg/icons/qwen.svg` |
| `glyph-gemma` | `packages/static-svg/icons/gemma.svg` |
| `glyph-meta` | `packages/static-svg/icons/meta.svg` |
| `glyph-deepseek` | `packages/static-svg/icons/deepseek.svg` |
| `glyph-mistral` | `packages/static-svg/icons/mistral.svg` |

Path geometry and the 24 × 24 view box are preserved. For native asset-catalog
compatibility, the root uses `fill="#000"` and numeric `width="24"` /
`height="24"`; the web-only `flex`/`line-height` style is removed. Keeping
`currentColor` and `1em` produced solid placeholder squares in the native view.
All five image sets preserve vector data and use template rendering.

The upstream MIT copyright and license are included in
`Sources/Resources/LobeIcons-LICENSE.txt` and copied into the app bundle.
`LocalModelBrandTests` verifies asset lookup, nonempty nonrectangular native
rendering and the bundled license; notch and tooltip fixtures cover all marks.

## Apify

`Sources/Assets.xcassets/glyph-apify.imageset/apify.svg` is Apify's own mark,
the three-piece "A" served as the site favicon at
[apify.com/favicon.svg](https://apify.com/favicon.svg), retrieved on
2026-09-25. The original is three colours (blue, green and orange) on a 1080 px
box; `ProviderGlyphView` tints everything one colour, so the three paths keep
their geometry and lose their fills (`fill="#000"` on the root, numeric
`width="24"` / `height="24"`), and the `viewBox` is cropped to the ink
(`78.22 78.22 923.56 923.56`) so the mark fills its box the way the traced
outlines do. The gaps between the pieces are what keep it legible in one
colour. Image set marked as a template with vector data preserved;
`ApifyProviderTests.testTheGlyphAssetRendersAsAMarkNotASquare` checks the
native render.

## llama.cpp

`glyph-llamacpp` uses the official `icon/icon-dark.svg` from
[ggml-org/llama.brand](https://github.com/ggml-org/llama.brand/tree/0708f2327336589bd4d3eba15a95199c318cd771),
retrieved 2026-09-28. The original two paths and viewBox are unchanged; the
asset is scaled and rendered as a template by `ProviderGlyphView`.

The asset is CC BY-NC 4.0 with explicit additional permission for identifying
llama.cpp in software distributions, including commercial distributions, and
for scaling and monochrome rendering. This asset is not MIT-licensed. The
license, source credit, and additional brand permission ship in
`Sources/Resources/LlamaBrand-LICENSE.txt` and `LlamaBrand-NOTICE.txt`.
