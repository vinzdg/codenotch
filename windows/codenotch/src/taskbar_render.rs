//! Native taskbar graphics. The caller owns the HWND, input, and account data.
//! Transparent pixels remain part of the native window's client hit area.
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
                Common::{D2D1_ALPHA_MODE_PREMULTIPLIED, D2D1_COLOR_F, D2D1_PIXEL_FORMAT, D2D_POINT_2F, D2D_RECT_F, D2D_SIZE_F},
                D2D1CreateDevice, ID2D1Device, ID2D1DeviceContext, ID2D1DeviceContext5,
                ID2D1Image, ID2D1SolidColorBrush, ID2D1StrokeStyle, ID2D1SvgDocument,
                D2D1_ANTIALIAS_MODE_ALIASED, D2D1_BITMAP_OPTIONS_CANNOT_DRAW,
                D2D1_BITMAP_OPTIONS_TARGET, D2D1_BITMAP_PROPERTIES1, D2D1_CAP_STYLE_ROUND, D2D1_CAP_STYLE_FLAT,
                D2D1_DASH_STYLE_SOLID, D2D1_DEVICE_CONTEXT_OPTIONS_NONE,
                D2D1_DRAW_TEXT_OPTIONS_CLIP, D2D1_ELLIPSE, D2D1_LINE_JOIN_ROUND,
                D2D1_STROKE_STYLE_PROPERTIES, D2D1_TEXT_ANTIALIAS_MODE_GRAYSCALE,
            },
            Direct3D::{D3D_DRIVER_TYPE, D3D_DRIVER_TYPE_HARDWARE, D3D_DRIVER_TYPE_WARP},
            Direct3D11::{D3D11CreateDevice, ID3D11Device, D3D11_CREATE_DEVICE_BGRA_SUPPORT, D3D11_SDK_VERSION},
            DirectComposition::{DCompositionCreateDevice, IDCompositionDevice, IDCompositionSurface, IDCompositionTarget, IDCompositionVisual},
            DirectWrite::{
                DWriteCreateFactory, IDWriteFactory, IDWriteFontCollection, IDWriteTextFormat,
                DWRITE_FACTORY_TYPE_SHARED, DWRITE_FONT_STRETCH_NORMAL,
                DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_WEIGHT_SEMI_BOLD,
                DWRITE_MEASURING_MODE_NATURAL, DWRITE_PARAGRAPH_ALIGNMENT_CENTER,
                DWRITE_TEXT_ALIGNMENT_LEADING, DWRITE_WORD_WRAPPING_NO_WRAP,
            },
            Dxgi::{Common::{DXGI_ALPHA_MODE_PREMULTIPLIED, DXGI_FORMAT_B8G8R8A8_UNORM}, IDXGIAdapter, IDXGIDevice, IDXGISurface},
        },
        UI::Shell::SHCreateMemStream,
    },
};

// Existing licensed artwork, shared with the web UI; no paths are redrawn here.
const LOGOS: [(&str, &str); 7] = [
    ("claude", include_str!("../glyphs/claude.svg")),
    ("codex", include_str!("../glyphs/codex.svg")),
    ("cursor", include_str!("../glyphs/cursor.svg")),
    ("grok", include_str!("../glyphs/grok.svg")),
    ("copilot", include_str!("../glyphs/copilot.svg")),
    ("gemini", include_str!("../glyphs/gemini.svg")),
    ("opencode", include_str!("../glyphs/opencode.svg")),
];

pub struct Renderer {
    context: ID2D1DeviceContext,
    svg_context: ID2D1DeviceContext5,
    logos: HashMap<&'static str, [ID2D1SvgDocument; 4]>,
    track: ID2D1SolidColorBrush,
    progress: ID2D1SolidColorBrush,
    foreground: ID2D1SolidColorBrush,
    activity: ID2D1SolidColorBrush,
    stroke: ID2D1StrokeStyle,
    weekly_stroke: ID2D1StrokeStyle,
    format: IDWriteTextFormat,
    font_scale: f32,
    surface: IDCompositionSurface,
    target: IDCompositionTarget,
    visual: IDCompositionVisual,
    composition: IDCompositionDevice,
    write_factory: IDWriteFactory,
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
            let logos = create_logos(&svg_context)?;
            let track = context.CreateSolidColorBrush(&rgba(1.0, 1.0, 1.0, 0.13), None)?;
            let progress = context.CreateSolidColorBrush(&rgba(0.45, 0.83, 0.61, 1.0), None)?;
            let foreground = context.CreateSolidColorBrush(&rgba(0.95, 0.96, 0.98, 1.0), None)?;
            let activity = context.CreateSolidColorBrush(&rgba(0.95, 0.96, 0.98, 1.0), None)?;
            let stroke = context.GetFactory()?.CreateStrokeStyle(&D2D1_STROKE_STYLE_PROPERTIES {
                startCap: D2D1_CAP_STYLE_ROUND, endCap: D2D1_CAP_STYLE_ROUND,
                dashCap: D2D1_CAP_STYLE_ROUND, lineJoin: D2D1_LINE_JOIN_ROUND,
                miterLimit: 10.0, dashStyle: D2D1_DASH_STYLE_SOLID, dashOffset: 0.0,
            }, None)?;
            let weekly_stroke = context.GetFactory()?.CreateStrokeStyle(&D2D1_STROKE_STYLE_PROPERTIES {
                startCap:D2D1_CAP_STYLE_FLAT, endCap:D2D1_CAP_STYLE_FLAT,
                dashCap:D2D1_CAP_STYLE_FLAT, lineJoin:D2D1_LINE_JOIN_ROUND,
                miterLimit:10.0, dashStyle:D2D1_DASH_STYLE_SOLID, dashOffset:0.0,
            },None)?;
            let write_factory: IDWriteFactory = DWriteCreateFactory(DWRITE_FACTORY_TYPE_SHARED)?;
            let format = text_format(&write_factory, 1.0)?;
            let composition: IDCompositionDevice = DCompositionCreateDevice(&dxgi_device)?;
            let target = composition.CreateTargetForHwnd(hwnd, true)?;
            let visual = composition.CreateVisual()?;
            let surface = composition.CreateSurface(width, height, DXGI_FORMAT_B8G8R8A8_UNORM, DXGI_ALPHA_MODE_PREMULTIPLIED)?;
            visual.SetContent(&surface)?;
            target.SetRoot(&visual)?;
            // Surface contents are initialized by the first draw before Commit.
            Ok(Self { context, svg_context, logos, track, progress, foreground, activity,
                stroke, weekly_stroke, format, font_scale:1.0, surface, target, visual, composition,
                write_factory, _d2d_device:d2d_device, _dxgi_device:dxgi_device,
                _d3d_device:d3d_device, width, height, driver, _thread_bound:PhantomData })
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

    pub fn draw(&mut self, frame: &Frame, scale: f32, hovered: Option<usize>, pressed: Option<usize>, seconds: f32) -> Result<()> {
        let scale = if scale.is_finite() && scale > 0.0 { scale.clamp(0.5, 8.0) } else { 1.0 };
        let visual_scale = scale * frame.appearance.size;
        if (self.font_scale - visual_scale).abs() > 0.001 {
            self.format = unsafe { text_format(&self.write_factory, visual_scale)? };
            self.font_scale = visual_scale;
        }
        let seconds = if seconds.is_finite() { seconds } else { 0.0 };
        let slots = taskbar_model::layout(frame.items.len(), self.width as f32, self.height as f32, scale, frame.appearance.size);
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
                let transform = matrix(1.0, offset.x as f32, offset.y as f32);
                self.context.SetTransform(&transform);
                self.context.BeginDraw();
                // BeginDraw can return a texture atlas offset, even for a full update.
                self.context.PushAxisAlignedClip(&D2D_RECT_F { left:0.0, top:0.0,
                    right:self.width as f32, bottom:self.height as f32 }, D2D1_ANTIALIAS_MODE_ALIASED);
                self.context.Clear(Some(&rgba(0.0, 0.0, 0.0, 0.0)));
                for slot in &slots {
                    if let Some(item) = frame.items.get(slot.index) {
                        self.draw_indicator(item, slot, frame, visual_scale, hovered == Some(slot.index),
                            pressed == Some(slot.index), seconds, offset);
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

    unsafe fn draw_indicator(&self, item: &Indicator, slot: &Slot, frame: &Frame, scale: f32,
        hovered: bool, pressed: bool, seconds: f32, offset: POINT) {
        self.context.PushAxisAlignedClip(&D2D_RECT_F { left:slot.x, top:0.0,
            right:slot.x + slot.width, bottom:self.height as f32 }, D2D1_ANTIALIAS_MODE_ALIASED);
        let dim = if item.dimmed { 0.5 } else { 1.0 };
        let foreground = if frame.dark { rgb(0xf1f2f4) } else { rgb(0x202124) };
        self.foreground.SetColor(&foreground);
        self.foreground.SetOpacity(dim);
        self.track.SetColor(&if frame.dark { rgba(1.0, 1.0, 1.0, if hovered { 0.22 } else { 0.13 }) }
            else { rgba(0.0, 0.0, 0.0, if hovered { 0.22 } else { 0.11 }) });
        self.track.SetOpacity(dim);
        self.progress.SetOpacity(dim);
        let center = D2D_POINT_2F { x:slot.center_x, y:slot.center_y };
        let stroke = (2.0 * scale + if pressed { 0.5 * scale } else { 0.0 }).min(slot.radius / 4.0);
        for (fraction,radius,thickness,weekly) in [(item.outer,slot.radius,stroke,item.outer_weekly),
            (item.inner,slot.radius * 0.82,stroke * 0.88,item.inner_weekly)] {
            if let Some(fraction) = fraction.filter(|v| v.is_finite()).map(|v| v.clamp(0.0, 1.0)) {
                let [r,g,b] = taskbar_model::usage_color(fraction,frame);
                self.progress.SetColor(&rgba(r as f32/255.0,g as f32/255.0,b as f32/255.0,1.0));
                let fraction = taskbar_model::meter_fraction(fraction,frame.appearance.shows_remaining);
                if weekly && frame.appearance.weekly_dashed {
                    let unit = slot.radius / 25.0;
                    self.draw_dashed_arc(center,radius,1.0,&self.track,thickness,unit);
                    self.draw_dashed_arc(center,radius,fraction,&self.progress,thickness,unit);
                } else {
                    self.context.DrawEllipse(&D2D1_ELLIPSE { point:center, radiusX:radius, radiusY:radius },
                        &self.track, thickness, None::<&ID2D1StrokeStyle>);
                    self.draw_arc(center, radius, -std::f32::consts::FRAC_PI_2, fraction, &self.progress, thickness);
                }
            }
        }
        let logo_index = (if frame.dark { 0 } else { 2 }) + usize::from(item.dimmed);
        if let Some(documents) = self.logos.get(item.provider.as_str()) {
            self.context.SetTransform(&matrix(slot.logo_size / 24.0,
                offset.x as f32 + slot.center_x - slot.logo_size / 2.0,
                offset.y as f32 + slot.center_y - slot.logo_size / 2.0));
            self.svg_context.DrawSvgDocument(&documents[logo_index]);
            self.context.SetTransform(&matrix(1.0, offset.x as f32, offset.y as f32));
        } else {
            let label: Vec<u16> = item.provider.chars().next().unwrap_or('?').to_uppercase().collect::<String>().encode_utf16().collect();
            self.context.DrawText(&label, &self.format, &D2D_RECT_F {
                left:slot.center_x - 4.0 * scale, top:slot.center_y - slot.logo_size / 2.0,
                right:slot.center_x + slot.logo_size / 2.0, bottom:slot.center_y + slot.logo_size / 2.0,
            }, &self.foreground, D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
        }
        // Activity stays distinct from quota dimming. It never changes the limits.
        let activity_radius = slot.radius * 0.608;
        match item.work_state.as_str() {
            "busy" => {
                self.activity.SetColor(&foreground);
                self.activity.SetOpacity(0.95);
                let step = ((seconds / 1.25).rem_euclid(1.0) * 16.0).floor() / 16.0;
                self.draw_arc(center, activity_radius, -std::f32::consts::FRAC_PI_2 + step * std::f32::consts::TAU,
                    0.20, &self.activity, 1.2 * scale);
            }
            "waiting" => {
                self.activity.SetColor(&if frame.dark { rgb(0xf2ff00) } else { rgb(0xb08800) });
                self.activity.SetOpacity(0.65 + 0.35 * (seconds * std::f32::consts::TAU / 1.7).cos());
                for dash in 0..12 {
                    self.draw_arc(center, activity_radius, dash as f32 * std::f32::consts::TAU / 12.0,
                        0.025, &self.activity, 1.2 * scale);
                }
            }
            _ => (),
        }
        let right = slot.x + slot.width - 3.0 * scale;
        // Avoid displaying part of a percentage when Windows only leaves a narrow gap.
        let needed = item.text.chars().count() as f32 * 12.0 * scale * 0.65;
        if right - slot.text_x >= needed && !item.text.is_empty() {
            let text: Vec<u16> = item.text.encode_utf16().collect();
            self.context.DrawText(&text, &self.format, &D2D_RECT_F { left:slot.text_x, top:0.0,
                right, bottom:self.height as f32 }, &self.foreground,
                D2D1_DRAW_TEXT_OPTIONS_CLIP, DWRITE_MEASURING_MODE_NATURAL);
        }
        self.context.PopAxisAlignedClip();
    }

    unsafe fn draw_arc(&self, center: D2D_POINT_2F, radius: f32, start: f32, fraction: f32,
        brush: &ID2D1SolidColorBrush, thickness: f32) {
        self.draw_arc_with_stroke(center,radius,start,fraction,brush,thickness,&self.stroke);
    }

    unsafe fn draw_dashed_arc(&self, center:D2D_POINT_2F,radius:f32,fraction:f32,
        brush:&ID2D1SolidColorBrush,thickness:f32,unit:f32) {
        for (start,sweep) in dashed_sweep(radius,fraction,unit) {
            self.draw_arc_with_stroke(center,radius,-std::f32::consts::FRAC_PI_2 + start,
                sweep,brush,thickness,&self.weekly_stroke);
        }
    }

    unsafe fn draw_arc_with_stroke(&self, center:D2D_POINT_2F,radius:f32,start:f32,fraction:f32,
        brush:&ID2D1SolidColorBrush,thickness:f32,style:&ID2D1StrokeStyle) {
        if radius <= 0.0 || fraction <= 0.0 { return; }
        let segments = (fraction * 128.0).ceil().max(1.0) as usize;
        let point = |step: usize| {
            let angle = start + fraction * std::f32::consts::TAU * step as f32 / segments as f32;
            D2D_POINT_2F { x:center.x + radius * angle.cos(), y:center.y + radius * angle.sin() }
        };
        for step in 0..segments {
            self.context.DrawLine(point(step), point(step + 1), brush, thickness, style);
        }
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

unsafe fn text_format(factory: &IDWriteFactory, scale: f32) -> Result<IDWriteTextFormat> {
    let format = factory.CreateTextFormat(w!("Segoe UI"), None::<&IDWriteFontCollection>,
        DWRITE_FONT_WEIGHT_SEMI_BOLD, DWRITE_FONT_STYLE_NORMAL, DWRITE_FONT_STRETCH_NORMAL,
        12.0 * scale, w!("en-US"))?;
    format.SetTextAlignment(DWRITE_TEXT_ALIGNMENT_LEADING)?;
    format.SetParagraphAlignment(DWRITE_PARAGRAPH_ALIGNMENT_CENTER)?;
    format.SetWordWrapping(DWRITE_WORD_WRAPPING_NO_WRAP)?;
    Ok(format)
}

unsafe fn create_logos(context: &ID2D1DeviceContext5) -> Result<HashMap<&'static str, [ID2D1SvgDocument; 4]>> {
    let mut logos = HashMap::new();
    for (provider, svg) in LOGOS {
        let create = || -> Result<[ID2D1SvgDocument; 4]> {
            let read = |dark, dimmed| -> Result<ID2D1SvgDocument> {
                let xml = native_svg(svg, dark, dimmed);
                let stream = SHCreateMemStream(Some(xml.as_bytes()))
                    .ok_or_else(|| Error::new(E_OUTOFMEMORY, "Unable to create native logo stream"))?;
                context.CreateSvgDocument(&stream, D2D_SIZE_F { width:24.0, height:24.0 })
            };
            Ok([read(true, false)?, read(true, true)?, read(false, false)?, read(false, true)?])
        };
        match create() {
            Ok(documents) => { logos.insert(provider, documents); }
            Err(error) if provider == "claude" || provider == "codex" => return Err(error),
            Err(_) => (), // Other providers retain a readable letter if their SVG uses unsupported features.
        }
    }
    Ok(logos)
}

fn native_svg(svg: &str, dark: bool, dimmed: bool) -> String {
    // Only adapt presentation for Direct2D. Preserve all licensed path geometry.
    let mut xml = svg.to_owned();
    if let Some(start) = xml.find("<metadata>") {
        if let Some(end) = xml[start..].find("</metadata>") { xml.replace_range(start..start + end + "</metadata>".len(), ""); }
    }
    xml.replace("1em", "24")
        .replace("currentColor", if dark { "#f1f2f4" } else { "#202124" })
        .replacen("<svg ", if dimmed { "<svg opacity=\"0.45\" " } else { "<svg opacity=\"0.9\" " }, 1)
}

fn validate_size(width: u32, height: u32) -> Result<()> {
    if width == 0 || height == 0 || width > 16384 || height > 4096 {
        Err(Error::new(E_INVALIDARG, "Invalid taskbar surface size"))
    } else { Ok(()) }
}

// Four design pixels on, two off, clipped at the actual quota. Flat caps
// preserve gaps and keep 0% completely empty, matching the original notch.
fn dashed_sweep(radius:f32,fraction:f32,unit:f32) -> Vec<(f32,f32)> {
    if !radius.is_finite() || !fraction.is_finite() || !unit.is_finite()
        || radius <= 0.0 || fraction <= 0.0 || unit <= 0.0 { return Vec::new(); }
    let circumference = std::f32::consts::TAU * radius;
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

fn matrix(scale: f32, x: f32, y: f32) -> Matrix3x2 {
    Matrix3x2 { M11:scale, M12:0.0, M21:0.0, M22:scale, M31:x, M32:y }
}
fn rgba(r: f32, g: f32, b: f32, a: f32) -> D2D1_COLOR_F { D2D1_COLOR_F { r, g, b, a } }
fn rgb(value: u32) -> D2D1_COLOR_F { rgba(((value >> 16) & 255) as f32 / 255.0, ((value >> 8) & 255) as f32 / 255.0, (value & 255) as f32 / 255.0, 1.0) }

#[cfg(test)]
mod tests {
    use super::*;
    use windows::{core::PCWSTR, Win32::{
        Foundation::{HINSTANCE, LPARAM, LRESULT, WPARAM},
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
                last_end = start+sweep*std::f32::consts::TAU;
                assert!(last_end <= fraction*std::f32::consts::TAU+0.00001);
            }
        }
    }

    // Exercise the actual Windows graphics APIs, rather than just parsing XML.
    // The hidden windows belong to this test thread; Explorer is never accessed.
    #[test]
    fn real_svg_surface_draws_independent_limits_themes_and_dpi_resize() {
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
            for (provider, _) in LOGOS { assert!(renderer.logos.contains_key(provider), "SVG failed: {provider}"); }
            let mut frame = Frame { items:vec![
                Indicator { id:"left".into(), provider:"claude".into(), inner:Some(0.21), outer:Some(0.09),
                    text:"9%".into(), work_state:"busy".into(), dimmed:false, inner_weekly:false, outer_weekly:true },
                Indicator { id:"right".into(), provider:"codex".into(), inner:None, outer:Some(0.09),
                    text:"9%".into(), work_state:"waiting".into(), dimmed:true, inner_weekly:false, outer_weekly:true },
            ], dark:true, watch:0.5, critical:0.7, appearance:crate::taskbar_model::Appearance::from_config(&crate::config::Config::default()) };
            renderer.draw(&frame, 1.0, Some(0), Some(1), 0.75).unwrap();
            frame.dark = false;
            renderer.draw(&frame, 1.0, None, None, 1.5).unwrap();
            for size in [0.8,1.0,1.25] {
                frame.appearance.size = size;
                for transition in ["hard_step","ramp"] {
                    frame.appearance.color_transition = transition.into();
                    for dashed in [false,true] {
                        frame.appearance.weekly_dashed = dashed;
                        renderer.draw(&frame,1.0,Some(0),None,1.6).unwrap();
                        // A weekly arc moved inside keeps its dashed style.
                        frame.items[0].inner_weekly = true;
                        frame.items[0].outer_weekly = false;
                        renderer.draw(&frame,1.0,None,None,1.7).unwrap();
                        frame.items[0].inner_weekly = false;
                        frame.items[0].outer_weekly = true;
                    }
                }
            }
            frame.appearance.size = 1.0;
            // Every built-in document is also submitted through DrawSvgDocument.
            frame.items = LOGOS.iter().enumerate().map(|(index, (provider, _))| Indicator {
                id:format!("fixture-{index}"), provider:(*provider).into(), inner:None,
                outer:Some(index as f32 / 6.0), text:format!("{}%", index * 16),
                work_state:"idle".into(), dimmed:index % 2 != 0, inner_weekly:false, outer_weekly:false,
            }).collect();
            renderer.resize(1120, 84).unwrap();
            renderer.draw(&frame, 2.0, Some(4), Some(5), 2.0).unwrap();
            frame.dark = true;
            for item in &mut frame.items { item.dimmed = !item.dimmed; }
            renderer.draw(&frame, 2.0, None, None, 2.5).unwrap();
            // Rejecting an invalid resize must leave the previous surface usable.
            assert!(renderer.resize(0, 84).is_err());
            renderer.draw(&frame, 2.0, None, None, 3.0).unwrap();
            renderer.resize(98, 42).unwrap();
            renderer.draw(&frame, 1.0, None, None, 3.5).unwrap();
            // Drop order: renderer, child, parent, registered class, COM apartment.
        }).join().unwrap();
    }
}
