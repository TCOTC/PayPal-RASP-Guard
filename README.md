# PayPal RASP Guard

一个 LSPosed / Xposed 模块，用来让 **Google Play 版 PayPal 在已 root 的设备上正常启动**，而不必降级版本、不必隐藏 root、不必改系统分区。

- 包名：`com.dsh.raspguard.paypal`
- 作用域：仅 `com.paypal.android.p2pmobile`
- 已实测：PayPal **10.20.1**（versionCode 1160090185）在 OnePlus PJF110 / Android 14 / KernelSU + LSPosed 环境下启动并停留在首页

---

## 问题

从 10.10.0 起，PayPal 的 RASP（运行时自我保护）会在启动阶段判定环境不可信，然后**主动制造一次未捕获异常**把进程弄死：

| 版本 | 自毁表现 |
|---|---|
| 10.10.0 / 10.12.0 | `RootDetectionSecurityException: Security policy violation: s=root`（`RaspCrashSchedulerModule`） |
| 10.19.0 / 10.20.1 | 伪装成 `OutOfMemoryError` 申请 550–965MB，或 `ArrayIndexOutOfBoundsException: index=-1` |
| 10.6.0 / 10.8.2 | 不触发，可正常启动 |

ART 收到未捕获异常后会调用 `Runtime.exit()`，整个进程退出 —— 用户看到的就是"点开闪退"。

值得注意的是 10.19/10.20 的形态：分配量每次随机（550–965MB）、发生在裸线程的混淆代码里，明显是**故意伪装成内存 bug** 以阻碍分析。它的类是 `RaspCrashSchedulerModule` —— 名字本身就是"崩溃调度器"。

本模块不去猜它检测了什么（root 痕迹、attestation、Xposed 框架……），而是**废掉它唯一的自杀手段**。

## 原理

接管进程的默认未捕获异常处理器：

```
默认行为:  未捕获异常 → ART 记录 FATAL → Runtime.exit() → 进程死
本模块:    未捕获异常 → 命中 RASP 特征 → 记录一行日志 → 不退出 → 进程存活
```

命中条件（见 `Hook.isRaspSelfDestruct`）：

- `OutOfMemoryError`（伪装形态之一）
- `IndexOutOfBoundsException`（伪装形态之二）
- 类名含 `rootdetection` / `rasp`
- 消息含 `s=root` / `security policy violation`

不命中的异常照常交给原处理器，不影响 App 的正常崩溃行为。

因为 PayPal 与 Datadog 会在启动过程中反复替换这个处理器，模块在 0 / 0.7 / 1.5 / 2.6 / 4 / 6 / 9 秒各重装一次。

## 它不做什么

- ❌ 不修改、不伪造 attestation —— 实测过，hook `setAttestationChallenge` / `setIsStrongBoxBacked` 完全不被调用，与本问题无关
- ❌ 不隐藏 root、不改 SELinux、不碰任何分区
- ❌ 不 patch APK、不改签名
- ❌ 不绕过服务端风控

## 环境要求

- 已 root（KernelSU / Magisk / APatch 任一）+ **LSPosed**（Zygisk 或 Riru 版）
- Android 8.0+（模块侧 minSdk 26）
- PayPal 装的是 Google Play 版本（签名必须是 `c7c62ea0…448072`，其余签名同理需为官方）

## 构建

不需要 Gradle。依赖 JDK（javac/keytool）+ Android SDK build-tools（aapt2/d8/zipalign/apksigner），脚本自动探测路径。

```powershell
# 构建
.\build.ps1

# 构建并直接安装到已连接设备
.\build.ps1 -Install

# 自定义工具链位置
.\build.ps1 -JdkHome 'C:\Program Files\Java\jdk-17' -SdkRoot 'C:\Android\Sdk'
```

产物：`build\PayPal-RASP-Guard-<version>.apk`

首次构建会在 `keystore\debug.keystore` 生成自签名密钥（已 gitignore）。**换机器构建会换签名**，覆盖安装前需先卸载。

## 安装与启用

```powershell
adb install -r build\PayPal-RASP-Guard-1.0.0.apk
```

然后在 LSPosed 管理器里：

1. 模块列表启用 **PayPal RASP Guard**
2. 确认作用域包含 `com.paypal.android.p2pmobile`（APK 内已声明 `xposedscope`，通常自动带上）
3. 强制停止 PayPal，重新打开

## 验证是否生效

LSPosed 日志（或 `adb shell su -c 'grep RASPGuard /data/adb/lspd/log/*'`）应出现：

```
[RASPGuard] loaded in com.paypal.android.p2pmobile
[RASPGuard] suppressed on Thread-37 [t+2600]: java.lang.ArrayIndexOutOfBoundsException: ...
```

只要出现 `suppressed` 且 App 还活着，就说明生效。每次冷启动大约会出现一条。

## 代价与风险

- **模块必须保持启用**，禁用/卸载后立刻恢复闪退
- 本质上是**关掉了一个支付 App 的自我保护**。这是使用者的取舍：风控服务端仍可能对某些操作有额外要求
- 只在 PayPal 进程内生效，不影响其他应用
- 已验证范围：启动 + 首页渲染。登录、转账等流程未逐一验证；若某步触发其他自毁路径，按同样思路扩展 `isRaspSelfDestruct` 即可

## 目录结构

```
app/                     模块本体
  AndroidManifest.xml    含 xposedmodule / xposedscope 声明
  assets/xposed_init     入口类声明（缺失会导致 LSPosed 不列出模块）
  res/values/arrays.xml  xposedscope 作用域数组
  src/.../Hook.java      实现
stubs/                   编译期用的 Xposed API 桩（不打包进 APK）
docs/findings.md         排查过程与证据
build.ps1                无需 Gradle 的构建脚本
```

## 更新记录

- **1.0.0** — 首版。替换默认未捕获异常处理器，吞掉 RASP 自毁异常；PayPal 10.20.1 启动正常。
