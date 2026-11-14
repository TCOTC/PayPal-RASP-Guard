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

## 自动发布（GitHub Actions）

`.github/workflows/release.yml`：推 `v*` tag 即自动构建并发布 Release，附 SHA-256 校验文件。

```bash
git tag v1.0.0
git push origin v1.0.0
```

也可在 Actions 页面手动触发并填写版本号。

**版本号由 tag 决定**：`v1.2.3` → `versionName=1.2.3`、`versionCode=10203`（`major*10000 + minor*100 + patch`）。工作流会改写 `app/AndroidManifest.xml`，仓库里的值只是本地默认，不必手动维护。tag 不符合 `vX.Y.Z` 会直接失败。

### 配置签名密钥（强烈建议）

不配置的话，CI 每次用临时生成的密钥签名，产物**无法覆盖升级**已安装的旧版本（LSPosed 也会把它当成另一个模块）。

```powershell
keytool -genkeypair -keystore release.keystore -alias raspguard `
  -keyalg RSA -keysize 2048 -validity 3650
[Convert]::ToBase64String([IO.File]::ReadAllBytes('release.keystore')) | Set-Clipboard
```

在仓库 **Settings → Secrets and variables → Actions** 里添加：

| Secret | 内容 |
|---|---|
| `KEYSTORE_BASE64` | 上一步复制出来的 base64 |
| `KEYSTORE_PASS` | keystore 口令 |
| `KEY_ALIAS` | `raspguard` |
| `KEY_PASS` | key 口令（一般与 keystore 相同） |

`release.keystore` 不要提交（`*.keystore` 已在 `.gitignore` 中）。**这把密钥要长期保管**：一旦丢失，此后发布的版本都无法覆盖升级旧安装。

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

## 免责声明

**本项目与 PayPal Inc. 无任何关联，未获其授权。安装或使用前请完整阅读 [DISCLAIMER.md](DISCLAIMER.md)。**

- 本组件**关闭的是目标应用的一项安全机制**，可能降低账户欺诈防护能力，并可能导致账户被限制
- 修改或干扰支付类客户端通常被其**用户协议禁止**
- 不同地区对"绕过技术保护措施"有不同规定，**合法性由使用者自行确认**
- 需要已 root 的设备与 LSPosed；这类环境本身即降低设备整体安全性
- 按"现状"提供，不附带任何担保；数据、设备、账户或资金损失由使用者自行承担
- 仅限在你自己拥有并承担风险的设备上、用于个人正当用途

如果你不同意上述任何一条，请不要安装或使用。

## 许可证

已放弃版权，释入**公有领域**（[The Unlicense](LICENSE)）。可自由复制、修改、分发、商用，无需署名。

说明：部分司法辖区（含中国大陆）不允许完全放弃著作人身权，Unlicense 为此提供了回退授权 —— 在这些地区等同于授予无限制、不可撤销的使用许可。

## 更新记录

- **1.0.0** — 首版。替换默认未捕获异常处理器，吞掉 RASP 自毁异常；PayPal 10.20.1 启动正常。
