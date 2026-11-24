# Antigravity Mobile（Levity 风格安卓互通端）

将 macOS 上的 **Google Antigravity** 延伸到 Android 手机的远程控制台与随身 Agent 客户端：
- **Mac 端 `bridge/`（Go 单二进制）**：只读读取 `conversation_summaries.db`（含子代理统计与原生 FTS5 搜索）、增量监听 `brain/` 会话流与产物、双模 `5h/7d` 配额监控与校准、安全白名单预览本地 `file:///` 文件、调用官方 `bin/agentapi` 发送指令/新建会话。
- **Android 端 `app/`（Flutter + Kotlin 原生层）**：深色流光毛玻璃 UI、局域网/Tailscale 多路竞速直连与 RTT 显示、可折叠配额仪表盘、思考/工具过程自动折叠、原生产物/图片预览、单手盲操气泡，以及 Android 前台保活服务与通知栏 `RemoteInput` 直接回复。

---

## 1. 启动 Mac 端桥接服务

```bash
cd bridge
GOPROXY=https://goproxy.cn,direct GOTOOLCHAIN=local go build -o bin/agy-bridge ./cmd/agy-bridge

# 检查本机 Antigravity 状态与当前配额快照
./bin/agy-bridge status

# 启动守护进程并打印终端配对二维码（自动探测局域网 + Tailscale IP）
./bin/agy-bridge serve
```

> 首次启动会自动在 `~/.config/antigravity-mobile/config.json` 生成随机 Bearer Token，并在 `~/.config/antigravity-mobile/bridge_state.db` 独立维护置顶/已读游标与配额账本，绝不改写 Antigravity 原生库。

---

## 2. 编译与安装 Android APK

如果本机尚未配置 Android SDK，可先安装命令行工具并配置 `ANDROID_HOME`：

```bash
brew install --cask android-commandlinetools
export ANDROID_HOME=/opt/homebrew/share/android-commandlinetools
sdkmanager "platform-tools" "platforms;android-35" "build-tools;35.0.0"
```

构建并安装到真机：

```bash
cd app
PUB_HOSTED_URL=https://pub.flutter-io.cn \
FLUTTER_STORAGE_BASE_URL=https://storage.flutter-io.cn \
flutter --no-version-check build apk --release

# 通过 adb 安装到已连接的小米/安卓手机
adb install -r build/app/outputs/flutter-apk/app-release.apk
```

---

## 3. 小米 HyperOS 后台保活建议

1. 扫码配对后，App 会自动请求通知权限并启动极低干扰的常驻连接通知。
2. 在 App 内进入「主机连接与配对 → 小米/安卓防杀后台设置」，将本应用设为**无限制省电策略**并允许**自启动**，即可在锁屏状态下即时收到 Agent 决策提醒，并直接在通知栏输入回复或一键确认开工。

---

## 4. 运行自动化测试

```bash
# Go 桥接端单测
cd bridge && GOTOOLCHAIN=local go test -v ./...

# 纯 Dart 协议包单测
cd app/packages/agy_client && dart test

# Flutter 静态分析与 Widget 测试
cd app && flutter --no-version-check analyze && flutter --no-version-check test
```
