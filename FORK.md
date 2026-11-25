# FORK.md — 本仓库相对 upstream 的差异

本仓库跟踪 [vinzdg/codenotch](https://github.com/vinzdg/codenotch)（**upstream**），
在它之上只保留三类改动：

1. 让 App 仍能在 **macOS 14.3 + Xcode 15.4** 上编译和运行，同时不夺走 upstream
   在 macOS 15 / 26 上的原生表现；
2. **XyToken** provider（fork 独有功能）；
3. 关闭 Sparkle 更新，并给出一个 ad-hoc 签名、可分发给朋友的 universal 包。

写入时的基线：`upstream/main = 8d27091`（`v1.26.0`，`CURRENT_PROJECT_VERSION` 28）。
这份文档只记**现在为什么这样写**和**下次同步时怎么判断**。

## 目录

- [同步 upstream](#同步-upstream)
- [1. macOS 14.3 兼容层](#1-macos-143-兼容层)
- [2. XyToken provider](#2-xytoken-provider)
- [3. 关闭 Sparkle 更新](#3-关闭-sparkle-更新)
- [4. ad-hoc 构建、分发包与 CI](#4-ad-hoc-构建分发包与-ci)
- [明确不带入的改动](#明确不带入的改动)
- [验证基线](#验证基线)

## 同步 upstream

```sh
git fetch upstream
git branch -f backup/pre-rebase-<版本> main
git rebase --onto upstream/main <fork基点> main
```

`<fork基点>` 是上一次同步后的 upstream 顶点。上游有过一次重写全部历史
（1.10.0 → 1.11.0），当时 `git merge-base` 为空，只能按 tree 对应关系找回基点；
1.11.0 之后每次都正常，`git merge-base main upstream/main` 有值就直接 rebase。

同步时按下面的顺序处理，顺序本身有原因：

1. **先解冲突**。冲突集中在 `project.yml`、`Sources/App/AppDelegate.swift`、
   `Sources/Providers/Sites.swift`、`Sources/Providers/WebSessionProvider.swift`。
   provider 列表一律「两边都留」，本地只追加 `xytoken`。
2. **再找新的系统 API**（第 1 节的 grep）与新的玻璃测试门禁（第 1 节末）。
3. **然后真的编译一次**。只靠读代码会漏掉「上游新增文件 / 非冲突区段」里的
   新 API 与 Swift 5.10 并发限制，它们只在编译期暴露。

## 1. macOS 14.3 兼容层

**为什么存在**：upstream 的部署目标是 15.0，代码直接用 macOS 26 才有的 API
（`glassEffect`、`pointerStyle`），1.26.0 起还有 macOS 15 的 `onGeometryChange`。
这些符号在旧 SDK 里**根本不存在**，`#available` 救不了，编译器连名字都看不到。
本机是 macOS 14.3 + Xcode 15.4，所以必须换掉调用点。

**涉及文件**

- `project.yml`：`deploymentTarget: 14.3`、`projectFormat: xcode15_0`、
  SwiftNIO `from: "2.86.0"`（2.87.0 起要求 Swift 6.1 tools，5.10 解析不了；
  SwiftPM 会跳过读不懂的版本，最终落在 2.86.2）
- `Package.resolved`：与上面的 pin 配套的解析结果
- `Sources/Compatibility/MacOS26Shims.swift`：`compatGlassEffect(_:in:interactive:slab:)`、
  `compatGlassBackground(_:in:)`、`compatPointerStyle(active:)`、`compatOnGeometryChange(for:_:action:)`
- `Sources/Settings/NotchSurfaceStyle.swift`：`glass` / `slabGlass` 连同文档整段在
  `#if compiler(>=6.2)` 里
- 调用点：`MoveHandle`、`SettingsHandle`(2)、`TooltipCard`、`UsageResetCard`、
  `UpdateCard`、`NotchRootView`(2 个 glass + 1 个 geometry)、`SettingsView`
  （`glassBackground(in:)` 与 `AccountRow` 的指针）
- `Swift 5.10 编译修正`：`AppDelegate`（provider 链拆成 `+=`、`weak store` 外层绑定）、
  `NotchRootView`（`bezelAnchor` 外层绑定、`cells` 拆成两级 `@ViewBuilder`）、
  `KreaUsage`（`??` 长链换逐键循环）、`ManualProvider`（`nonisolated(unsafe) onChanged`）、
  `PhoneLinkServer` / `GrokActivityMonitor` / `LMStudioMetrics` / `OMLXMetrics`
  （嵌套并发闭包里的 `weak self`）、`ClaudeTokenRefresher`（`nonisolated run`）、
  `ApifyUsage`（`en_US_POSIX` 下补 `groupingSize = 3`）
- 测试侧：`ClaudeOAuthProviderTests` / `ManualProviderTests` / `RemoteHostsTests`
  捕获的 `var` 换 `final class Box`；`MiniMaxUsageTests` / `OpenCodeUsageTests`
  显式 `TimeInterval(...)`；`NotchLayoutTests` 的玻璃断言进同一个 `#if`

**`compiler(>=6.2)`，不是 `swift(>=6.2)`。** 这一条踩过：`swift(>=6.2)` 判断的是
**语言模式**，而 `project.yml` 钉了 `SWIFT_VERSION: "5.0"`，所以它在 Xcode 26 上
也是假的。写错时后果很隐蔽：macOS 26 的 CI 全绿，但原生 Glass 与
`onGeometryChange` 分支根本没被编译，交付的包在 macOS 26 上仍是兼容材质。
`compiler(...)` 才是「这个编译器有没有那套 SDK」。

**两处不同形状，别合并。** upstream 多数调用点直接修饰视图
（`view.glassEffect(style.glass, in: shape)`），`SettingsView.glassBackground(in:)`
却是 `background { Color.clear.glassEffect(.regular, in: shape) }`。玻璃不是背景，
它是折射 `self` 后面的内容，所以 shim 分开两件：`compatGlassEffect` 修饰 `self`，
`compatGlassBackground` 保留 background 形状。合并成 background 会让 Xcode 26 的
构建与 upstream 长得不一样。

**旧 SDK 的替代实现**：`#if compiler(>=6.2)` 之内仍有 `if #available(macOS 26, *)`，
新工具链编译真修饰符、运行时再判系统；旧工具链整段看不到符号，用
`.regularMaterial`（与视图同形状）、`NSCursor` hover、background `GeometryReader`
顶上。geometry 的报告推到下一个 run loop，否则在 layout 期间写 model 会报
「Modifying state during view update」。

**同步时怎么找漏网点**

```sh
grep -rn 'glassEffect\|pointerStyle\|onGeometryChange' Sources/ \
  | grep -v 'Compatibility/MacOS26Shims.swift'
```

只应剩下注释。上游新增调用点会**编译失败**，而不是冲突：
删掉 `if #available` 包装，换成 `compat*` 调用，并且**不要在调用点写 `Glass`**
（那个类型只允许出现在 shim 里，且只在 `#if` 内）。

**新 API 不一定是 26 的。** `onGeometryChange` 是 macOS **15** 的，
老的「macOS 26 清单」一条都没覆盖到它。下次先查 API 的最低系统版本。

**玻璃测试门禁**：`NotchRenderTests.testTheFoldedPillIsTransparentInTheGlassStyle`
与 `UsageBandTests.PaletteAppearanceTests` 的三个对比度测试都断言 Liquid Glass 的
取值；macOS 26 以下 `.glass` 解析成 `.solid`，断言不可能成立，所以各加
`try XCTSkipUnless(NotchSurfaceStyle.glassAvailable, …)`。这是**测试适配不是决策**：
上游哪天自己加了门禁，本地这几行就该删。

`Tests/NotchRenderTests.swift` 里 `EdgeCrossfadeTests` 有一处「按面板中点反推屏幕」
的修正：上游在那里重新调 `NotchGeometry.preferredScreen(from:)`（走 `NSScreen.main`），
而无窗口的测试宿主里 `NSScreen.main` 不稳定，接了外接屏就会拿错屏幕。
判据：上游不再依赖 `NSScreen.main` 那天，这处就该删。

## 2. XyToken provider

**为什么存在**：XyToken 的用量在网页会话里，refresh cookie 是 HttpOnly 且每次调用
都轮换，所以「刷新 + 查询」必须在 App 自己的 WKWebView 里带着用户登录态跑。

**涉及文件**

- `Sources/Providers/Sites.swift`：`static let xytoken`
- `Sources/Providers/XyTokenUsage.swift`、`Tests/XyTokenUsageTests.swift`
- `Sources/Providers/WebSessionProvider.swift`：`mfaCodes`、`stepUpCode`、
  拒绝行带 `request=`/body、`session ->` 行、`isLoaded = false`、`logsResponseBody`
- `Sources/App/AppDelegate.swift`：构造、`webProviders`、`signInItems`、`onAuthenticated`
- `Tests/WebSessionSignInTests.swift`：`xytoken.signedIn` 经 upstream `account()` 成为账号

**要点**（细节看代码注释，这里只记容易搞错的）：

- **窗口 id 是 `rule_key` 里 `|` 之前的稳定半段**（`day:1` / `week:1`）。`|` 之后是
  重置排程，会随重置日变；拿整串当 id 会让周环突然消失。`headlineID: "day:1"`、
  `weeklyID: "week:1"` 就是这么来的，由
  `testSiteWindowRolesResolveToTheParsedWindows` 钉住。
- **周期长度取自 limit 自己的 `period_value` / `period_unit`**，不是
  `window_end - window_start`：实测两个窗口的 `window_start` 相同，日窗口的跨度
  正好是「距午夜的剩余时间」，那是请求时刻而不是周期起点。
- **登录探针要求整包**（`access_token` + `user` + `session`），与站台前端的
  `isAuthBundle` 一致。只看 `session.sid` 会把还没输验证码的会话判成已登录，
  窗口随即关闭（2026-10-29 的真实故障）。
- **`403 ADMIN_MFA_REQUIRED` 不是掉线**，是站台在等二次验证；它被写成
  `needsMfa:` 而不是 `needsAuth:`，行为不变（`.needsAuth` 正是打开验证窗的入口）。
- **refresh 按站台契约轮换**：记住 `session.sid` 并在后续刷新带
  `X-Auth-Session`；`409 AUTH_REFRESH_RACE` 隔 150ms 重试一次，
  `409 AUTH_SESSION_MISMATCH` 丢掉 sid 退回 bootstrap。
- **`request=` 是排障的第一手证据**：站台自己的请求日志能按 `X-Request-Id` 查到。

**同步时怎么判断**：upstream 也在加 `WebSessionProvider` 站点（DeepSeek、MiniMax、
QianwenAI、Qoder、MiMo），冲突时两边都留。`webProviders` / `signInItems` 只追加
`xytoken`，顺序取 upstream 的——1.26.0 的结果是
`[qianwen, mimo, qoder, xytoken]` 与 `[deepSeek, miniMaxWeb, qianwen, mimo, qoder, xytoken]`。

**外观配置同步规则**：设置里有一批开关要么按 provider 声明的窗口角色解析，要么
要求窗口自带 `duration` / `resetsAt`。上游新增这类开关时，回来确认 xytoken 是否
也要声明。依赖 `weeklyID` 的（每周圆环、虚线周环、圆环读数含每周、每周作为主环、
周限额提醒）与依赖「窗口是否到顶」的（`shutRingsWhenSpent`、`hideDepletedAccounts`）
都已经满足；菜单栏那条对 xytoken **结构性不适用**
（`StatusItemSummary.canSummarise` 只收五小时窗口或 Claude/Codex 家族）。

**已知取舍**：fork 当前**不做**「息屏时暂停抓取」。网页会话在系统挂起前几秒轮换
cookie，可能被站台判成 replay 而撤销会话；这个风险是本轮主动接受的，
不要在别处再补一套半成品保护。

## 3. 关闭 Sparkle 更新

**为什么存在**：这是本地定制构建，不能被 upstream 的 appcast 静默替换掉。

**涉及文件**：`project.yml` 与生成出来的 `Sources/Info.plist`

- `SUFeedURL: ""`
- `SUEnableAutomaticChecks: false`
- `SUAutomaticallyUpdate` 保持 upstream 自己的 `false`，不必再改

**同步时怎么判断**：`SU*` 上游若仍是有地址 + 自动检查 true，本地就继续空 + false。
`Sources/Info.plist` 是 `make gen` 从 `project.yml` 生成的，**改那边**，不要手改生成物。
代价要记住：1.19.0 起 upstream 那套「新版本在 notch 里问」在 fork 里完全不可达，
红点、Update/Later、安装进度都是死代码。这是意图，不是 bug。

## 4. ad-hoc 构建、分发包与 CI

**为什么存在**：本机钥匙串里没有签名证书，所有构建都是 ad-hoc。ad-hoc 下 Xcode 会用
**带 hardened runtime** 的 ad-hoc 签名给 App 签名，而旁边的 Sparkle 框架也是 ad-hoc、
没有 Team ID，dyld 因此拒绝加载（`Library not loaded: @rpath/Sparkle.framework`）。
这个失败在构建期与 `codesign --verify` 期都看不出来，**只在启动那一刻出现**。

**涉及文件**

- `Makefile`：`DEV_SIGN` 三段分支（Developer ID → Apple Development → ad-hoc）、
  `define DEV_RESIGN`（构建后把 Sparkle 与 App 一次性重签）、`install`、
  `build-ci`（单次 universal）、`package-adhoc`（双架构检查 + `ditto` zip + sha256）
- `Scripts/install-app.sh`：构建 Release → 装到 `/Applications` → 回读版本与签名 →
  **确认进程真的起来**（只看 `.app` 存在不算成功）
- `.github/workflows/ci.yml`：macOS 26 上跑 `make test-ci`（唯一能编译
  `compiler(>=6.2)` 分支的地方）
- `.github/workflows/package.yml`：`make package-adhoc` → 上传 zip 与 sha256 作为
  workflow artifact，**不发布 Release**，`permissions: contents: read`

**为什么分发包必须在 macOS 26 上构建**：`compiler(>=6.2)` 的分支只有新 SDK 才编译。
Xcode 15.4 打出的包即使拿到 macOS 26 上跑，走的仍是兼容材质；只有云端
Xcode 26 产出的包才在 macOS 26 上使用原生 Liquid Glass。本机构建只用来验证兼容路径。

**为什么 `package-adhoc` 是一次构建**：`build-ci` 开头就 `rm -rf build/ci`，
分两次单架构构建会删掉第一次的产物；而且只改 `-destination` 不会产生 fat binary。
真正的开关是 `ARCHS="arm64 x86_64" ONLY_ACTIVE_ARCH=NO` 加 `generic/platform=macOS`。
写完 zip 前检查主 executable **和** Sparkle 的 `lipo -archs`，任何一项缺片就删掉
zip 并失败——存在一个 zip 就会有人把它发给朋友。

**朋友怎么打开**：ad-hoc 未公证，macOS 会隔离下载文件。拖到 `/Applications` 后执行
`xattr -dr com.apple.quarantine /Applications/Codenotch.app`。没有更新通道，
新版本要重新下载。Intel 半边是同一份 universal binary，但本机无法实机验证。

## 明确不带入的改动

这些在旧 fork 里存在，本轮按用户确认的范围**没有**带进新版。同步时不要"顺手"抄回来：

- **Kimi OAuth token 自主续期**（`KimiTokenRefresher`、`KimiCredentials` 相关改动与测试）：
  恢复 upstream 原样。
- **通用浏览器会话登录提示重构**（`UsageStore.needsSignIn`、`ProviderAccount.needsSignIn`、
  `SettingsView.needsSetup` 与 `ProviderSummaryTests`）：XyToken 不需要它，upstream 的
  `WebSessionProvider.account()` 已经按 `<id>.signedIn` 返回账号。
- **息屏暂停抓取**（`UsageStore.displayIsAsleep` 与 `OllamaTests` 的注入）：见第 2 节末尾的取舍。

## 验证基线

本机（macOS 14.3 / arm64 / Xcode 15.4）：

```sh
make build                # 期望 ** BUILD SUCCEEDED **
make test                 # 期望 0 failures
Scripts/install-app.sh    # 装到 /Applications，并确认进程起来
```

- 旧 fork 在 1.26.0 上的记录是 2884 个测试、2859 通过、25 跳过、0 失败。
  测试总数会随 upstream 增长，**要盯的是 0 failures**；跳过数受
  `FullScreenAutoFoldTests.skipIfPointerOnNotch`（指针停在 notch 区域时跳过 8 个）影响。
- 跳过构成的常见来源：opt-in live check、macOS 26 以下的玻璃/dock 渲染与对比度断言。
- 本机沙箱里 `make test` 会停在 `-10822`（测试宿主需要 LaunchServices），要到普通终端跑。
  编译与 `build-for-testing` 在沙箱内可以跑绿。

云端（GitHub `macos-26` / Xcode 26）：CI 跑 `make test-ci`，Package 跑
`make package-adhoc` 并核对双架构。**这两处才是 `compiler(>=6.2)` 分支的实测**。

手工冒烟：XyToken 登录、日/周窗口与重置时间、usage pace、MFA 流程、会话失效后的
重新登录。没有真实凭据时如实标注未实测，不要用单元测试冒充。
