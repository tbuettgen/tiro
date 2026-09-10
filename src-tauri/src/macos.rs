//! Native macOS services. Permissions are requested only when used.

use core_foundation::array::{CFArray, CFArrayRef};
use core_foundation::base::{CFType, CFTypeRef, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::{CFDictionary, CFDictionaryRef};
use core_foundation::string::{CFString, CFStringRef};
use std::sync::{mpsc, Mutex};
use std::time::{Duration, Instant};

#[link(name = "IOKit", kind = "framework")]
extern "C" {
    fn IOPSCopyPowerSourcesInfo() -> CFTypeRef;
    fn IOPSCopyPowerSourcesList(info: CFTypeRef) -> CFArrayRef;
    fn IOPSGetPowerSourceDescription(info: CFTypeRef, source: CFTypeRef) -> CFDictionaryRef;
    fn IOPSGetProvidingPowerSourceType(info: CFTypeRef) -> CFStringRef;
}

#[link(name = "CoreGraphics", kind = "framework")]
extern "C" {
    fn CGPreflightPostEventAccess() -> bool;
    fn CGRequestPostEventAccess() -> bool;
    fn CGEventSourceFlagsState(state: i32) -> u64;
    fn CGEventSourceKeyState(state: i32, key: u16) -> bool;
}

fn power_info() -> Option<CFType> {
    // Copy functions transfer ownership; the CF wrappers release on drop.
    let info = unsafe { IOPSCopyPowerSourcesInfo() };
    (!info.is_null()).then(|| unsafe { CFType::wrap_under_create_rule(info) })
}

pub fn on_ac_power() -> bool {
    let Some(info) = power_info() else {
        return false;
    };
    let source = unsafe { IOPSGetProvidingPowerSourceType(info.as_CFTypeRef()) };
    !source.is_null()
        && unsafe { CFString::wrap_under_get_rule(source) } == CFString::new("AC Power")
}

fn is_internal_battery(description: &CFDictionary<CFString, CFType>) -> bool {
    let kind = description
        .find(CFString::new("Type"))
        .and_then(|v| v.downcast::<CFString>());
    let present = description
        .find(CFString::new("Is Present"))
        .and_then(|v| v.downcast::<CFBoolean>());
    kind == Some(CFString::new("InternalBattery")) && present.is_some_and(bool::from)
}

pub fn battery_present() -> bool {
    let Some(info) = power_info() else {
        return false;
    };
    let sources = unsafe { IOPSCopyPowerSourcesList(info.as_CFTypeRef()) };
    if sources.is_null() {
        return false;
    }
    let sources = unsafe { CFArray::<CFType>::wrap_under_create_rule(sources) };
    sources.iter().any(|source| {
        let description =
            unsafe { IOPSGetPowerSourceDescription(info.as_CFTypeRef(), source.as_CFTypeRef()) };
        !description.is_null()
            && is_internal_battery(&unsafe { CFDictionary::wrap_under_get_rule(description) })
    })
}

/// Called on the recording thread before opening CoreAudio. A denied mic
/// must produce an actionable error instead of recording silent samples.
pub fn ensure_microphone_access() -> Result<(), String> {
    use objc2_av_foundation::{AVAuthorizationStatus, AVCaptureDevice, AVMediaTypeAudio};
    let media = unsafe { AVMediaTypeAudio }.ok_or("macOS audio capture is unavailable")?;
    let status = unsafe { AVCaptureDevice::authorizationStatusForMediaType(media) };
    if status == AVAuthorizationStatus::Authorized {
        return Ok(());
    }
    if status == AVAuthorizationStatus::NotDetermined {
        let (tx, rx) = mpsc::channel();
        let completion = block2::RcBlock::new(move |granted| {
            let _ = tx.send(bool::from(granted));
        });
        unsafe {
            AVCaptureDevice::requestAccessForMediaType_completionHandler(media, &completion);
        }
        match rx.recv_timeout(Duration::from_secs(60)) {
            Ok(true) => return Ok(()),
            Err(_) => return Err("Microphone permission is pending. Respond to the macOS dialog, then start dictation again.".into()),
            Ok(false) => {}
        }
    }
    Err("Allow Tiro in System Settings → Privacy & Security → Microphone, then try again.".into())
}

/// Where a first-run menu bar item lands, in points from the right edge
/// of the screen. macOS places a status item it has never seen at the far
/// LEFT of the status area, and on a MacBook with a notch that is exactly
/// the part that gets cut off once the bar is full — the item then exists
/// but is never drawn. AppKit persists each item's spot as
/// `NSStatusItem Preferred Position <autosave name>` in the app's user
/// defaults (the user's Cmd-drag writes the same key), so seeding it once
/// puts Tiro among the visible items next to the system controls. A
/// later drag by the user overwrites it and is never touched again.
const MENU_BAR_PREFERRED_POSITION: f64 = 420.0;

/// Seed the menu bar item's position before the tray is built (see
/// `MENU_BAR_PREFERRED_POSITION`). AppKit names the app's first status
/// item `Item-0` when no autosave name is set, which is what tray-icon
/// creates. Never overwrites an existing value.
pub fn hint_menu_bar_position() {
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::runtime::{AnyClass, AnyObject};
    use objc2_foundation::NSString;

    let Some(cls) = AnyClass::get(c"NSUserDefaults") else {
        return;
    };
    let key = NSString::from_str("NSStatusItem Preferred Position Item-0");
    // SAFETY: plain Foundation calls on the standard defaults object with
    // an NSString key and a double; both arguments outlive the calls.
    unsafe {
        let defaults: Retained<AnyObject> = msg_send![cls, standardUserDefaults];
        let existing: Option<Retained<AnyObject>> = msg_send![&*defaults, objectForKey: &*key];
        if existing.is_none() {
            let _: () =
                msg_send![&*defaults, setDouble: MENU_BAR_PREFERRED_POSITION, forKey: &*key];
        }
    }
}

/// The notch of a built-in display, in points relative to that screen's
/// own left edge: `left`/`right` are the x extents of the cutout and
/// `height` the band it occupies (`NSScreen.safeAreaInsets.top`, which is
/// also the menu bar height there).
#[derive(Clone, Copy, Debug, PartialEq)]
pub struct Notch {
    pub height: f64,
    pub left: f64,
    pub right: f64,
}

/// The notch of the monitor with the given tao-style bounds (physical px,
/// top-left origin), or None when that screen has none — an external
/// display, or a MacBook without one. Main thread only.
pub fn notch_for_monitor(x: i32, y: i32, width: u32, height: u32) -> Option<Notch> {
    use objc2::msg_send;
    use objc2::rc::Retained;
    use objc2::{ClassType, MainThreadMarker};
    use objc2_app_kit::NSScreen;
    use objc2_foundation::{NSArray, NSEdgeInsets, NSRect};

    MainThreadMarker::new()?;
    // SAFETY: NSScreen class method and property getters, main thread.
    unsafe {
        let screens: Retained<NSArray<NSScreen>> = msg_send![NSScreen::class(), screens];
        let count = screens.count();
        if count == 0 {
            return None;
        }
        // AppKit frames are points with a bottom-left origin on the primary
        // screen; tao reports physical px with a top-left origin. Flip and
        // scale each frame to find the screen the caller means.
        let primary: Retained<NSScreen> = msg_send![&*screens, objectAtIndex: 0usize];
        let primary_frame: NSRect = msg_send![&*primary, frame];
        let main_h = primary_frame.size.height;
        for i in 0..count {
            let screen: Retained<NSScreen> = msg_send![&*screens, objectAtIndex: i];
            let frame: NSRect = msg_send![&*screen, frame];
            let scale: f64 = msg_send![&*screen, backingScaleFactor];
            let px = (frame.origin.x * scale).round() as i32;
            let py = ((main_h - (frame.origin.y + frame.size.height)) * scale).round() as i32;
            let pw = (frame.size.width * scale).round() as u32;
            let ph = (frame.size.height * scale).round() as u32;
            if (px - x).abs() > 2 || (py - y).abs() > 2 || pw != width || ph != height {
                continue;
            }
            let insets: NSEdgeInsets = msg_send![&*screen, safeAreaInsets];
            if insets.top <= 0.0 {
                return None;
            }
            let left: NSRect = msg_send![&*screen, auxiliaryTopLeftArea];
            let right: NSRect = msg_send![&*screen, auxiliaryTopRightArea];
            return Some(Notch {
                height: insets.top,
                left: left.origin.x + left.size.width - frame.origin.x,
                right: right.origin.x - frame.origin.x,
            });
        }
        None
    }
}

/// Window levels and Space behaviour for the two overlays. With
/// `over_fullscreen` the pill joins every Space — full-screen apps
/// included — at the screen-saver level, so a take started inside a
/// full-screen app still shows its indicator; off, it is an ordinary
/// floating window on the current Space — except that a pill docked at
/// the notch (`notch`) draws over the menu bar band, so it still needs
/// the status level to be seen there. The panel joins all Spaces (and
/// full-screen ones) at its usual level so the hotkey can always summon
/// it. Main thread only; safe to call again when a setting changes.
pub fn configure_overlay_windows(app: &tauri::AppHandle, over_fullscreen: bool, notch: bool) {
    use objc2::msg_send;
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};
    use tauri::Manager;

    const FLOATING: isize = 3; // NSFloatingWindowLevel
    const STATUS: isize = 25; // NSStatusWindowLevel, above the menu bar
    const SCREEN_SAVER: isize = 1000; // NSScreenSaverWindowLevel

    fn ns_window(w: &tauri::WebviewWindow) -> Option<&'static NSWindow> {
        let raw = std::ptr::NonNull::new(w.ns_window().ok()?)?;
        // SAFETY: tauri hands back the live NSWindow; main thread only.
        Some(unsafe { raw.cast::<NSWindow>().as_ref() })
    }

    if let Some(win) = app.get_webview_window("pill").as_ref().and_then(ns_window) {
        let (level, behavior) = if over_fullscreen {
            (
                SCREEN_SAVER,
                NSWindowCollectionBehavior::CanJoinAllSpaces
                    | NSWindowCollectionBehavior::FullScreenAuxiliary
                    | NSWindowCollectionBehavior::Stationary
                    | NSWindowCollectionBehavior::IgnoresCycle,
            )
        } else {
            (
                if notch { STATUS } else { FLOATING },
                NSWindowCollectionBehavior::empty(),
            )
        };
        // SAFETY: plain NSWindow setters on the main thread.
        unsafe {
            let _: () = msg_send![win, setCollectionBehavior: behavior];
            let _: () = msg_send![win, setLevel: level];
        }
    }
    if let Some(win) = app.get_webview_window("panel").as_ref().and_then(ns_window) {
        let behavior = NSWindowCollectionBehavior::CanJoinAllSpaces
            | NSWindowCollectionBehavior::FullScreenAuxiliary;
        // SAFETY: as above.
        unsafe {
            let _: () = msg_send![win, setCollectionBehavior: behavior];
        }
    }
}

/// Present the pill window: re-assert its level and Space behaviour (cheap,
/// and immune to anything that touched them since setup), then order it
/// front even though Tiro is not the active app — `show()` goes through
/// `makeKeyAndOrderFront:`, which macOS ignores for an inactive app's
/// window while another app's full-screen Space is up, exactly when
/// `pill_over_fullscreen` matters. Logs once if the window still is not on
/// the active Space afterwards. Main thread only.
pub fn present_pill(app: &tauri::AppHandle, window: &tauri::WebviewWindow) {
    use objc2::msg_send;
    use objc2_app_kit::{NSWindow, NSWindowCollectionBehavior};
    use tauri::Manager;

    let (over, notch) = {
        let ctx = app.state::<crate::flow::AppCtx>();
        let cfg = crate::flow::lock(&ctx.cfg);
        (
            cfg.get_bool("pill_over_fullscreen"),
            crate::placement::resolve_pill_dock(&cfg.get("pill_position"))
                == crate::placement::PillDock::Notch,
        )
    };
    configure_overlay_windows(app, over, notch);
    let Some(raw) = window.ns_window().ok().and_then(std::ptr::NonNull::new) else {
        return;
    };
    // SAFETY: tauri hands back the live NSWindow; main thread only.
    unsafe {
        let win: &NSWindow = raw.cast::<NSWindow>().as_ref();
        let _: () = msg_send![win, orderFrontRegardless];
        let on_space: bool = msg_send![win, isOnActiveSpace];
        if over && !on_space {
            let behavior: NSWindowCollectionBehavior = msg_send![win, collectionBehavior];
            let level: isize = msg_send![win, level];
            let visible: bool = msg_send![win, isVisible];
            eprintln!(
                "pill: not on the active Space after ordering (behavior={:#x} level={level} visible={visible})",
                behavior.bits()
            );
        }
    }
}

/// Create the panel and pill windows. On macOS they are NOT declared in
/// the config (tauri.macos.conf.json empties `app.windows`): an NSWindow
/// created while the process is still a regular app never joins another
/// app's full-screen Space, whatever collection behaviour it is given
/// later, so the pill could not show over full-screen apps. tao applies
/// the activation policy only when the run loop starts — after config
/// windows already exist — hence the policy is applied at runtime first
/// and the windows are built here, with the same options the shared
/// config gives the other platforms.
pub fn build_windows(app: &tauri::App) -> tauri::Result<()> {
    use tauri::{WebviewUrl, WebviewWindowBuilder};

    WebviewWindowBuilder::new(app, "panel", WebviewUrl::App("index.html".into()))
        .title("Tiro")
        .inner_size(800.0, 560.0)
        .min_inner_size(800.0, 560.0)
        .max_inner_size(800.0, 560.0)
        .resizable(true)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .skip_taskbar(true)
        .visible(false)
        .build()?;
    WebviewWindowBuilder::new(app, "pill", WebviewUrl::App("pill.html".into()))
        .title("Tiro Pill")
        .inner_size(300.0, 76.0)
        .min_inner_size(300.0, 76.0)
        .max_inner_size(300.0, 76.0)
        .resizable(true)
        .decorations(false)
        .transparent(true)
        .shadow(false)
        .skip_taskbar(true)
        .visible(false)
        .always_on_top(true)
        .focused(false)
        .focusable(false)
        .build()?;
    Ok(())
}

static PASTE_GATE: Mutex<()> = Mutex::new(());

/// The paste chord is Command+V on macOS. Keep physical modifiers out of
/// it; if the user continues holding a shortcut, leave the text copied.
pub fn paste() -> Result<(), String> {
    use core_graphics::event::{CGEvent, CGEventFlags, CGEventTapLocation};
    use core_graphics::event_source::{CGEventSource, CGEventSourceStateID};

    let _guard = PASTE_GATE.lock().unwrap_or_else(|e| e.into_inner());
    if !unsafe { CGPreflightPostEventAccess() } && !unsafe { CGRequestPostEventAccess() } {
        return Err("Text copied. Allow Tiro in System Settings → Privacy & Security → Accessibility to paste at the cursor.".into());
    }
    // kVK_ANSI_V; HID state is physical keyboard state. Caps Lock and Fn
    // are intentionally excluded from the shortcut-modifier mask.
    const V: u16 = 9;
    let modifiers = (CGEventFlags::CGEventFlagShift
        | CGEventFlags::CGEventFlagControl
        | CGEventFlags::CGEventFlagAlternate
        | CGEventFlags::CGEventFlagCommand)
        .bits();
    let started = Instant::now();
    while unsafe { CGEventSourceFlagsState(1) } & modifiers != 0
        || unsafe { CGEventSourceKeyState(1, V) }
    {
        if started.elapsed() >= Duration::from_secs(2) {
            return Err("Text copied. Release the shortcut keys and paste with Command+V.".into());
        }
        std::thread::sleep(Duration::from_millis(15));
    }
    std::thread::sleep(Duration::from_millis(120));
    let source = CGEventSource::new(CGEventSourceStateID::Private)
        .map_err(|_| "Could not create a macOS keyboard event source")?;
    // Construct both events before posting so allocation failure cannot
    // leave the target with a key-down and no matching key-up.
    let down = CGEvent::new_keyboard_event(source.clone(), V, true)
        .map_err(|_| "Could not create the paste key-down event")?;
    let up = CGEvent::new_keyboard_event(source, V, false)
        .map_err(|_| "Could not create the paste key-up event")?;
    down.set_flags(CGEventFlags::CGEventFlagCommand);
    up.set_flags(CGEventFlags::CGEventFlagCommand);
    down.post(CGEventTapLocation::HID);
    up.post(CGEventTapLocation::HID);
    Ok(())
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn only_a_present_internal_battery_makes_a_laptop() {
        for (kind, present, expected) in [
            ("InternalBattery", true, true),
            ("InternalBattery", false, false),
            ("UPS", true, false),
            ("ExternalBattery", true, false),
        ] {
            let description = CFDictionary::from_CFType_pairs(&[
                (CFString::new("Type"), CFString::new(kind).as_CFType()),
                (
                    CFString::new("Is Present"),
                    CFBoolean::from(present).as_CFType(),
                ),
            ]);
            assert_eq!(is_internal_battery(&description), expected, "{kind}");
        }
        let empty = CFDictionary::from_CFType_pairs(&[]);
        assert!(!is_internal_battery(&empty));
    }
}
