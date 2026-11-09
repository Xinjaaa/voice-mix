# Mac Voice Mix

基于 Tauri 2、React、TypeScript、Rust 和 Core Audio 的 macOS 音量控制应用。当前提供开发版本，音频后端仅实现 macOS。

## 已实现

- 默认及非默认输入/输出设备音量、支持设备的静音、默认设备切换。
- 菜单栏入口，关闭窗口后继续运行，托盘及设置页可恢复原声和退出。
- 正在播放的应用列表，独立音量、静音、规则保存与重启后的显式恢复。
- Process Tap、私有 aggregate device、实时平滑增益；100% 且未静音时恢复系统播放路径。
- 设备或进程变化、采样率变化和回调异常时尝试停止接管，提供重新应用规则操作。
- 明暗主题、键盘滑块控制、无权限或不支持设备的提示。

首版应用混音支持仅使用默认输出的双声道 float32 PCM。能够确认外层 app bundle 的辅助进程会聚合；无法确认所属应用的 WebKit 进程暂时禁用控制。蓝牙、AirPlay、多声道、自选输出路由尚未完成兼容性验收。

## 开发

项目提供 Makefile，运行 `make` 查看全部命令。常用操作：

```bash
make install          # 按锁文件安装依赖
make dev              # 启动真实桌面应用
make preview          # 浏览器界面预览，使用模拟数据
make verify           # 检查及测试，不播放声音或修改设备音量
make build            # 构建 release .app 和 .dmg
make open             # 打开已构建的 release 应用
make build-debug      # 构建 debug .app 和 .dmg
make open PROFILE=debug
```

`make test-native-write` 会短暂修改默认设备音量后恢复；`make probe-signal` 会播放低音量测试音并验证应用混音。这两个目标需要显式执行，不包含在 `make verify` 中。`make clean` 清理构建产物，保留依赖和用户设置。

需要 macOS 14.4+、Xcode/Command Line Tools、Node.js 22、pnpm 10 和 Rust 1.92+。当前构建验证平台为 Apple Silicon、macOS 26.6.2。

```bash
pnpm install --frozen-lockfile
pnpm tauri dev
```

`pnpm dev` 仅打开浏览器界面预览，使用模拟数据，不修改系统音频。真实设备与应用控制必须在 Tauri 桌面应用中运行。

## 使用

1. 启动应用，调整输出设备或麦克风设备音量；点击设备名称可切换默认设备。
2. 播放应用声音，再点击“启用应用混音”。首次实际调整应用音量会触发 macOS 音频录制权限请求。
3. 允许后调整各应用音量。应用内音量及系统设备音量仍共同影响实际播放。
4. 设置页可调节所有设备、重置应用规则、恢复所有原声或退出。
5. 重启后默认不自动捕获音频；点击启用混音后恢复已保存规则。设备音量不会被保存规则自动覆盖。

音频仅本机实时处理，不保存或上传。拒绝音频权限时仍可调节设备。权限在 macOS“系统设置 → 隐私与安全性”中管理，具体分组名称以系统版本为准。

## 构建

```bash
pnpm build:mac
```

输出 `.app` 和 `.dmg` 位于 `src-tauri/target/release/bundle/`。开发调试包使用：

```bash
pnpm tauri build --debug --bundles app,dmg
```

输出位于 `src-tauri/target/debug/bundle/`。当前没有配置 Developer ID 发布签名、公证或自动更新，属于本机开发包。

## 验证

```bash
pnpm typecheck
pnpm test
pnpm test:native
cargo fmt --manifest-path src-tauri/Cargo.toml --check
cargo clippy --manifest-path src-tauri/Cargo.toml --all-targets -- -D warnings
cargo test --manifest-path src-tauri/Cargo.toml
```

`pnpm test:native` 包含实际回调的确定性 PCM 测试及只读硬件枚举。可选 `bash scripts/test-native.sh --write-device` 对当前默认输入/输出音量短暂写入再恢复；请在合适的播放环境中运行。

真实应用信号诊断需已有音频播放，显式执行包内二进制：

```bash
"src-tauri/target/debug/bundle/macos/Mac Voice Mix.app/Contents/MacOS/mac-voice-mix" --probe-mix=path:/usr/bin/afplay
```

也可使用可重复的测试脚本自动播放低音量测试音：

```bash
python3 scripts/probe-signal.py "src-tauri/target/release/bundle/macos/Mac Voice Mix.app/Contents/MacOS/mac-voice-mix"
```

该命令将目标应用依次设为 25%、静音、50%，打印回调的数值指标后恢复原声，不修改规则配置。它只在传入诊断参数时执行。RMS 比例证明本产品回调处理后的信号，不能单独证明扬声器物理输出、延迟或所有第三方应用兼容性。

## 文档

- [产品需求](docs/product-and-technical-plan.md)
- [Tauri 技术方案](docs/tauri-technical-design.md)
- [实现与验证结果](docs/macos-implementation-status.md)
- [代码审查记录](docs/code-review-macos.md)
