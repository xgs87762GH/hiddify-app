# AGENTS — 给 AI 协作者的硬约束

本文件对本仓库的任何 AI 协作者（Claude、CodeBuddy、Cursor 等）生效，优先级高于任务描述。
上游官方的 `CLAUDE.md` 仍然有效，本文件只补充本仓库（fork）的工作纪律。

## 一、分支纪律（最重要）

- **`main` 永远等于官方**，不承载任何本地改动。它存在的唯一意义是干净地跟踪 `upstream`，用来随时合入官方更新。
- **任何改动都发生在功能分支上**，命名 `feat/<topic>`、`fix/<topic>`、`chore/<topic>`。当前主分支：`feat/ui-layout-and-fixes`。
- **禁止向 `main` 提交、禁止 push `upstream`**（upstream 的 push 已禁用，不要再尝试开启）。
- 官方更新只按快进合并，不产生合并提交、不产生分叉：

```powershell
git fetch upstream
git switch main
git merge --ff-only upstream/main
git push origin main
```

- 功能分支落后官方时，用 `git rebase upstream/main` 对齐，不要 merge 官方进功能分支。

## 二、禁止删除与禁止造成紊乱

- **不删代码。** 任何"看起来没用"的代码先问，不自己判断删。确实要删时，单独提交，message 写清理由。
- **不大范围重写。** 单次改动聚焦一个主题；需要重构时先说明计划再动手。
- **不制造注释掉的代码。** 删除即删除，git 历史是这些内容的唯一去处。
- **不动生成物：** `lib/gen/`（slang）、`.dart_tool/`、`build/`、`*.g.dart`、`windows|linux|macos/flutter/generated_*`。需要重新生成时用工具（`dart run slang`、`dart run build_runner build`），不要手改。
- **不动 `pubspec.yaml` 的 `dependency_overrides: build_config ^1.4.0`**，删掉 build_runner 会起不来。
- **`hiddify-core` 子模块**由 `D:\env\...` 的 Go 工具链构建，`go.mod`/`go.sum` 的改动只在有明确任务时提交。
- **提交前必跑**：`flutter analyze`（0 issue）与 `flutter test`（全绿）。只报成功，不报跳过。
- **StreamProvider 没有 `.future` 可等**：`connectionNotifierProvider` / `activeProxyNotifierProvider` / `proxiesOverviewNotifierProvider` 的 build 返回 Stream，`.future` 等的是**首个事件**，冷启动时 core 刚起来、事件秒级后才到。要当前值用 `valueOrNull`，要持续同步用 `ref.listen`；`fireImmediately` 的回调若在 build 里 `ref.read` 其他 provider，会触发 riverpod 的 `Concurrent modification during iteration`，首次渲染用 `Future.microtask` 挪出 build。
- **升级 Flutter/Dart SDK 后先 `flutter clean`**，否则缓存的旧版 Impeller shader 会让测试报 `Unsupported runtime stages format version`。

## 三、提交规范

- 英文 Conventional Commits：`type(scope): summary`，type 用 `feat|fix|perf|chore|test|refactor`。
- 按主题拆成多个提交；一个提交只做一件事，message 解释"为什么"，不逐行复述 diff。
- 翻译类改动按 `CLAUDE.md` 的规则：`en` 单独提交，其余语言随后。
- 推送只推到 `origin` 的功能分支，命令用 SSH；HTTPS 走不通时加 `-c http.proxy= -c https.proxy=` 绕过代理（Hiddify 自带的 `127.0.0.1:12334` 会让 GitHub TLS 失败）。

## 四、环境要点

- Flutter 3.41.9 / Dart 3.11.5，路径 `D:\env\sdk\flutter`（旧版备份 `D:\env\sdk\flutter-3.38.10-bak`，确认稳定后删除）。
- 另一台开发机在 `F:\DevelopObject\MyProject\hiddify-app`，工具链在 `D:\DevelopEnv`；两台 SDK 版本必须保持一致，否则 `pubspec.lock` 会出现假差异。
- 中文路径会让分析服务崩溃，跑 analyze / dart 命令时用 ASCII 路径（如 `C:\hiddify-app`）。
- **`flutter clean` 会删 `build/windows/x64/_deps/sentry-native-src`**，之后 CMake 重新 clone sentry-native 的子模块时 `chromium.googlesource.com` 不可达，构建报 `Unable to generate build files`。恢复方式：从 `https://codeload.github.com/getsentry/sentry-native/tar.gz/refs/tags/0.7.20` 下载源码解压到该目录（`codeload.github.com` 可达，`github.com` 主站和 SSH 均被间歇阻断，ghproxy 镜像证书过期），然后带 `HIDDIFY_SENTRY_NATIVE_SOURCE=<该目录>` 与 `SENTRY_NATIVE_BACKEND=none` 构建。pub cache 里 sentry_flutter 包的 `sentry-native.cmake` 已被 patch 以支持该变量；`pub upgrade` 若重装 sentry_flutter，需要重新打这个补丁。
- **不要 `flutter clean` 后用默认方式构建**：clean 只删 `build/`，上面的 sentry 源码树必须重新准备。
- Windows 打包：`fastforge package --platform windows --targets exe|msix`，需把 flutter bin 加进 `PATH`、设 `INNO_SETUP_PATH`；MSIX 用自签证书 `CN=Hiddify-Test`（密码 1234，`windows/sign.pfx`，已 gitignore）。打包前必须 `taskkill /F /IM Hiddify.exe`。
- **`windows/packaging/msix/make_config.yaml` 被 .gitignore 排除**（含证书密码），换机后需重新配置：版本号 `msix_version` 与 pubspec 手工同步，并且必须加 `signtool_options: /f windows\sign.pfx /p 1234 /fd SHA256`——msix 工具默认走 `http://timestamp.digicert.com` 时间戳，该地址不可达时整个 MSIX 打包失败在签名一步。
- 版本号在 `pubspec.yaml`（`5.0.2+50002`），MSIX 版本由 `.github/change_version.sh` 同步，不要手改 `make_config.yaml` 里的 `msix_version`。
- **本机（Windows）只能产出 Windows 与 Web 两种包**：Windows 用 fastforge（exe / msix），Web 用 `flutter build web --release` 后把 `build/web` 压成 zip（约 19MB，构建时会报 wasm dry-run 与 `CupertinoIcons` 字体缺失警告，均为既有现象，不影响产物）。
- **Android 在本机不具备构建条件**：`compileSdkVersion 36` / `targetSdkVersion 36` / `ndkVersion 28.2.13676358`，而本机只有 `platforms;android-34`、`build-tools;34.0.0`、`ndk;26.1.10909125`；且 `android/app/libs` 只有 `.gitkeep`——Go 内核的 `libcore.aar` 由外部（hiddify-core 发布产物）提供，缺失时打出的 APK 能装但启动即崩，不要在本地产出这种包。要补的话需装 SDK 36 / build-tools 36 / NDK 28（`dl.google.com` 需可达）并放入内核 AAR，或交给 CI。
- macOS / iOS / Linux 桌面包必须在对应宿主机上构建（Linux 桌面虽已开 feature flag，但 Windows 上没有 clang/GTK 工具链）。

## 五、当前状态速查（更新于 2026-10-23）

- 主分支：`feat/ui-layout-and-fixes`，已推送；`main` 与官方 `4b99aa68` 一致。
- 应用版本 5.0.2+50002；安装包在 `dist/`（setup.exe / msix / windows zip / web zip）。
- 已知遗留：代理列表测速节流 300ms（改它要同步改 `proxies_overview_notifier_test.dart` 的 pump 时长）；`hiddify-core.dll` 86MB 未做裁剪；UI 测试已覆盖 `AppLayout`、首页两栏、代理网格列数。
