# Antigravity Mobile（`agy-remote` 原生插件 + Levity 安卓端）

将 macOS 上的 **Google Antigravity** 以**原生插件形式**延伸到 Android 手机的远程控制台与随身 Agent 客户端：
- **Mac 端 Antigravity 原生插件 `agy-remote`（`plugin/` + `bridge/`）**：
  - **自动托管 Sidecar + Aux Pane 面板**：启用插件自动后台运行，在 Antigravity 右侧边栏直接打开扫码配对二维码、查看在线手机数与 `5h/7d` 配额、一键测试通知与重置密钥。
  - **Lifecycle Hooks 零延迟提醒**：挂载 `Stop` 与 `PostToolUse(ask_question)`，Agent 完成或提问时 <50ms 推送到手机。
  - **内置 MCP 工具**：暴露 `agy_remote_status`、`agy_remote_pairing_info`、`agy_remote_notify_mobile`，让 Agent 或定时任务主动给手机发消息。
  - **核心数据能力**：只读查询 `conversation_summaries.db`（子代理计数 + FTS5 全文搜索）、增量监听 `brain/` 会话与 Artifacts、双模 `5h/7d` 配额监控、安全白名单预览本地 `file:///` 文件、调用官方 `agentapi` 发送指令。
- **Android 端 `app/`（Flutter + Kotlin 原生层）**：深色流光毛玻璃 UI、局域网/Tailscale 多路竞速直连、可折叠配额仪表盘、思考/工具折叠、原生产物/图片预览、单手盲操悬浮球，以及前台保活与通知栏 `RemoteInput` 直接回复。

---

## 1. 一键安装 Mac 端 Antigravity 插件 `agy-remote`

```bash
cd /Users/apple/go-project/ai/antigravity-mobile
./scripts/install-plugin.sh
```

安装完成后，插件位于 `~/.gemini/config/plugins/agy-remote/`：
1. 在 Antigravity 插件页即可看到并一键开关 **`agy-remote`**（无需手动开终端运行服务）。
2. 打开右侧边栏 **`agy-remote`** 面板即可直接用安卓 App 扫描屏幕上的二维码完成配对。
3. 如需脱离 Antigravity 单独命令行调试，仍支持：`~/.gemini/config/plugins/agy-remote/bin/agy-remote serve | pair | status`。

---

## 2. 编译与安装 Android APK

```bash
cd /Users/apple/go-project/ai/antigravity-mobile/app
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home \
ANDROID_HOME=/opt/homebrew/share/android-sdk \
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter --no-version-check --suppress-analytics build apk --release --target-platform android-arm64

# 安装到 USB 调试连接的安卓手机
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## 3. 小米 HyperOS 后台保活建议

1. 扫码配对后，App 会自动请求通知权限并启动极低干扰的常驻连接通知。
2. 在 App 内进入「主机连接与配对 → 小米/安卓防杀后台设置」，将本应用设为**无限制省电策略**并允许**自启动**，即可在锁屏状态下即时收到 Agent 决策提醒，并直接在通知栏输入回复或一键确认开工。

---

## 4. 运行全栈测试

```bash
# Go 插件后端（含 Sidecar UI、MCP、Hook、配额、沙箱）
cd bridge && GOTOOLCHAIN=local go test -v ./...

# 纯 Dart 协议包
cd app/packages/agy_client && dart test

# Flutter 静态分析与 Widget 测试
cd app && flutter --no-version-check --suppress-analytics analyze && flutter --no-version-check --suppress-analytics test
```
