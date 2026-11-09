use std::{
    sync::Mutex,
    time::{Duration, Instant},
};
use tauri::{Manager, PhysicalPosition, PhysicalSize, Rect};

#[derive(Default)]
pub struct PopupState {
    last_hidden: Mutex<Option<Instant>>,
}

pub fn hide(app: &tauri::AppHandle) {
    let Some(window) = app.get_webview_window("mixer") else {
        return;
    };
    if window.is_visible().unwrap_or(false) {
        if let Ok(mut last) = window.state::<PopupState>().last_hidden.lock() {
            *last = Some(Instant::now());
        }
        let _ = window.hide();
    }
}

pub fn toggle(app: &tauri::AppHandle, anchor: Rect) {
    let Some(window) = app.get_webview_window("mixer") else {
        return;
    };
    // Clicking the tray may blur the panel before the mouse-up event arrives.
    let just_hidden = app
        .state::<PopupState>()
        .last_hidden
        .lock()
        .ok()
        .and_then(|last| *last)
        .is_some_and(|last| last.elapsed() < Duration::from_millis(300));
    if window.is_visible().unwrap_or(false) || just_hidden {
        hide(app);
    } else {
        show_at(app, Some(anchor));
    }
}

const EDGE_GAP: f64 = 8.0;
const TRAY_GAP: f64 = 6.0;
const PANEL_WIDTH: f64 = 460.0;
const PANEL_HEIGHT: f64 = 740.0;

/// Geometry is in physical pixels on the tray's monitor.
fn placement(
    anchor: (f64, f64, f64, f64),
    work: (f64, f64, f64, f64),
    scale: f64,
) -> (i32, i32, u32, u32) {
    let (ax, ay, aw, ah) = anchor;
    let (wx, wy, ww, wh) = work;
    let edge = EDGE_GAP * scale;
    let gap = TRAY_GAP * scale;
    let width = (PANEL_WIDTH * scale).min((ww - edge * 2.0).max(1.0));
    let desired_height = (PANEL_HEIGHT * scale).min((wh - edge * 2.0).max(1.0));
    let x = (ax + aw / 2.0 - width / 2.0).clamp(wx + edge, (wx + ww - edge - width).max(wx + edge));
    let below = (ay + ah + gap).max(wy + edge);
    let bottom = wy + wh - edge;
    // macOS menu bar anchors have enough room below. Bottom taskbars open upwards.
    let (y, height) = if below < bottom && ay + ah / 2.0 <= wy + wh / 2.0 {
        (below, desired_height.min(bottom - below))
    } else {
        let height = desired_height.min((ay - gap - wy - edge).max(1.0));
        ((ay - gap - height).max(wy + edge), height)
    };
    (
        x.round() as i32,
        y.round() as i32,
        width.round() as u32,
        height.round() as u32,
    )
}

pub fn show(app: &tauri::AppHandle) {
    let rect = app
        .tray_by_id("mixer-tray")
        .and_then(|tray| tray.rect().ok().flatten());
    show_at(app, rect);
}

pub fn show_at(app: &tauri::AppHandle, anchor: Option<Rect>) {
    let Some(window) = app.get_webview_window("mixer") else {
        return;
    };
    let result = (|| -> tauri::Result<()> {
        if let Some(rect) = anchor {
            let monitors = window.available_monitors()?;
            // Tray rectangles are physical on macOS/Windows. Select using each monitor's
            // scale when a backend returns logical coordinates.
            let monitor = monitors.iter().find(|monitor| {
                let p = rect.position.to_physical::<f64>(monitor.scale_factor());
                let s = rect.size.to_physical::<f64>(monitor.scale_factor());
                let x = p.x + s.width / 2.0;
                let y = p.y + s.height / 2.0;
                let origin = monitor.position();
                let size = monitor.size();
                x >= origin.x as f64
                    && x < origin.x as f64 + size.width as f64
                    && y >= origin.y as f64
                    && y < origin.y as f64 + size.height as f64
            });
            if let Some(monitor) = monitor {
                let scale = monitor.scale_factor();
                let p = rect.position.to_physical::<f64>(scale);
                let s = rect.size.to_physical::<f64>(scale);
                let work = monitor.work_area();
                let (x, y, width, height) = placement(
                    (p.x, p.y, s.width, s.height),
                    (
                        work.position.x as f64,
                        work.position.y as f64,
                        work.size.width as f64,
                        work.size.height as f64,
                    ),
                    scale,
                );
                window.set_size(PhysicalSize::new(width, height))?;
                window.set_position(PhysicalPosition::new(x, y))?;
            } else {
                window.center()?;
            }
        } else {
            window.center()?;
        }
        window.show()?;
        window.set_focus()
    })();
    if let Err(error) = result {
        eprintln!("Unable to position mixer popup: {error}");
        let _ = window.show();
        let _ = window.set_focus();
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn aligns_below_tray_and_keeps_right_edge_visible() {
        let (x, y, w, h) = placement((1400.0, 0.0, 24.0, 24.0), (0.0, 24.0, 1440.0, 876.0), 1.0);
        assert_eq!((x, y, w, h), (972, 32, 460, 740));
    }
    #[test]
    fn handles_retina_and_negative_monitor_origins() {
        let (x, y, w, h) = placement(
            (-2300.0, 0.0, 48.0, 48.0),
            (-2560.0, 48.0, 2560.0, 1552.0),
            2.0,
        );
        assert_eq!((x, y, w, h), (-2544, 64, 920, 1480));
    }
    #[test]
    fn short_screen_reduces_height_without_covering_menu_bar() {
        let (x, y, w, h) = placement((400.0, 0.0, 24.0, 24.0), (0.0, 24.0, 800.0, 576.0), 1.0);
        assert_eq!((x, y, w, h), (182, 32, 460, 560));
    }
    #[test]
    fn bottom_taskbar_opens_above_anchor() {
        let (_, y, _, h) = placement((800.0, 860.0, 24.0, 40.0), (0.0, 0.0, 1440.0, 860.0), 1.0);
        assert_eq!((y, h), (114, 740));
    }
}
