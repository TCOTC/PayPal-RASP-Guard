# 排查记录

> 记录"PayPal 在已 root 设备上启动闪退"这一问题的定位过程与关键证据。便于日后复现或扩展。

## 设备与版本

- OnePlus PJF110 / ColorOS 国行 / Android 14（API 34）/ arm64-v8a
- 系统构建 2024-09-11（未更新），BL 已解锁（`verifiedbootstate=orange`）
- KernelSU + Zygisk Next 1.5.3 + LSPosed 2.2.1 + Vector 2.0
- PayPal 10.20.1（Play 版，签名 `c7c62ea0…448072`）

## 版本对照（实测）

| 版本 | versionCode | 结果 |
|---|---|---|
| 10.6.0 | 1160090132 | 可用 |
| 10.8.2 | 1160090157 | 可用 |
| 10.10.0 | 1160090162 | 崩：`RootDetectionSecurityException: s=root` |
| 10.12.0 | 1160090169 | 崩：同上 |
| 10.19.0 | 1160090180 | 崩：OOM / `index=-1` |
| 10.20.1 | 1160090185 | 崩：OOM / `index=-1` |

故障区间：10.8.2 之后、10.10.0 之前。

## 关键证据

### 1. 崩溃形态（10.20.1）

```
FATAL EXCEPTION: Thread-3x
java.lang.OutOfMemoryError: Failed to allocate a 719765280 byte allocation ...
    at o.g.Camera2StreamConfigurationMap(Unknown Source:95)
    at o.setAttachments.run(:1279)
```

或

```
java.lang.ArrayIndexOutOfBoundsException: length=121538394; index=-1
```

分配量每次不同（550/706/719/735/772/854/965 MB），进程 `growth limit` 仅 512MB：
**单次申请超过整个堆上限**，且与系统剩余内存无关（可用 4.2GB，swap 空闲 9.1GB）。

### 2. 方法名是伪造的

用 `kill -3` 导出 129 个线程的完整栈后可见：

```
EncryptionManagerImpl.getHighSpeedVideoFpsRanges(:477)
CoroutineScheduler$Worker.getHighSpeedVideoFpsRanges(:798)
DataStoreImpl$data$1.getHighSpeedVideoSizes(:567)
SntpServiceImpl.getHighSpeedVideoSizes(:151)
```

相机 API 的方法名被接到加密管理器、协程调度器、DataStore、NTP 客户端上 ——
商业壳的符号伪造手法，**不要按相机方向排查**。

### 3. 自毁机制

10.10/10.12 的栈直接点名：

```
com.paypal.oslo.app.rasp.RootDetectionSecurityException: Security policy violation: s=root
  at com.paypal.oslo.app.di.RaspCrashSchedulerModule.$r8$lambda$...
  at com.paypal.oslo.app.di.RaspCrashSchedulerModule$$ExternalSyntheticLambda0.run(:0)
```

`RaspCrashSchedulerModule` = "崩溃调度器"，即崩溃是**设计出来的**。

### 4. 排除项（均实测）

- **内存不足**：16GB 机型，可用 4.2GB
- **网络/代理**：断网仍崩；手机直连 RKP 端点能拿到 699 字节合法 CBOR
- **本地数据**：root 整包备份后 `pm clear`，仍崩
- **缓存 / 编译产物**：`pm trim-caches`、`cmd package compile --reset` 均无效
- **权限**：CAMERA 授权与否无影响
- **版本 10.19.0**：Play 原签、逐字节校验证书，同样崩溃
- **Keystore 密钥损坏**：卸载后 `keyentry` 1742→1738、alias 行消失，重装仍崩 → 证伪
- **attestation / RKP**：打开 `enable_rkpd` 后 RKP 确实发起请求，但交换在协议层失败
  （`Response failed to parse` / `Actual: 0`），且端点自身正常 → 无法在用户侧修复
- **隐藏 root**：KernelSU `umount modules` 后 PayPal 进程看不到 `/system/bin/su`，10.10.0 仍报 `s=root`
- **Frida**：本机 ART 上 spawn 报 `setArgV0 slot`、attach 报 `agent connection closed`，不可用

### 5. 最终解法

不再与检测对抗，改为接管未捕获异常处理器：RASP 自毁异常被记录但不退出进程。
实测 10.20.1 存活超过 60 秒并正常渲染首页。

## 复现要点

- 查看模块是否注入：`adb shell su -c 'grep RASPGuard /data/adb/lspd/log/*'`
- 查看是否列出模块：`/data/adb/lspd/config/modules_config.db` 的 `modules` / `modules_state` 表
- 模块必须有 `assets/xposed_init`，否则 LSPosed 不列出它
