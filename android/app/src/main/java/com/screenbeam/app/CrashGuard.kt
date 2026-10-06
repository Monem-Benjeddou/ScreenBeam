package com.screenbeam.app

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import android.os.SystemClock
import android.util.Log

/**
 * Crash recovery for the phone app.
 *
 * - Records any uncaught exception (on any thread) and reopens the app, which then says so.
 * - A crash within 20 s of launch is "quick". After 2 quick crashes in a row the app starts in safe
 *   mode (the vendor low-latency decoder settings, the riskiest part, are off) with a one-tap way
 *   back; after 3 it stops reopening itself.
 */
object CrashGuard {
    private const val TAG = "ScreenBeam"
    private const val PREFS = "screenbeam_crash"
    private const val QUICK_MS = 20_000L
    private var installed = false
    private lateinit var appContext: Context

    val safeMode: Boolean
        get() = installed && prefs().getBoolean("safe_mode", false)

    fun install(context: Context) {
        if (installed) return
        installed = true
        appContext = context.applicationContext
        val launchedAt = SystemClock.elapsedRealtime()
        val systemHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { thread, error ->
            try {
                val p = prefs()
                val quick = SystemClock.elapsedRealtime() - launchedAt < QUICK_MS
                val streak = if (quick) p.getInt("quick_crashes", 0) + 1 else 1
                p.edit()
                    .putInt("quick_crashes", if (quick) streak else 0)
                    .putString("last_crash", "${error.javaClass.simpleName} on ${thread.name}: ${error.message}")
                    .putBoolean("safe_mode", p.getBoolean("safe_mode", false) || streak >= 2)
                    .putString("notice", if (streak >= 3) "gave_up" else "reopened")
                    .commit()
                Log.e(TAG, "crash on ${thread.name} (quick streak $streak)", error)
                if (streak < 3 && relaunch()) {
                    // A fresh process picks up the activity we just asked for; end this broken one now.
                    android.os.Process.killProcess(android.os.Process.myPid())
                    kotlin.system.exitProcess(10)
                }
            } catch (_: Throwable) {
            }
            systemHandler?.uncaughtException(thread, error)
        }
        // Running for a while without crashing: the streak is over.
        Handler(Looper.getMainLooper()).postDelayed({
            prefs().edit().putInt("quick_crashes", 0).apply()
        }, QUICK_MS)
        debugCrashTrigger()
    }

    /** One-time message after a crash, or null. */
    fun takeNotice(context: Context): String? {
        val p = prefs()
        val notice = p.getString("notice", null) ?: return null
        p.edit().remove("notice").apply()
        return when (notice) {
            "gave_up" -> "ScreenBeam closed several times in a row. It's in safe mode now."
            else -> "ScreenBeam closed unexpectedly and was reopened."
        }
    }

    fun leaveSafeMode() {
        prefs().edit().putBoolean("safe_mode", false).putInt("quick_crashes", 0).apply()
    }

    private fun prefs() = appContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)

    /**
     * Asks the system to start the app again while we're still the foreground app (Android 10+
     * doesn't let an alarm or a background process bring an activity back later).
     */
    private fun relaunch(): Boolean {
        val intent = appContext.packageManager.getLaunchIntentForPackage(appContext.packageName) ?: return false
        intent.addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TASK)
        return try {
            appContext.startActivity(intent)
            true
        } catch (_: Exception) {
            false
        }
    }

    /**
     * Proves recovery works on a real device: `adb shell setprop debug.screenbeam.crash N` makes each
     * of the next N launches crash 2 s after starting (`setprop debug.screenbeam.crash 0` resets it).
     */
    private fun debugCrashTrigger() {
        val n = try {
            @Suppress("PrivateApi")
            Class.forName("android.os.SystemProperties").getMethod("getInt", String::class.java, Int::class.javaPrimitiveType)
                .invoke(null, "debug.screenbeam.crash", 0) as Int
        } catch (_: Exception) {
            0
        }
        val done = prefs().getInt("debug_crashes_done", 0)
        if (n <= 0) {
            if (done != 0) prefs().edit().remove("debug_crashes_done").apply()
            return
        }
        if (done >= n) return
        prefs().edit().putInt("debug_crashes_done", done + 1).commit()
        Handler(Looper.getMainLooper()).postDelayed({
            throw IllegalStateException("debug crash ${done + 1} of $n (debug.screenbeam.crash)")
        }, 2_000)
    }
}
