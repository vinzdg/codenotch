//! Native taskbar graphics. The caller owns the HWND, input, and account data.
//! Transparent pixels remain part of the native window's client hit area.
//! Each cell is drawn as the notch's `renderRing` draws it, in the same 56-unit box: hole r22,
//! track and reading r25 × 5, weekly r31 outside or r16 inside × 2.4, activity r19 × 2.5, glyph 26.
#![cfg(windows)]

use crate::taskbar_model::{self, Frame, Indicator, Slot};
use std::{collections::HashMap, marker::PhantomData, rc::Rc};
use windows::{
    core::{w, Error, Interface, Result},
    Foundation::Numerics::Matrix3x2,
    Win32::{
        Foundation::{E_INVALIDARG, E_OUTOFMEMORY, E_UNEXPECTED, HMODULE, HWND, POINT},
        Graphics::{
            Direct2D::{
                Common::{D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_FIGURE_BEGIN_HOLLOW, D2D1_FIGURE_END_OPEN,
                    D2D1_PIXEL_FORMAT, D2D_POINT_2F, D2D_RECT_F, D2D_SIZE_F},
                D2D1CreateDevice, ID2D1Device, ID2D1DeviceContext, ID2D1DeviceContext5, ID2D1Factory,
                ID2D1Image, ID2D1Layer, ID2D1SolidColorBrush, ID2D1StrokeStyle, ID2D1SvgDocument,
                D2D1_ANTIALIAS_MODE_ALIASED, D2D1_ANTIALIAS_MODE_PER_PRIMITIVE, D2D1_ARC_SEGMENT, D2D1_ARC_SIZE_SMALL,
                D2D1_BITMAP_OPTIONS_CANNOT_DRAW, D2D1_BITMAP_OPTIONS_TARGET, D2D1_BITMAP_PROPERTIES1,
                D2D1_CAP_STYLE_FLAT, D2D1_CAP_STYLE_ROUND, D2D1_DASH_STYLE_SOLID, D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                D2D1_DRAW_TEXT_OPTIONS_CLIP, D2D1_ELLIPSE, D2D1_LAYER_PARAMETERS1,
                D2D1_LINE_JOIN_ROUND, D2D1_STROKE_STYLE_PROPERTIES, D2D1_SWEEP_DIRECTION_CLOCKWISE,
                D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            },
            Direct3D::{D3D_DRIVER_TYPE, D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP},
            Direct3D11::{D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION},
            DirectComposition::{DCompositionCreateDevice, IDCompositionDevice, IDCompositionSurface, IDCompositionTarget, IDCompositionVisual},
            DirectWrite::{
                DWriteCreateFactory, IDWriteFactory, IDWriteFontCollection, IDWriteTextFormat, IDWriteTypography,
                DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_FEATURE, DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES,
                DWRITE_FONT_STRETCH_NORMAL, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_WEIGHT, DWRITE_FONT_WEIGHT_BOLD,
                DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_MEASURING_MODE_NATURAL, DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
                DWRITE_TEXT_ALIGNMENT_CENTER, DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_TEXT_RANGE, DWRITE_WORD_WRAPPING_NO_WRAP,
            },
            Dxgi::{Common::{DXGI_ALPHA_MODE_PREMULTIPLIED, DXGI_FORMAT_B8G8R8A8_UNORM}, IDXGIAdapter, IDXGIDevice, IDXGISurface},
        },
        UI::Shell::SHCreateMemStream,
    },
};

/// The notch's CSS custom properties. The dark notch sits on a black pill, so its opaque greys
/// become white at the same strength here, over whatever the taskbar shows.
struct Palette { ink: D2D1_COLOR_F, glyph: D2D1_COLOR_F, track: D2D1_COLOR_F, hole: D2D1_COLOR_F, watch: D2D1_COLOR_F }

fn palette(dark: bool) -> Palette {
    if dark {
        Palette { ink:rgb(0xffffff), glyph:rgb(0xe8e8ea), track:rgba(1.0, 1.0, 1.0, 48.0 / 255.0),
            hole:rgba(1.0, 1.0, 1.0, 42.0 / 255.0), watch:rgb(0xf2ff00) }
    } else {
        Palette { ink:rgb(0x1d1d1f), glyph:rgb(0x1d1d1f), track:rgba(0.0, 0.0, 0.0, 0.16),
            hole:rgb(0xffffff), watch:rgb(0xb08800) }
    }
}

/// The notch's fallback letters, for a provider with no built-in mark (z.ai) or one Direct2D
/// cannot read.
fn letter(provider: &str) -> &'static str {
    match provider {
        "claude" => "C", "codex" => "Cx", "glm" => "Z.ai", "deepseek" => "DS", "opencode" => "OC",
        "commandcode" => "CC", "cursor" => "Cu", "grok" => "Gk", "copilot" => "Cp", "gemini" => "Ag",
        "qoder" => "Q", _ => "?",
    }
}

const TAU: f32 = std::f32::consts::TAU;
/// `.dim` and `.ringwrap.stale`, and `.ringwrap.pressed` while a click refreshes.
const FADED: f32 = 0.55;
const PRESSED: f32 = 0.93;

pub struct Renderer {
    context: ID2D1DeviceContext,
    svg_context: ID2D1DeviceContext5,
    factory: ID2D1Factory,
    /// The dark and the light document of each built-in mark.
    logos: HashMap<&'static str, [ID2D1SvgDocument; 2]>,
    brush: ID2D1SolidColorBrush,
    round: ID2D1StrokeStyle,
    flat: ID2D1StrokeStyle,
    write_factory: IDWriteFactory,
    tabular: IDWriteTypography,
    /// Text formats by weight and size, so a size change makes one and not one a frame.
    formats: HashMap<(i32, u32), IDWriteTextFormat>,
    surface: IDCompositionSurface,
    target: IDCompositionTarget,
    visual: IDCompositionVisual,
    composition: IDCompositionDevice,
    _d2d_device: ID2D1Device,
    _dxgi_device: IDXGIDevice,
    _d3d_device: ID3D11Device,
    width: u32,
    height: u32,
    driver: &'static str,
    // Graphics creation, drawing, resizing and release stay on the HWND's thread.
    _thread_bound: PhantomData<Rc<()>>,
}

impl Renderer {
    pub fn new(hwnd: HWND, width: u32, height: u32) -> Result<Self> {
        validate_size(width, height)?;
        Self::with_driver(hwnd, width, height, D3D_DRIVER_TYPE_HARDWARE, "hardware")
            .or_else(|hardware_error| {
                Self::with_driver(hwnd, width, height, D3D_DRIVER_TYPE_WARP, "warp")
                    .map_err(|warp_error| Error::new(warp_error.code(), format!(
                        "Taskbar graphics failed: hardware=0x{:08x}, WARP=0x{:08x}",
                        hardware_error.code().0 as u32, warp_error.code().0 as u32,
                    )))
            })
    }

    fn with_driver(hwnd: HWND, width: u32, height: u32, kind: D3D_DRIVER_TYPE, driver: &'static str) -> Result<Self> {
        unsafe {
            let mut d3d_device = None;
            D3D11CreateDevice(None::<&IDXGIAdapter>, kind, HMODULE::default(),
                D3D11_CREATE_DEVICE_BGRA_SUPPORT, None, D3D11_SDK_VERSION,
                Some(&mut d3d_device), None, None)?;
            let d3d_device = d3d_device.ok_or_else(|| Error::new(E_UNEXPECTED, "D3D11 returned no device"))?;
            let dxgi_device: IDXGIDevice = d3d_device.cast()?;
            let d2d_device = D2D1CreateDevice(&dxgi_device, None)?;
            let context = d2d_device.CreateDeviceContext(D2D1_DEVICE_CONTEXT_OPTIONS_NONE)?;
            context.SetDpi(96.0, 96.0); // layout() and mouse input share physical pixels.
            context.SetTextAntialiasMode(D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE);
            let svg_context: ID2D1DeviceContext5 = context.cast()?;
            let factory = context.GetFactory()?;
            let logos = create_logos(&svg_context)?;
            let brush = context.CreateSolidColorBrush(&rgb(0xffffff), None)?;
            let stroke = |cap| factory.CreateStrokeStyle(&D2D1_STROKE_STYLE_PROPERTIES {
                startCap:cap, endCap:cap, dashCap:cap, lineJoin:D2D1_LINE_JOIN_ROUND,
                miterLimit:10.0, dashStyle:D2D1_DASH_STYLE_SOLID, dashOffset:0.0,
            }, None);
            let (round, flat) = (stroke(D2D1_CAP_STYLE_ROUND)?, stroke(D2D1_CAP_STYLE_FLAT)?);
            let write_factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            // `.pct`'s font-variant-numeric: tabular-nums, so 31% and 47% are the same width.
            let tabular = write_factory.CreateTypography()?;
            tabular.AddFontFeature(DWRITE_FONT_FEATURE { nameTag:DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, parameter:1 })?;
            let composition: IDCompositionDevice = DCompositionCreateDevice(&dxgi_device)?;
            let target = composition.CreateTargetForHwnd(hwnd, true)?;
            let visual = composition.CreateVisual()?;
            let surface = composition.CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED)?;
            visual.SetContent(&surface)?;
            target.SetRoot(&visual)?;
            // Surface contents are initialized by the first draw before Commit.
            Ok(Self { context, svg_context, factory, logos, brush, round, flat, write_factory, tabular,
                formats:HashMap::new(), surface, target, visual, composition, _d2d_device:d2d_device,
                _dxgi_device:dxgi_device, _d3d_device:d3d_device, width, height, driver, _thread_bound:PhantomData })
        }
    }

    pub fn driver(&self) -> &'static str { self.driver }

    pub fn resize(&mut self, width: u32, height: u32) -> Result<()> {
        validate_size(width, height)?;
        if (width, height) == (self.width, self.height) { return Ok(()); }
        unsafe {
            let surface = self.composition.CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED)?;
            self.visual.SetContent(&surface)?;
            self.surface = surface;
            self.width = width;
            self.height = height;
        }
        // Do not expose uninitialized pixels. The next draw initializes and commits.
        Ok(())
    }

    /// `pressed` holds the cells being refreshed or clicked, drawn at the notch's pressed size.
    pub fn draw(&mut self, frame: &Frame, scale: f32, pressed: &[usize], seconds: f32) -> Result<()> {
        let seconds = if seconds.is_finite() { seconds } else { 0.0 };
        let slots = taskbar_model::layout(frame, self.width as f32, self.height as f32, scale);
        // Every cell shares one unit and one font size, so the formats are fetched once a frame.
        let fonts = match slots.first() {
            Some(slot) => Some((self.format(DWRITE_FONT_WEIGHT_SEMI_BOLD, slot.font)?,
                self.format(DWRITE_FONT_WEIGHT_BOLD, 20.0 * slot.unit)?,
                self.format(DWRITE_FONT_WEIGHT_BOLD, 15.0 * slot.unit)?)),
            None => None,
        };
        unsafe {
            let mut offset = POINT::default();
            let dxgi_surface: IDXGISurface = self.surface.BeginDraw(None, &mut offset)?;
            // End the DComp update even if wrapping its temporary texture fails.
            let draw_result = (|| -> Result<()> {
                let properties = D2D1_BITMAP_PROPERTIES1 {
                    pixelFormat: D2D1_PIXEL_FORMAT { format:DXGI_FORMAT_B8G8R8A8_UNORM, alphaMode:D2D1_ALPHA_MODE_PREMULTIPLIED },
                    dpiX:96.0, dpiY:96.0,
                    bitmapOptions:D2D1_BITMAP_OPTIONS_TARGET | D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                    ..Default::default()
                };
                let bitmap = self.context.CreateBitmapFromDxgiSurface(&dxgi_surface, Some(&properties))?;
                self.context.SetTarget(&bitmap);
                let origin = (offset.x as f32, offset.y as f32);
                self.context.SetTransform(&matrix(1.0, origin.0, origin.1));
                self.context.BeginDraw();
                // BeginDraw can return a texture atlas offset, even for a full update.
                self.context.PushAxisAlignedClip(&D2D_RECT_F { left:0.0, top:0.0,
                    right:self.width as f32, bottom:self.height as f32 }, D2D1_ANTIALIAS_MODE_ALIASED);
                self.context.Clear(Some(&rgba(0.0, 0.0, 0.0, 0.0)));
                if let Some((pct, big, small)) = &fonts {
                    let colours = palette(frame.dark);
                    for slot in &slots {
                        let Some(item) = frame.items.get(slot.index) else { continue };
                        let letter_format = if letter(&item.provider).chars().count() > 1 { small } else { big };
                        self.draw_cell(item, slot, frame, &colours, pressed.contains(&slot.index), seconds, origin, pct, letter_format)?;
                    }
                }
                self.context.PopAxisAlignedClip();
                self.context.EndDraw(None, None)
            })();
            self.context.SetTarget(None::<&ID2D1Image>);
            let surface_result = self.surface.EndDraw();
            draw_result.and(surface_result)?;
            self.composition.Commit()
        }
    }

    fn format(&mut self, weight: DWRITE_FONT_WEIGHT, size: f32) -> Result<IDWriteTextFormat> {
        let size = if size.is_finite() { size.clamp(1.0, 200.0) } else { 12.0 };
        let key = (weight.0, size.to_bits());
        if let Some(format) = self.formats.get(&key) { return Ok(format.clone()); }
        if self.formats.len() > 16 { self.formats.clear(); }
        let format = unsafe { text_format(&self.write_factory, weight, size)? };
        self.formats.insert(key, format.clone());
        Ok(format)
    }

    #[allow(clippy::too_many_arguments)]
    unsafe fn draw_cell(&self, item: &Indicator, slot: &Slot, frame: &Frame, colours: &Palette, pressed: bool,
        seconds: f32, origin: (f32, f32), pct: &IDWriteTextFormat, letter_format: &IDWriteTextFormat) -> Result<()> {
        self.context.PushAxisAlignedClip(&D2D_RECT_F { left:slot.x, top:0.0,
            right:slot.x + slot.width, bottom:self.height as f32 }, D2D1_ANTIALIAS_MODE_ALIASED);
        let (cx, cy, u) = (slot.center_x, slot.center_y, slot.unit);
        // `.ringwrap.pressed`: the ring, its reading, the activity and the glyph shrink together.
        let s = if pressed { PRESSED } else { 1.0 };
        self.context.SetTransform(&matrix(s, origin.0 + cx * (1.0 - s), origin.1 + cy * (1.0 - s)));
        let center = D2D_POINT_2F { x:cx, y:cy };
        let remaining = frame.appearance.shows_remaining;

        // svg.ring: the hole, the track and the week, faded as one when the reading is old.
        self.faded(item.stale, || {
            self.brush.SetColor(&colours.hole);
            self.brush.SetOpacity(1.0);
            self.context.FillEllipse(&circle(center, 22.0 * u), &self.brush);
            self.brush.SetColor(&colours.track);
            self.context.DrawEllipse(&circle(center, 25.0 * u), &self.brush, 5.0 * u, &self.round);
            if let Some(week) = item.weekly {
                let r = if frame.appearance.weekly_ring == "inside" { 16.0 } else { 31.0 } * u;
                let fraction = taskbar_model::meter_fraction(week, remaining).clamp(0.0, 1.0);
                let dashed = frame.appearance.weekly_dashed;
                self.brush.SetColor(&colours.track);
                self.brush.SetOpacity(0.7);
                if dashed { self.dashed(center, r, 1.0, 2.4 * u, u)?; }
                else { self.context.DrawEllipse(&circle(center, r), &self.brush, 2.4 * u, &self.flat); }
                self.brush.SetColor(&tone(week, frame));
                self.brush.SetOpacity(0.85);
                if dashed { self.dashed(center, r, fraction, 2.4 * u, u)?; }
                else { self.arc(center, r, 0.0, fraction, 2.4 * u, &self.round)?; }
            }
            Ok(())
        })?;
        // svg.reading, its own layer so it fades on its own over the track.
        if let Some(used) = item.headline {
            self.faded(item.stale, || {
                self.brush.SetColor(&tone(used, frame));
                self.brush.SetOpacity(1.0);
                self.arc(center, 25.0 * u, 0.0, taskbar_model::meter_fraction(used, remaining).clamp(0.0, 1.0), 5.0 * u, &self.round)
            })?;
        }
        // svg.activity keeps its strength on an old reading: whether an agent runs is current.
        match item.work_state.as_str() {
            "busy" => {
                // spin 1.2 s steps(12): a 28% arc turning in twelfths.
                let step = ((seconds / 1.2).rem_euclid(1.0) * 12.0).floor() / 12.0;
                self.brush.SetColor(&colours.ink);
                self.brush.SetOpacity(1.0);
                self.arc(center, 19.0 * u, step, 0.28, 2.5 * u, &self.round)?;
            }
            "waiting" => {
                self.brush.SetColor(&colours.watch);
                self.brush.SetOpacity(pulse(seconds));
                self.context.DrawEllipse(&circle(center, 19.0 * u), &self.brush, 2.5 * u, &self.flat);
            }
            _ => (),
        }
        // .glyph, dimmed when its window is used up or its reading is old.
        self.faded(item.spent || item.stale, || {
            if let Some(documents) = self.logos.get(item.provider.as_str()) {
                let size = 26.0 * u;
                self.context.SetTransform(&matrix(s * size / 24.0, origin.0 + cx - s * size / 2.0, origin.1 + cy - s * size / 2.0));
                self.svg_context.DrawSvgDocument(&documents[usize::from(!frame.dark)]);
                self.context.SetTransform(&matrix(s, origin.0 + cx * (1.0 - s), origin.1 + cy * (1.0 - s)));
            } else {
                self.brush.SetColor(&colours.glyph);
                self.brush.SetOpacity(1.0);
                let text: Vec<u16> = letter(&item.provider).encode_utf16().collect();
                let half = 28.0 * u;
                self.context.DrawText(&text, letter_format, &D2D_RECT_F { left:cx - half, top:cy - half, right:cx + half, bottom:cy + half },
                    &self.brush, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
            }
            Ok(())
        })?;
        self.context.SetTransform(&matrix(1.0, origin.0, origin.1));
        // .pct, beside the ring rather than under it: a taskbar is not tall enough for both.
        if !item.text.is_empty() {
            let text: Vec<u16> = item.text.encode_utf16().collect();
            let right = slot.x + slot.width;
            let layout = self.write_factory.CreateTextLayout(&text, pct, (right - slot.text_x).max(1.0), self.height as f32)?;
            layout.SetTypography(&self.tabular, DWRITE_TEXT_RANGE { startPosition:0, length:text.len() as u32 })?;
            self.brush.SetColor(&colours.ink);
            self.brush.SetOpacity(1.0);
            self.context.DrawTextLayout(D2D_POINT_2F { x:slot.text_x, y:0.0 }, &layout, &self.brush, D2D1_DRAW_TEXT_OPTIONS_CLIP);
        }
        self.context.PopAxisAlignedClip();
        Ok(())
    }

    /// Draws `paint` at the notch's .55 when `faded`, as one layer, as CSS opacity does.
    unsafe fn faded(&self, faded: bool, paint: impl FnOnce() -> Result<()>) -> Result<()> {
        if !faded { return paint(); }
        let infinite = D2D_RECT_F { left:-f32::MAX, top:-f32::MAX, right:f32::MAX, bottom:f32::MAX };
        let parameters = D2D1_LAYER_PARAMETERS1 { contentBounds:infinite, maskAntialiasMode:D2D1_ANTIALIAS_MODE_PER_PRIMITIVE,
            maskTransform:matrix(1.0, 0.0, 0.0), opacity:FADED, ..Default::default() };
        self.context.PushLayer(&parameters, None::<&ID2D1Layer>);
        let result = paint();
        self.context.PopLayer();
        result
    }

    /// The notch's `svgArc`: clockwise from twelve o'clock, `start` and `fraction` in turns, and
    /// nothing at all at zero.
    unsafe fn arc(&self, center: D2D_POINT_2F, radius: f32, start: f32, fraction: f32, width: f32, style: &ID2D1StrokeStyle) -> Result<()> {
        if fraction.is_nan() || fraction <= 0.0 || radius.is_nan() || radius <= 0.0 { return Ok(()); }
        if fraction >= 1.0 { self.context.DrawEllipse(&circle(center, radius), &self.brush, width, style); return Ok(()); }
        let at = |turns: f32| {
            let angle = (turns - 0.25) * TAU;
            D2D_POINT_2F { x:center.x + radius * angle.cos(), y:center.y + radius * angle.sin() }
        };
        let path = self.factory.CreatePathGeometry()?;
        let sink = path.Open()?;
        sink.BeginFigure(at(start), D2D1_FIGURE_BEGIN_HOLLOW);
        // In two halves, so neither is over half a turn and its end never meets its start.
        for end in [start + fraction / 2.0, start + fraction] {
            sink.AddArc(&D2D1_ARC_SEGMENT { point:at(end), size:D2D_SIZE_F { width:radius, height:radius },
                rotationAngle:0.0, sweepDirection:D2D1_SWEEP_DIRECTION_CLOCKWISE, arcSize:D2D1_ARC_SIZE_SMALL });
        }
        sink.EndFigure(D2D1_FIGURE_END_OPEN);
        sink.Close()?;
        self.context.DrawGeometry(&path, &self.brush, width, style);
        Ok(())
    }

    /// The notch's `dashedArc`: 4 units on, 2 off, butt caps, cut at the reading.
    unsafe fn dashed(&self, center: D2D_POINT_2F, radius: f32, fraction: f32, width: f32, unit: f32) -> Result<()> {
        for (start, sweep) in dashed_sweep(radius, fraction, unit) {
            self.arc(center, radius, start / TAU, sweep, width, &self.flat)?;
        }
        Ok(())
    }
}

impl Drop for Renderer {
    fn drop(&mut self) {
        unsafe {
            self.context.SetTarget(None::<&ID2D1Image>);
            let _ = self.target.SetRoot(None::<&IDCompositionVisual>);
            let _ = self.composition.Commit(); // Never block WM_NCDESTROY on a compositor wait.
        }
    }
}

/// pulse 1.1 s steps(6): 1 → .25 → 1, six steps each way, as CSS steps each keyframe interval.
fn pulse(seconds: f32) -> f32 {
    let phase = (seconds / 1.1).rem_euclid(1.0);
    let half = (phase * 2.0).fract();
    let step = (half * 6.0).floor() / 6.0;
    if phase < 0.5 { 1.0 - 0.75 * step } else { 0.25 + 0.75 * step }
}

fn tone(used: f32, frame: &Frame) -> D2D1_COLOR_F {
    let [r, g, b] = taskbar_model::usage_color(used, frame);
    rgba(r as f32 / 255.0, g as f32 / 255.0, b as f32 / 255.0, 1.0)
}

unsafe fn text_format(factory: &IDWriteFactory, weight: DWRITE_FONT_WEIGHT, size: f32) -> Result<IDWriteTextFormat> {
    let format = factory.CreateTextFormat(w!("Segoe UI"), None::<&IDWriteFontCollection>,
        weight, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL, size, w!("en-US"))?;
    // The figure starts at the slot's text edge; a letter glyph is centred in the ring.
    format.SetTextAlignment(if weight == DWRITE_FONT_WEIGHT_BOLD { DWRITE_TEXT_ALIGNMENT_CENTER } else { DWRITE_TEXT_ALIGNMENT_LEADING })?;
    format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
    format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
    Ok(format)
}

unsafe fn create_logos(context: &ID2D1DeviceContext5) -> Result<HashMap<&'static str, [ID2D1SvgDocument; 2]>> {
    let mut logos = HashMap::new();
    for (provider, svg) in crate::glyphs::BUILTIN {
        let read = |dark| -> Result<ID2D1SvgDocument> {
            let xml = native_svg(svg, palette(dark).glyph);
            let stream = SHCreateMemStream(Some(xml.as_bytes()))
                .ok_or_else(|| Error::new(E_OUTOFMEMORY, "Unable to create native logo stream"))?;
            context.CreateSvgDocument(&stream, D2D_SIZE_F { width:24.0, height:24.0 })
        };
        match (read(true), read(false)) {
            (Ok(dark), Ok(light)) => { logos.insert(provider, [dark, light]); }
            (Err(error), _) | (_, Err(error)) if provider == "claude" || provider == "codex" => return Err(error),
            _ => (), // Other providers keep the notch's letter if Direct2D cannot read their SVG.
        }
    }
    Ok(logos)
}

fn native_svg(svg: &str, colour: D2D1_COLOR_F) -> String {
    // Only adapt presentation for Direct2D. Preserve all licensed path geometry.
    let mut xml = svg.to_owned();
    if let Some(start) = xml.find("<metadata>") {
        if let Some(end) = xml[start..].find("</metadata>") { xml.replace_range(start..start + end + "</metadata>".len(), ""); }
    }
    let hex = format!("#{:02x}{:02x}{:02x}", (colour.r * 255.0).round() as u8, (colour.g * 255.0).round() as u8, (colour.b * 255.0).round() as u8);
    xml.replace("1em", "24").replace("currentColor", &hex)
}

fn validate_size(width: u32, height: u32) -> Result<()> {
    if width == 0 || height == 0 || width > 16384 || height > 4096 {
        Err(Error::new(E_INVALIDARG, "Invalid taskbar surface size"))
    } else { Ok(()) }
}

// Four design units on, two off, clipped at the actual quota. Flat caps
// preserve gaps and keep 0% completely empty, matching the original notch.
fn dashed_sweep(radius:f32,fraction:f32,unit:f32) -> Vec<(f32,f32)> {
    if !radius.is_finite() || !fraction.is_finite() || !unit.is_finite()
        || radius <= 0.0 || fraction <= 0.0 || unit <= 0.0 { return Vec::new(); }
    let circumference = TAU * radius;
    let length = circumference * fraction.min(1.0);
    let mut arcs = Vec::new();
    let mut position = 0.0;
    while position < length {
        let dash = (4.0*unit).min(length-position);
        arcs.push((position/radius,dash/circumference));
        position += 6.0*unit;
    }
    arcs
}

fn circle(point: D2D_POINT_2F, radius: f32) -> D2D1_ELLIPSE { D2D1_ELLIPSE { point, radiusX:radius, radiusY:radius } }
fn matrix(scale: f32, x: f32, y: f32) -> Matrix3x2 {
    Matrix3x2 { M11:scale, M12:0.0, M21:0.0, M22:scale, M31:x, M32:y }
}
fn rgba(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F { D2D1_COLOR_F { r, g, b, a } }
fn rgb(value: u32) -> D2D1_COLOR_F { rgba(((value >> 16) & 255) as f32 / 255.0, ((value >> 8) & 255) as f32 / 255.0, (value & 255) as f32 / 255.0, 1.0) }

#[cfg(test)]
mod tests {
    use super::*;
    use crate::taskbar_model::Appearance;
    use windows::{core::PCWSTR, Win32::{
        Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM},
        Graphics::DirectWrite::DWRITE_TEXT_METRICS,
        System::{Com::{CoInitializeEx, CoUninitialize, COINIT_APARTMENTTHREADED}, LibraryLoader::GetModuleHandleW},
        UI::WindowsAndMessaging::{CreateWindowExW, DefWindowProcW, DestroyWindow,
            RegisterClassW, UnregisterClassW, WNDCLASSW, WINDOW_EX_STYLE, WS_CHILD,
            WS_CLIPSIBLINGS, WS_EX_NOACTIVATE, WS_EX_NOREDIRECTIONBITMAP, WS_POPUP},
    }};

    struct ComApartment;
    impl Drop for ComApartment { fn drop(&mut self) { unsafe { CoUninitialize() }; } }
    struct Window(HWND);
    impl Drop for Window { fn drop(&mut self) { unsafe { let _ = DestroyWindow(self.0); } } }
    struct WindowClass { name: Vec<u16>, instance: HINSTANCE }
    impl Drop for WindowClass {
        fn drop(&mut self) { unsafe { let _ = UnregisterClassW(PCWSTR(self.name.as_ptr()), self.instance); } }
    }
    unsafe extern "system" fn test_window(hwnd: HWND, message: u32, wparam: WPARAM, lparam: LPARAM) -> LRESULT {
        DefWindowProcW(hwnd, message, wparam, lparam)
    }

    #[test]
    fn dashed_weekly_sweep_preserves_gaps_and_never_exceeds_the_quota() {
        assert!(dashed_sweep(17.0,0.0,0.68).is_empty());
        for fraction in [0.01,0.23,1.0] {
            let arcs = dashed_sweep(17.0,fraction,0.68);
            assert!(!arcs.is_empty());
            let mut last_end = 0.0;
            for (index,(start,sweep)) in arcs.into_iter().enumerate() {
                assert!(sweep > 0.0);
                if index > 0 { assert!(start > last_end,"weekly ticks must have a visible gap"); }
                last_end = start+sweep*TAU;
                assert!(last_end <= fraction*TAU+0.00001);
            }
        }
    }

    #[test]
    fn the_waiting_pulse_steps_down_to_a_quarter_and_back() {
        let values: Vec<f32> = (0..12).map(|step| pulse(step as f32 * 1.1 / 12.0 + 0.001)).collect();
        assert_eq!(values[0], 1.0);
        assert!((values[6] - 0.25).abs() < 0.001);
        assert!(values[..6].windows(2).all(|pair| pair[1] < pair[0]));
        assert!(values[6..].windows(2).all(|pair| pair[1] > pair[0]));
        assert!(values.iter().all(|v| (0.25..=1.0).contains(v)));
    }

    #[test]
    fn every_provider_has_the_notchs_letter() {
        for provider in crate::TRAY_PROVIDER_IDS { assert_ne!(letter(provider), "?", "{provider}"); }
    }

    fn indicator(provider: &str, headline: Option<f32>, weekly: Option<f32>, work_state: &str, stale: bool, spent: bool) -> Indicator {
        Indicator { id:format!("{provider}-{work_state}"), provider:provider.into(), headline, weekly,
            text:"71%".into(), work_state:work_state.into(), stale, spent }
    }

    // Exercise the actual Windows graphics APIs, rather than just parsing XML.
    // The hidden windows belong to this test thread; Explorer is never accessed.
    #[test]
    fn real_svg_surface_draws_every_cell_state_theme_and_dpi_resize() {
        std::thread::spawn(|| unsafe {
            CoInitializeEx(None, COINIT_APARTMENTTHREADED).ok().unwrap();
            let _apartment = ComApartment;
            let instance = HINSTANCE(GetModuleHandleW(None).unwrap().0);
            let class = WindowClass {
                name: format!("CodenotchRenderTest-{}-{:?}", std::process::id(), std::thread::current().id())
                    .encode_utf16().chain(std::iter::once(0)).collect(),
                instance,
            };
            assert_ne!(RegisterClassW(&WNDCLASSW { lpfnWndProc:Some(test_window), hInstance:instance,
                lpszClassName:PCWSTR(class.name.as_ptr()), ..Default::default() }), 0);
            let parent = Window(CreateWindowExW(WINDOW_EX_STYLE(0), w!("STATIC"), w!(""),
                WS_POPUP, 0, 0, 560, 84, None, None, instance, None).unwrap());
            let child = Window(CreateWindowExW(WS_EX_NOACTIVATE | WS_EX_NOREDIRECTIONBITMAP,
                PCWSTR(class.name.as_ptr()), w!(""), WS_CHILD | WS_CLIPSIBLINGS,
                0, 0, 280, 42, parent.0, None, instance, None).unwrap());
            let mut renderer = Renderer::new(child.0, 280, 42).unwrap();
            assert!(matches!(renderer.driver(), "hardware" | "warp"));
            // Optional-provider fallbacks must not hide a regression in bundled art.
            for (provider, _) in crate::glyphs::BUILTIN { assert!(renderer.logos.contains_key(provider), "SVG failed: {provider}"); }
            let mut frame = Frame { items:vec![
                indicator("claude", Some(0.21), Some(0.09), "busy", false, false),
                indicator("codex", None, Some(0.09), "waiting", true, false),
                indicator("glm", Some(1.0), None, "idle", true, true),
            ], dark:true, watch:0.5, critical:0.7, appearance:Appearance::from_config(&crate::config::Config::default()) };
            renderer.draw(&frame, 1.0, &[0], 0.75).unwrap();
            frame.dark = false;
            renderer.draw(&frame, 1.0, &[], 1.5).unwrap();
            for size in [0.8,1.0,1.25] {
                frame.appearance.size = size;
                for placement in ["off", "inside", "outside"] {
                    frame.appearance.weekly_ring = placement.into();
                    for dashed in [false,true] {
                        frame.appearance.weekly_dashed = dashed;
                        renderer.draw(&frame,1.0,&[1],1.6).unwrap();
                    }
                }
            }
            frame.appearance.size = 1.0;
            // Every built-in document is also submitted through DrawSvgDocument.
            frame.items = crate::glyphs::BUILTIN.iter().enumerate().map(|(index, (provider, _))|
                indicator(provider, Some(index as f32 / 9.0), None, "idle", index % 2 != 0, index % 3 == 0)).collect();
            renderer.resize(1120, 84).unwrap();
            renderer.draw(&frame, 2.0, &[4, 5], 2.0).unwrap();
            frame.dark = true;
            renderer.draw(&frame, 2.0, &[], 2.5).unwrap();
            // Rejecting an invalid resize must leave the previous surface usable.
            assert!(renderer.resize(0, 84).is_err());
            renderer.draw(&frame, 2.0, &[], 3.0).unwrap();
            renderer.resize(98, 42).unwrap();
            renderer.draw(&frame, 1.0, &[], 3.5).unwrap();
            frame.items.clear();
            renderer.draw(&frame, 1.0, &[], 4.0).unwrap();
            // Drop order: renderer, child, parent, registered class, COM apartment.
        }).join().unwrap();
    }

    /// The model sizes the strip from its own advance table; DirectWrite must agree, or a figure
    /// would be clipped or the strip would carry space for no reason.
    #[test]
    fn the_models_figure_widths_match_segoe_ui_with_tabular_figures() {
        unsafe {
            let factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED).unwrap();
            let tabular = factory.CreateTypography().unwrap();
            tabular.AddFontFeature(DWRITE_FONT_FEATURE { nameTag:DWRITE_FONT_FEATURE_TAG_TABULAR_FIGURES, parameter:1 }).unwrap();
            let format = text_format(&factory, DWRITE_FONT_WEIGHT_SEMI_BOLD, 100.0).unwrap();
            for text in ["0%", "8%", "31%", "47%", "100%", "~1", "<0.1%", ">99.9%", "…", "—"] {
                let wide: Vec<u16> = text.encode_utf16().collect();
                let layout = factory.CreateTextLayout(&wide, &format, 10000.0, 200.0).unwrap();
                layout.SetTypography(&tabular, DWRITE_TEXT_RANGE { startPosition:0, length:wide.len() as u32 }).unwrap();
                let mut metrics = DWRITE_TEXT_METRICS::default();
                layout.GetMetrics(&mut metrics).unwrap();
                let model = taskbar_model::text_width(text, 100.0);
                assert!(metrics.widthIncludingTrailingWhitespace <= model + 0.5,
                    "{text}: DirectWrite {} > model {model}", metrics.widthIncludingTrailingWhitespace);
                assert!(model - metrics.widthIncludingTrailingWhitespace < 8.0,
                    "{text}: model {model} leaves too much room over {}", metrics.widthIncludingTrailingWhitespace);
            }
        }
    }
}
