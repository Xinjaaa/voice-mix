fn main() {
    if std::env::var("CARGO_CFG_TARGET_OS").as_deref() == Ok("macos") {
        cc::Build::new()
            .cpp(true)
            .file("../native/macos/audio.mm")
            .flag("-std=c++17")
            .flag("-fobjc-arc")
            .flag("-mmacosx-version-min=14.4")
            .flag("-Wno-deprecated-declarations")
            .compile("mvm_audio");
        for framework in ["CoreAudio", "Foundation", "AppKit", "AudioToolbox"] {
            println!("cargo:rustc-link-lib=framework={framework}");
        }
        println!("cargo:rerun-if-changed=../native/macos");
    }
    tauri_build::try_build(tauri_build::Attributes::new().app_manifest(
        tauri_build::AppManifest::new().commands(&["audio_request", "quit_app", "hide_panel"]),
    ))
    .expect("Tauri build configuration is invalid");
}
