mod backend;
mod popup;
use backend::Backend;
use popup::show;
use serde_json::{json, Value};
use tauri::{
    menu::{Menu, MenuItem},
    tray::{MouseButton, MouseButtonState, TrayIconBuilder, TrayIconEvent},
    Manager,
};

#[tauri::command]
async fn audio_request(
    request: Value,
    backend: tauri::State<'_, Backend>,
) -> Result<Value, String> {
    backend.request(request).await
}
#[tauri::command]
fn hide_panel(window: tauri::Window) {
    popup::hide(window.app_handle());
}
#[tauri::command]
async fn quit_app(app: tauri::AppHandle, backend: tauri::State<'_, Backend>) -> Result<(), String> {
    backend.request(json!({"op":"shutdown"})).await?;
    app.exit(0);
    Ok(())
}
fn exit_after_restore(app: tauri::AppHandle) {
    tauri::async_runtime::spawn(async move {
        match app
            .state::<Backend>()
            .request(json!({"op":"shutdown"}))
            .await
        {
            Ok(_) => app.exit(0),
            Err(e) => {
                use tauri::Emitter;
                show(&app);
                let _ = app.emit_to("mixer", "audio-error", e);
            }
        }
    });
}
pub fn run() {
    if let Some(app_id) =
        std::env::args().find_map(|arg| arg.strip_prefix("--probe-mix=").map(String::from))
    {
        backend::probe_mix(&app_id);
        return;
    }
    tauri::Builder::default()
        .plugin(tauri_plugin_single_instance::init(|app, _, _| show(app)))
        .invoke_handler(tauri::generate_handler![
            audio_request,
            quit_app,
            hide_panel
        ])
        .setup(|app| {
            app.manage(popup::PopupState::default());
            #[cfg(target_os = "macos")]
            app.set_activation_policy(tauri::ActivationPolicy::Accessory);
            let path = app.path().app_config_dir()?.join("preferences.json");
            app.manage(Backend::start(app.handle().clone(), path));
            let open = MenuItem::with_id(app, "open", "打开混音面板", true, None::<&str>)?;
            let restore =
                MenuItem::with_id(app, "restore", "恢复所有应用原声", true, None::<&str>)?;
            let quit = MenuItem::with_id(app, "quit", "退出", true, None::<&str>)?;
            let menu = Menu::with_items(app, &[&open, &restore, &quit])?;
            let mut pixels = vec![0u8; 32 * 32 * 4];
            for x in 0..32 {
                for y in 0..32 {
                    if ((6..=10).contains(&x) && (11..=21).contains(&y))
                        || ((11..=18).contains(&x) && (6..=26).contains(&y))
                        || ((22..=25).contains(&x) && (10..=22).contains(&y))
                    {
                        let i = (y * 32 + x) * 4;
                        pixels[i + 3] = 255;
                    }
                }
            }
            TrayIconBuilder::with_id("mixer-tray")
                .icon(tauri::image::Image::new_owned(pixels, 32, 32))
                .icon_as_template(true)
                .tooltip("Mac Voice Mix")
                .menu(&menu)
                .show_menu_on_left_click(false)
                .on_menu_event(|app, event| match event.id.as_ref() {
                    "open" => show(app),
                    "quit" => exit_after_restore(app.clone()),
                    "restore" => {
                        let app = app.clone();
                        tauri::async_runtime::spawn(async move {
                            use tauri::Emitter;
                            if let Err(e) = app
                                .state::<Backend>()
                                .request(json!({"op":"restore"}))
                                .await
                            {
                                let _ = app.emit_to("mixer", "audio-error", e);
                            }
                        });
                    }
                    _ => {}
                })
                .on_tray_icon_event(|tray, event| {
                    if let TrayIconEvent::Click {
                        button: MouseButton::Left,
                        button_state: MouseButtonState::Up,
                        rect,
                        ..
                    } = event
                    {
                        popup::toggle(tray.app_handle(), rect);
                    }
                })
                .build(app)?;
            Ok(())
        })
        .on_window_event(|window, event| match event {
            tauri::WindowEvent::CloseRequested { api, .. } => {
                api.prevent_close();
                popup::hide(window.app_handle());
            }
            tauri::WindowEvent::Focused(false) => popup::hide(window.app_handle()),
            _ => {}
        })
        .build(tauri::generate_context!())
        .expect("Unable to build Mac Voice Mix")
        .run(|app, event| {
            if let tauri::RunEvent::ExitRequested {
                code: None, api, ..
            } = event
            {
                api.prevent_exit();
                exit_after_restore(app.clone());
            }
        });
}
