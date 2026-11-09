use serde_json::{json, Value};
use std::{
    collections::{BTreeMap, BTreeSet},
    fs,
    path::PathBuf,
    sync::{
        atomic::{AtomicBool, Ordering},
        mpsc,
    },
    time::{Duration, Instant},
};
use tauri::{AppHandle, Emitter};

#[cfg(target_os = "macos")]
mod native {
    use serde_json::Value;
    use std::ffi::{c_char, c_void, CStr, CString};
    unsafe extern "C" {
        fn mvm_create() -> *mut c_void;
        fn mvm_execute(context: *mut c_void, request: *const c_char) -> *mut c_char;
        fn mvm_free(value: *mut c_char);
        fn mvm_destroy(context: *mut c_void);
    }
    pub struct Native(*mut c_void);
    impl Native {
        pub fn new() -> Result<Self, String> {
            let ptr = unsafe { mvm_create() };
            if ptr.is_null() {
                Err("Unable to create macOS audio backend".into())
            } else {
                Ok(Self(ptr))
            }
        }
        pub fn execute(&mut self, request: &Value) -> Result<Value, String> {
            let input = CString::new(request.to_string()).map_err(|e| e.to_string())?;
            // Context and all native calls are confined to this worker thread.
            let ptr = unsafe { mvm_execute(self.0, input.as_ptr()) };
            if ptr.is_null() {
                return Err("Native backend returned no response".into());
            }
            let bytes = unsafe { CStr::from_ptr(ptr) }.to_bytes().to_vec();
            unsafe { mvm_free(ptr) };
            let result: Value = serde_json::from_slice(&bytes).map_err(|e| e.to_string())?;
            if result["ok"] == true {
                Ok(result["data"].clone())
            } else {
                Err(result["error"].to_string())
            }
        }
    }
    impl Drop for Native {
        fn drop(&mut self) {
            unsafe { mvm_destroy(self.0) };
        }
    }
}
#[cfg(not(target_os = "macos"))]
mod native {
    use serde_json::Value;
    pub struct Native;
    impl Native {
        pub fn new() -> Result<Self, String> {
            Ok(Self)
        }
        pub fn execute(&mut self, _: &Value) -> Result<Value, String> {
            Err("This build currently implements macOS audio only".into())
        }
    }
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Rule {
    volume: f64,
    muted: bool,
}
#[derive(serde::Serialize, serde::Deserialize)]
#[serde(rename_all = "camelCase")]
struct Preferences {
    schema_version: u32,
    #[serde(default)]
    rules: BTreeMap<String, Rule>,
}
impl Default for Preferences {
    fn default() -> Self {
        Self {
            schema_version: 1,
            rules: BTreeMap::new(),
        }
    }
}
fn parse_preferences(bytes: &[u8]) -> Result<Preferences, String> {
    let preferences: Preferences = serde_json::from_slice(bytes).map_err(|e| e.to_string())?;
    if preferences.schema_version != 1
        || preferences.rules.iter().any(|(key, r)| {
            key.is_empty() || !r.volume.is_finite() || !(0.0..=1.0).contains(&r.volume)
        })
    {
        return Err("Invalid preferences version or audio rule".into());
    }
    Ok(preferences)
}
fn validate_request(request: &Value) -> Result<(), String> {
    let op = request["op"].as_str().ok_or("Missing operation")?;
    if ![
        "snapshot",
        "enable_mixing",
        "restore",
        "shutdown",
        "app_control",
        "app_reset",
        "device_default",
        "device_volume",
        "device_mute",
    ]
    .contains(&op)
    {
        return Err("Unsupported operation".into());
    }
    if op.starts_with("device_")
        && (request["uid"].as_str().is_none_or(str::is_empty)
            || !matches!(request["direction"].as_str(), Some("input" | "output")))
    {
        return Err("Invalid device identity or direction".into());
    }
    if op.starts_with("app_") && request["appId"].as_str().is_none_or(str::is_empty) {
        return Err("Missing application identity".into());
    }
    if op == "app_control" || op == "device_volume" {
        let volume = request["volume"].as_f64().ok_or("Missing numeric volume")?;
        if !volume.is_finite() || !(0.0..=1.0).contains(&volume) {
            return Err("Volume must be between zero and one".into());
        }
    }
    if (op == "app_control" || op == "device_mute") && request["muted"].as_bool().is_none() {
        return Err("Mute must be a boolean".into());
    }
    Ok(())
}
struct Message {
    request: Value,
    reply: tauri::async_runtime::Sender<Result<Value, String>>,
}
pub struct Backend {
    sender: mpsc::SyncSender<Message>,
    shutting_down: AtomicBool,
}
impl Backend {
    pub fn start(app: AppHandle, path: PathBuf) -> Self {
        let (sender, receiver) = mpsc::sync_channel::<Message>(128);
        std::thread::spawn(move || worker(app, path, receiver));
        Self {
            sender,
            shutting_down: AtomicBool::new(false),
        }
    }
    pub async fn request(&self, request: Value) -> Result<Value, String> {
        validate_request(&request)?;
        let shutdown = request["op"] == "shutdown";
        if shutdown {
            self.shutting_down
                .compare_exchange(false, true, Ordering::AcqRel, Ordering::Acquire)
                .map_err(|_| "Audio shutdown already in progress")?;
        } else if self.shutting_down.load(Ordering::Acquire) {
            return Err("Audio engine is shutting down".into());
        }
        let (sender, mut receiver) = tauri::async_runtime::channel(1);
        if let Err(e) = self.sender.try_send(Message {
            request,
            reply: sender,
        }) {
            if shutdown {
                self.shutting_down.store(false, Ordering::Release);
            }
            return Err(format!("Audio worker busy or stopped: {e}"));
        }
        let result = receiver
            .recv()
            .await
            .ok_or("Audio worker stopped before responding")?;
        if shutdown && result.is_err() {
            self.shutting_down.store(false, Ordering::Release);
        }
        result
    }
}
fn save(path: &PathBuf, prefs: &Preferences) -> Result<(), String> {
    use std::io::Write;
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|e| e.to_string())?;
    }
    let temp = path.with_extension("tmp");
    let mut file = fs::File::create(&temp).map_err(|e| e.to_string())?;
    file.write_all(&serde_json::to_vec_pretty(prefs).map_err(|e| e.to_string())?)
        .map_err(|e| e.to_string())?;
    file.sync_all().map_err(|e| e.to_string())?;
    fs::rename(temp, path).map_err(|e| e.to_string())
}
fn enrich(
    mut state: Value,
    prefs: &Preferences,
    enabled: bool,
    config_error: &Option<String>,
    instance: &str,
    revision: u64,
) -> Value {
    state["rules"] = serde_json::to_value(&prefs.rules).unwrap_or(json!({}));
    state["mixingEnabled"] = json!(enabled);
    state["configError"] = json!(config_error);
    state["serviceInstanceId"] = json!(instance);
    state["revision"] = json!(revision);
    state
}
fn worker(app: AppHandle, path: PathBuf, receiver: mpsc::Receiver<Message>) {
    let mut native = match native::Native::new() {
        Ok(v) => v,
        Err(e) => {
            while let Ok(m) = receiver.recv() {
                let _ = m.reply.blocking_send(Err(e.clone()));
            }
            return;
        }
    };
    let instance = format!(
        "{}-{}",
        std::process::id(),
        std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap_or_default()
            .as_nanos()
    );
    let mut config_error = None;
    let mut writable = true;
    let mut prefs = match fs::read(&path) {
        Ok(bytes) => parse_preferences(&bytes).unwrap_or_else(|_| {
            writable = false;
            config_error = Some("配置格式无效，原文件未覆盖；本次调整仅在当前运行中生效。".into());
            Preferences::default()
        }),
        Err(e) if e.kind() == std::io::ErrorKind::NotFound => Preferences::default(),
        Err(e) => {
            writable = false;
            config_error = Some(e.to_string());
            Preferences::default()
        }
    };
    let mut enabled = false;
    let mut attempted = BTreeSet::<String>::new();
    let mut dirty = false;
    let mut save_at = Instant::now();
    let mut poll_at = Instant::now();
    let mut revision = 0;
    loop {
        match receiver.recv_timeout(Duration::from_millis(50)) {
            Ok(message) => {
                let op = message.request["op"].as_str().unwrap_or("");
                let shutdown = op == "shutdown";
                let result: Result<Value, String> = (|| {
                    if op == "enable_mixing" {
                        let state = native.execute(&json!({"op":"snapshot"}))?;
                        enabled = true;
                        attempted.clear();
                        return Ok(state);
                    }
                    if op == "app_control" && !enabled {
                        return Err("请先启用应用混音。首次调整时 macOS 会申请音频权限。".into());
                    }
                    // Prevent automatic rule application during restore/shutdown, including cleanup failures.
                    if op == "restore" || shutdown {
                        enabled = false;
                        attempted.clear();
                    }
                    let state = native.execute(&message.request)?;
                    if op == "app_control" {
                        let key = message.request["appId"].as_str().ok_or("Missing appId")?;
                        prefs.rules.insert(
                            key.into(),
                            Rule {
                                volume: message.request["volume"]
                                    .as_f64()
                                    .ok_or("Missing volume")?,
                                muted: message.request["muted"].as_bool().ok_or("Missing mute")?,
                            },
                        );
                        attempted.insert(key.into());
                        dirty = true;
                        save_at = Instant::now() + Duration::from_millis(400);
                    }
                    if op == "app_reset" {
                        if let Some(key) = message.request["appId"].as_str() {
                            prefs.rules.remove(key);
                            attempted.remove(key);
                        }
                        dirty = true;
                        save_at = Instant::now() + Duration::from_millis(400);
                    }
                    if shutdown && dirty && writable {
                        if let Err(e) = save(&path, &prefs) {
                            config_error = Some(e);
                        }
                        dirty = false;
                    }
                    Ok(state)
                })();
                revision += 1;
                let succeeded = result.is_ok();
                let result =
                    result.map(|s| enrich(s, &prefs, enabled, &config_error, &instance, revision));
                if !shutdown {
                    if let Ok(ref state) = result {
                        let _ = app.emit_to("mixer", "audio-state-changed", state);
                    }
                }
                let _ = message.reply.blocking_send(result);
                if shutdown && succeeded {
                    break;
                }
            }
            Err(mpsc::RecvTimeoutError::Timeout) => {}
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        }
        if dirty && writable && Instant::now() >= save_at {
            match save(&path, &prefs) {
                Ok(_) => config_error = None,
                Err(e) => config_error = Some(e),
            }
            dirty = false;
        }
        if Instant::now() >= poll_at {
            poll_at = Instant::now() + Duration::from_millis(400);
            match native.execute(&json!({"op":"snapshot"})) {
                Ok(mut state) => {
                    if enabled {
                        let apps = state["apps"].as_array().cloned().unwrap_or_default();
                        let active: BTreeSet<String> = apps
                            .iter()
                            .filter_map(|a| a["id"].as_str().map(String::from))
                            .collect();
                        attempted.retain(|key| active.contains(key));
                        for a in apps {
                            let Some(key) = a["id"].as_str() else {
                                continue;
                            };
                            // Failed/stale sessions require an explicit retry, not an endless restart loop.
                            if !attempted.contains(key)
                                && a["controllable"] == true
                                && a["error"].is_null()
                            {
                                if let Some(rule) = prefs.rules.get(key) {
                                    attempted.insert(key.into());
                                    if let Err(e)=native.execute(&json!({"op":"app_control","appId":key,"volume":rule.volume,"muted":rule.muted})) {let _=app.emit_to("mixer","audio-error",e);}
                                }
                            }
                        }
                        if let Ok(next) = native.execute(&json!({"op":"snapshot"})) {
                            state = next;
                        }
                    }
                    revision += 1;
                    let _ = app.emit_to(
                        "mixer",
                        "audio-state-changed",
                        enrich(state, &prefs, enabled, &config_error, &instance, revision),
                    );
                }
                Err(e) => {
                    let _ = app.emit_to("mixer", "audio-error", e);
                }
            }
        }
    }
}

/// Explicit diagnostic, never called during normal startup. Emits numeric metrics only.
pub fn probe_mix(app_id: &str) {
    let result = (|| -> Result<(), String> {
        let mut native = native::Native::new()?;
        for (stage, volume, muted) in [
            ("quarter", 0.25, false),
            ("mute", 0.25, true),
            ("half", 0.5, false),
        ] {
            native.execute(
                &json!({"op":"app_control","appId":app_id,"volume":volume,"muted":muted}),
            )?;
            for _ in 0..4 {
                std::thread::sleep(Duration::from_millis(250));
                let state = native.execute(&json!({"op":"snapshot"}))?;
                let application = state["apps"]
                    .as_array()
                    .and_then(|apps| apps.iter().find(|a| a["id"] == app_id))
                    .ok_or("Test application stopped playing")?;
                println!("{}", json!({"stage":stage,"app":application}));
            }
        }
        let restored = native.execute(&json!({"op":"shutdown"}))?;
        println!("{}", json!({"stage":"restored","result":restored}));
        Ok(())
    })();
    if let Err(error) = result {
        eprintln!("{error}");
        std::process::exit(1);
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn rejects_invalid_control_before_native_side_effects() {
        for request in [
            json!({"op":"app_control","appId":"music","volume":0.4,"muted":1}),
            json!({"op":"app_control","appId":"music","volume":1.2,"muted":false}),
            json!({"op":"device_volume","uid":"speaker","direction":"bad","volume":0.5}),
            json!({"op":"device_volume","uid":"","direction":"output","volume":0.5}),
            json!({"op":"shell"}),
        ] {
            assert!(validate_request(&request).is_err());
        }
        assert!(validate_request(
            &json!({"op":"app_control","appId":"music","volume":0.0,"muted":false})
        )
        .is_ok());
    }
    #[test]
    fn preserves_volume_and_mute_rules_across_config_roundtrip() {
        let input = br#"{"schemaVersion":1,"rules":{"music":{"volume":0.35,"muted":true}}}"#;
        let preferences = parse_preferences(input).unwrap();
        let restored = parse_preferences(&serde_json::to_vec(&preferences).unwrap()).unwrap();
        assert_eq!(restored.rules["music"].volume, 0.35);
        assert!(restored.rules["music"].muted);
        assert!(parse_preferences(br#"{"schemaVersion":999,"rules":{}}"#).is_err());
        assert!(parse_preferences(
            br#"{"schemaVersion":1,"rules":{"music":{"volume":-0.2,"muted":false}}}"#
        )
        .is_err());
    }
    #[test]
    fn config_write_replaces_existing_file_and_leaves_no_partial_file() {
        let directory = std::env::temp_dir().join(format!(
            "mvm-test-{}-{}",
            std::process::id(),
            std::time::SystemTime::now()
                .duration_since(std::time::UNIX_EPOCH)
                .unwrap()
                .as_nanos()
        ));
        let path = directory.join("preferences.json");
        let mut preferences = Preferences::default();
        save(&path, &preferences).unwrap();
        preferences.rules.insert(
            "music".into(),
            Rule {
                volume: 0.25,
                muted: false,
            },
        );
        save(&path, &preferences).unwrap();
        assert_eq!(
            parse_preferences(&fs::read(&path).unwrap()).unwrap().rules["music"].volume,
            0.25
        );
        assert!(!path.with_extension("tmp").exists());
        fs::remove_dir_all(directory).unwrap();
    }
}
