### PayPal RASP Guard v__VERSION__

让 Google Play 版 PayPal 在已 root 的设备上正常启动：接管进程的未捕获异常处理器，使 RASP 的自毁型异常被记录而不终止进程。
不修改 attestation、不绕过服务端风控、不改 APK、不改系统分区。

**安装**

1. 需要已 root 设备 + LSPosed
2. `adb install -r __APK__`
3. LSPosed 中启用 **PayPal RASP Guard**，确认作用域包含 PayPal
4. 强制停止 PayPal 后重新打开

**校验**

```
__SHA__
```

**注意**

- 模块必须保持启用，禁用后应用恢复闪退
- 本组件关闭了目标应用的一项安全机制，可能降低账户欺诈防护能力
- 使用前请阅读 [DISCLAIMER.md](https://github.com/__REPO__/blob/__REF__/DISCLAIMER.md)
- 本项目与 PayPal Inc. 无任何关联
