package com.dsh.raspguard.paypal;

import android.os.Handler;
import android.os.Looper;

import de.robv.android.xposed.IXposedHookLoadPackage;
import de.robv.android.xposed.XposedBridge;
import de.robv.android.xposed.callbacks.XC_LoadPackage.LoadPackageParam;

/**
 * PayPal RASP Guard
 *
 * <p>PayPal 的 RASP（运行时自我保护）在启动阶段一旦判定环境不可信，会由
 * {@code com.paypal.oslo.app.di.RaspCrashSchedulerModule} 主动制造一次未捕获异常
 * （在 10.10/10.12 上是 {@code RootDetectionSecurityException: s=root}，
 * 在 10.19/10.20 上伪装成 {@code OutOfMemoryError} / {@code index=-1} 越界）。
 *
 * <p>ART 收到未捕获异常后默认调用 Runtime.exit()，整个进程随之退出，表现为"闪退"。
 * 本模块把默认的未捕获异常处理器换成一层过滤器：匹配到 RASP 自毁特征的异常时
 * 只记录、不退出，从而让进程存活。它<b>不修改</b>任何安全判定，也不伪造 attestation。
 *
 * <p>注意：本类仅在 {@code com.paypal.android.p2pmobile} 进程内生效（作用域见
 * AndroidManifest 中的 xposedscope）。
 */
public class Hook implements IXposedHookLoadPackage {

    private static final String TAG = "[RASPGuard] ";
    private static final String PKG = "com.paypal.android.p2pmobile";

    /** 重新安装处理器的延后时刻（ms）。PayPal / Datadog 会在启动过程中多次替换该处理器。 */
    private static final int[] REINSTALL_DELAYS = {700, 1500, 2600, 4000, 6000, 9000};

    /**
     * 判断是否为 RASP 自毁型异常。
     *
     * <p>判定只依据异常本身，不做启发式猜测：
     * <ul>
     *   <li>OOM / 越界：RASP 用来"伪装成 bug"的两种形态</li>
     *   <li>类名或消息命中 RASP / root 检测特征</li>
     * </ul>
     */
    private static boolean isRaspSelfDestruct(Throwable e) {
        if (e == null) return false;

        // 1) 伪装形态：内存分配失败 或 数组下标越界
        if (e instanceof OutOfMemoryError) return true;
        if (e instanceof IndexOutOfBoundsException) return true;

        // 2) 显式形态：RASP 自身异常类
        String cls = e.getClass().getName().toLowerCase(java.util.Locale.ROOT);
        if (cls.contains("rootdetection") || cls.contains("rasp")) return true;

        // 3) 消息特征
        String msg = String.valueOf(e.getMessage()).toLowerCase(java.util.Locale.ROOT);
        return msg.contains("s=root") || msg.contains("security policy violation");
    }

    private static void installGuard(final String stage) {
        try {
            final Thread.UncaughtExceptionHandler previous = Thread.getDefaultUncaughtExceptionHandler();

            Thread.setDefaultUncaughtExceptionHandler(new Thread.UncaughtExceptionHandler() {
                @Override
                public void uncaughtException(Thread t, Throwable e) {
                    if (isRaspSelfDestruct(e)) {
                        XposedBridge.log(TAG + "suppressed on " + t.getName()
                                + " [" + stage + "]: " + e.getClass().getName()
                                + ": " + e.getMessage());
                        return; // 不退出进程
                    }
                    XposedBridge.log(TAG + "passthrough [" + stage + "]: " + e);
                    if (previous != null) {
                        previous.uncaughtException(t, e);
                    } else {
                        android.os.Process.killProcess(android.os.Process.myPid());
                    }
                }
            });
        } catch (Throwable t) {
            XposedBridge.log(TAG + "install failed [" + stage + "]: " + t);
        }
    }

    @Override
    public void handleLoadPackage(LoadPackageParam lpparam) throws Throwable {
        if (!PKG.equals(lpparam.packageName)) return;

        XposedBridge.log(TAG + "loaded in " + lpparam.packageName);
        installGuard("load");

        try {
            final Handler main = new Handler(Looper.getMainLooper());
            for (final int delay : REINSTALL_DELAYS) {
                main.postDelayed(new Runnable() {
                    @Override
                    public void run() {
                        installGuard("t+" + delay);
                    }
                }, delay);
            }
        } catch (Throwable t) {
            XposedBridge.log(TAG + "schedule failed: " + t);
        }
    }
}
