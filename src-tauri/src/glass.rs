//! Native glass backdrop for the panel window on macOS.
//!
//! The panel is a frameless transparent window, so its CSS "glass" is only
//! a tinted layer over whatever happens to be behind it — the webview has
//! nothing of the desktop to blur. This inserts an AppKit effect view
//! UNDER the webview so the surface picks up the desktop like a system
//! HUD panel does:
//!
//! - macOS 26 and newer: `NSGlassEffectView` (Liquid Glass), resolved by
//!   class name at runtime so the same binary keeps running on older
//!   releases.
//! - macOS 12 through 15: `NSVisualEffectView` with the HUD material.
//!
//! The webview stays a sibling on top; the CSS tint the Transparency slider
//! drives is composited over the backdrop, so 0 still reads as solid and
//! 100 shows mostly backdrop. Every AppKit view mutation here runs on the
//! main thread (`run_on_main_thread`), like the rest of the window code.

use std::ffi::CStr;
use std::ptr::NonNull;

use objc2::rc::{Allocated, Retained};
use objc2::runtime::AnyClass;
use objc2::runtime::AnyObject;
use objc2::{msg_send, ClassType, MainThreadMarker};
use objc2_app_kit::{
    NSAppearance, NSAutoresizingMaskOptions, NSView, NSVisualEffectBlendingMode,
    NSVisualEffectMaterial, NSVisualEffectState, NSVisualEffectView, NSWindowOrderingMode,
};
use objc2_foundation::{NSArray, NSPoint, NSRect, NSSize, NSString};
use tauri::{AppHandle, Manager, WebviewWindow};

/// Corner radius of the panel glass (`--r-surface` in ui/styles.css).
pub const PANEL_RADIUS: f64 = 14.0;

/// The Liquid Glass view class; absent before macOS 26.
const GLASS_CLASS: &CStr = c"NSGlassEffectView";

/// Which backdrop `apply` produced, for the log line.
#[derive(Clone, Copy, PartialEq, Eq, Debug)]
pub enum Backdrop {
    /// `NSGlassEffectView` — real Liquid Glass (macOS 26+).
    Liquid,
    /// `NSVisualEffectView` HUD material (macOS 12–15).
    Vibrancy,
}

impl Backdrop {
    pub fn as_str(self) -> &'static str {
        match self {
            Backdrop::Liquid => "liquid glass",
            Backdrop::Vibrancy => "vibrancy",
        }
    }
}

/// The window's content view. `'static` is a convenience: callers use the
/// reference only for the duration of one main-thread closure while the
/// `WebviewWindow` handle keeps the window alive.
fn content_view(window: &WebviewWindow) -> Result<&'static NSView, String> {
    let raw = window.ns_view().map_err(|e| e.to_string())?;
    let raw = NonNull::new(raw).ok_or("window has no content view")?;
    // SAFETY: tauri hands back the window's NSView, and this only runs on
    // the main thread (every caller checks `MainThreadMarker` first).
    Ok(unsafe { raw.cast::<NSView>().as_ref() })
}

/// Every backdrop view inserted earlier (the effect views are the only
/// NSVisualEffectView / NSGlassEffectView children the content view ever
/// has — the webview is a WKWebView).
///
/// # Safety
/// Main thread only, with `content` a live NSView.
unsafe fn backdrops(content: &NSView) -> Vec<Retained<NSView>> {
    // `subviews` returns a copy, so removing from it later is safe.
    let subviews: Retained<NSArray<NSView>> = msg_send![content, subviews];
    let glass = AnyClass::get(GLASS_CLASS);
    let mut found = Vec::new();
    for i in 0..subviews.count() {
        let sub: Retained<NSView> = msg_send![&*subviews, objectAtIndex: i];
        let vibrancy: bool = msg_send![&*sub, isKindOfClass: NSVisualEffectView::class()];
        let liquid: bool = match glass {
            Some(cls) => msg_send![&*sub, isKindOfClass: cls],
            None => false,
        };
        if vibrancy || liquid {
            found.push(sub);
        }
    }
    found
}

/// The backdrop's frame for a glass `width` (logical px) inside `bounds`:
/// hugging the window's right edge like the CSS surface does, full height.
fn glass_frame(bounds: NSRect, width: f64) -> NSRect {
    let w = width.min(bounds.size.width);
    NSRect {
        origin: NSPoint {
            x: bounds.size.width - w,
            y: 0.0,
        },
        size: NSSize {
            width: w,
            height: bounds.size.height,
        },
    }
}

/// Insert the backdrop under the window's webview, replacing any earlier
/// one, sized to the glass `width` (logical px; the surface is narrower
/// than the window while compact). Main thread only.
pub fn apply(window: &WebviewWindow, radius: f64, width: f64) -> Result<Backdrop, String> {
    let mtm = MainThreadMarker::new().ok_or("glass: not on the main thread")?;
    let content = content_view(window)?;
    // SAFETY: main thread (checked above); `content` is the live content
    // view; every class used is an NSView subclass, and the new view is
    // handed to AppKit which retains it as a subview.
    unsafe {
        for old in backdrops(content) {
            let _: () = msg_send![&*old, removeFromSuperview];
        }
        let win_bounds: NSRect = msg_send![content, bounds];
        let bounds = glass_frame(win_bounds, width);
        let (view, kind): (Retained<NSView>, Backdrop) = match AnyClass::get(GLASS_CLASS) {
            Some(cls) => {
                let alloc: Allocated<NSView> = msg_send![cls, alloc];
                let view: Retained<NSView> = msg_send![alloc, initWithFrame: bounds];
                let _: () = msg_send![&*view, setCornerRadius: radius];
                (view, Backdrop::Liquid)
            }
            None => {
                let alloc = mtm.alloc::<NSVisualEffectView>();
                let view: Retained<NSVisualEffectView> = msg_send![alloc, initWithFrame: bounds];
                let _: () = msg_send![&*view, setMaterial: NSVisualEffectMaterial::HUDWindow];
                let _: () =
                    msg_send![&*view, setBlendingMode: NSVisualEffectBlendingMode::BehindWindow];
                let _: () = msg_send![&*view, setState: NSVisualEffectState::Active];
                // Not in the headers, but honored by NSVisualEffectView for
                // years (the window-vibrancy crate relies on it as well).
                let _: () = msg_send![&*view, setCornerRadius: radius];
                (Retained::into_super(view), Backdrop::Vibrancy)
            }
        };
        // Right-anchored with a fixed width: the window grows and shrinks
        // natively around the glass, which animates its width on its own
        // (`set_glass_width`), so the backdrop must never just fill the
        // window — that is a blurred slab popping in beside the surface.
        let mask = NSAutoresizingMaskOptions::ViewMinXMargin
            | NSAutoresizingMaskOptions::ViewHeightSizable;
        let _: () = msg_send![&*view, setAutoresizingMask: mask];
        let _: () = msg_send![
            content,
            addSubview: &*view,
            positioned: NSWindowOrderingMode::Below,
            relativeTo: Option::<&NSView>::None
        ];
        Ok(kind)
    }
}

/// Remove the backdrop again (the Liquid Glass switch turned off). Main
/// thread only.
pub fn clear(window: &WebviewWindow) -> Result<(), String> {
    MainThreadMarker::new().ok_or("glass: not on the main thread")?;
    let content = content_view(window)?;
    // SAFETY: main thread; live content view.
    unsafe {
        for old in backdrops(content) {
            let _: () = msg_send![&*old, removeFromSuperview];
        }
    }
    Ok(())
}

/// Pin the backdrop's appearance to Tiro's theme: the material must read
/// dark under the dark tint and light under the light one even when the
/// OS is set the other way. `None` follows the OS again (theme = system).
/// Only the backdrop view is touched, so the window keeps reporting the
/// OS appearance to `effective_theme`. Main thread only.
pub fn set_appearance(window: &WebviewWindow, dark: Option<bool>) -> Result<(), String> {
    MainThreadMarker::new().ok_or("glass: not on the main thread")?;
    let content = content_view(window)?;
    let appearance: Option<Retained<NSAppearance>> = match dark {
        None => None,
        Some(dark) => {
            let name = NSString::from_str(if dark {
                "NSAppearanceNameDarkAqua"
            } else {
                "NSAppearanceNameAqua"
            });
            // SAFETY: class method with an NSString argument, main thread.
            unsafe { msg_send![NSAppearance::class(), appearanceNamed: &*name] }
        }
    };
    // SAFETY: main thread; live content view; nil appearance is allowed.
    unsafe {
        for view in backdrops(content) {
            let _: () = msg_send![&*view, setAppearance: appearance.as_deref()];
        }
    }
    Ok(())
}

/// Match the backdrop to the glass width (logical px), animating over `ms`
/// when the CSS surface is animating too (0 snaps). Safe from any thread.
pub fn set_glass_width(app: &AppHandle, width: f64, ms: u64) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        let Some(panel) = app.get_webview_window("panel") else {
            return;
        };
        let Ok(content) = content_view(&panel) else {
            return;
        };
        // SAFETY: main thread; live content view; NSAnimationContext is a
        // plain AppKit class and the animator proxy forwards setFrame:.
        unsafe {
            let bounds: NSRect = msg_send![content, bounds];
            let frame = glass_frame(bounds, width);
            let context = AnyClass::get(c"NSAnimationContext");
            for view in backdrops(content) {
                match (ms, context) {
                    (0, _) | (_, None) => {
                        let _: () = msg_send![&*view, setFrame: frame];
                    }
                    (ms, Some(cls)) => {
                        let _: () = msg_send![cls, beginGrouping];
                        let current: Retained<AnyObject> = msg_send![cls, currentContext];
                        let _: () = msg_send![&*current, setDuration: ms as f64 / 1000.0];
                        let animator: Retained<AnyObject> = msg_send![&*view, animator];
                        let _: () = msg_send![&*animator, setFrame: frame];
                        let _: () = msg_send![cls, endGrouping];
                    }
                }
            }
        }
    });
}

/// Apply or remove the panel backdrop to match the `liquid_glass` setting,
/// then pin its appearance to the configured theme. Safe to call from any
/// thread; the AppKit work is queued onto the main thread. Failures are
/// logged, never fatal — the CSS tint still renders without a backdrop.
pub fn sync(app: &AppHandle) {
    let app = app.clone();
    let _ = app.clone().run_on_main_thread(move || {
        let ctx = app.state::<crate::flow::AppCtx>();
        let (enabled, theme) = {
            let cfg = crate::flow::lock(&ctx.cfg);
            (
                cfg.get_bool("liquid_glass"),
                cfg.get("theme").to_lowercase(),
            )
        };
        let Some(panel) = app.get_webview_window("panel") else {
            return;
        };
        if !enabled {
            if let Err(e) = clear(&panel) {
                eprintln!("glass: clear failed: {e}");
            }
            return;
        }
        let width = if crate::placement::panel_expanded(&app) {
            f64::from(crate::placement::PANEL_W_EXPANDED)
        } else {
            f64::from(crate::placement::PANEL_W_COMPACT)
        };
        match apply(&panel, PANEL_RADIUS, width) {
            Ok(kind) => eprintln!("glass: panel backdrop = {}", kind.as_str()),
            Err(e) => {
                eprintln!("glass: apply failed: {e}");
                return;
            }
        }
        let dark = match theme.as_str() {
            "dark" => Some(true),
            "light" => Some(false),
            _ => None,
        };
        if let Err(e) = set_appearance(&panel, dark) {
            eprintln!("glass: appearance failed: {e}");
        }
    });
}
