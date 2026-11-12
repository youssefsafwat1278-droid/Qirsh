package com.youssefsafwat.mali

import android.content.Context
import android.os.Handler
import android.os.Looper
import androidx.work.BackoffPolicy
import androidx.work.Constraints
import androidx.work.ExistingWorkPolicy
import androidx.work.NetworkType
import androidx.work.OneTimeWorkRequest
import androidx.work.WorkManager
import androidx.work.Worker
import androidx.work.WorkerParameters
import io.flutter.FlutterInjector
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodChannel
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference

/**
 * The engine that can run a background-triggered drain: the activity's engine,
 * once its Dart AppShell registered the handler (`setBackgroundDrainReady`).
 * With no activity engine at all the worker starts a headless one instead
 * (see [CaptureDrainWorker]).
 */
object CaptureDrainHost {
    @Volatile private var channel: MethodChannel? = null
    @Volatile private var ready = false

    fun attach(channel: MethodChannel) {
        this.channel = channel
        ready = false
    }

    fun detach(channel: MethodChannel) {
        if (this.channel === channel) {
            this.channel = null
            ready = false
        }
    }

    fun setReady(channel: MethodChannel, ready: Boolean) {
        if (this.channel === channel) this.ready = ready
    }

    fun readyChannel(): MethodChannel? = if (ready) channel else null

    /** An activity engine is attached (ready or not). */
    fun hasEngine(): Boolean = channel != null

    /** A headless cold-start engine of this process is alive. */
    @Volatile var headlessActive = false
        private set

    fun headlessStarted() {
        headlessActive = true
    }

    fun headlessEnded() {
        headlessActive = false
    }
}

/**
 * Persistent scheduling of the background capture drain: ONE unique work
 * ([UNIQUE_WORK]), a network constraint and exponential backoff starting at the
 * retry ledger's first step (30 s). WorkManager persists the work across
 * process death and reboot (its own RescheduleReceiver, merged from the
 * library manifest, uses RECEIVE_BOOT_COMPLETED, which the app declares).
 * After a force-stop Android cancels the scheduled jobs and delivers no
 * broadcast (no SMS either) until the user opens the app again; WorkManager
 * then re-schedules on that next start.
 */
object CaptureBackgroundScheduler {
    const val UNIQUE_WORK = "qirsh.capture_drain.v1"
    private const val PREFS = "mali_capture_drain_schedule_v1"
    private const val KEY_RUN_AT = "scheduledRunAtMs"
    private const val BACKOFF_SECONDS = 30L

    private var running = false
    private var followUpAtMs: Long? = null

    /** Asks for a drain no earlier than [delayMs] from now. Never duplicates. */
    @Synchronized
    fun request(context: Context, delayMs: Long) {
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        val runAt = now + delayMs.coerceAtLeast(0L)
        val prefs = app.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
        val scheduled = if (prefs.contains(KEY_RUN_AT)) prefs.getLong(KEY_RUN_AT, 0L) else null
        when (CaptureDrainSchedulePolicy.decide(running, scheduled, runAt, now)) {
            CaptureDrainSchedulePolicy.Decision.KEEP_EXISTING -> Unit
            CaptureDrainSchedulePolicy.Decision.FOLLOW_UP_AFTER_RUN ->
                followUpAtMs = minOf(followUpAtMs ?: runAt, runAt)
            CaptureDrainSchedulePolicy.Decision.REPLACE -> {
                enqueue(app, runAt - now, ExistingWorkPolicy.REPLACE)
                prefs.edit().putLong(KEY_RUN_AT, runAt).apply()
            }
        }
    }

    /** Sign-out / Remove data / account switch: nothing scheduled may run. */
    @Synchronized
    fun cancel(context: Context) {
        val app = context.applicationContext
        followUpAtMs = null
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit().remove(KEY_RUN_AT).apply()
        WorkManager.getInstance(app).cancelUniqueWork(UNIQUE_WORK)
    }

    @Synchronized
    internal fun onWorkerStarted(context: Context) {
        running = true
        context.applicationContext.getSharedPreferences(PREFS, Context.MODE_PRIVATE)
            .edit().remove(KEY_RUN_AT).apply()
    }

    /** Chains the follow-up a request made while running asked for. */
    @Synchronized
    internal fun onWorkerFinished(context: Context) {
        running = false
        val next = followUpAtMs ?: return
        followUpAtMs = null
        val app = context.applicationContext
        val now = System.currentTimeMillis()
        // The current work is still RUNNING here: APPEND_OR_REPLACE queues the
        // follow-up behind it instead of cancelling it.
        enqueue(app, (next - now).coerceAtLeast(0L), ExistingWorkPolicy.APPEND_OR_REPLACE)
        app.getSharedPreferences(PREFS, Context.MODE_PRIVATE).edit()
            .putLong(KEY_RUN_AT, maxOf(next, now)).apply()
    }

    /** Stopped by the OS (constraint lost, cancelled): WorkManager owns the retry. */
    @Synchronized
    internal fun onWorkerStopped() {
        running = false
        followUpAtMs = null
    }

    private fun enqueue(app: Context, delayMs: Long, policy: ExistingWorkPolicy) {
        val request = OneTimeWorkRequest.Builder(CaptureDrainWorker::class.java)
            .setConstraints(
                Constraints.Builder().setRequiredNetworkType(NetworkType.CONNECTED).build(),
            )
            .setBackoffCriteria(BackoffPolicy.EXPONENTIAL, BACKOFF_SECONDS, TimeUnit.SECONDS)
            .setInitialDelay(delayMs, TimeUnit.MILLISECONDS)
            .build()
        WorkManager.getInstance(app).enqueueUniqueWork(UNIQUE_WORK, policy, request)
    }
}

/**
 * A headless Flutter engine running the Dart `captureBackgroundMain` entrypoint
 * (lib/main.dart): the cold-start drain host. Driven on the main thread.
 */
interface HeadlessCaptureEngine {
    /**
     * Starts the engine and its Dart entrypoint. [onReady] runs (main thread)
     * once Dart registered its one-run drain host, with the capture channel to
     * drive. Throws when the engine cannot be started.
     */
    fun start(onReady: (MethodChannel) -> Unit)

    /** Shuts the engine (and its Dart isolate) down. Idempotent. */
    fun destroy()
}

/** Where the worker gets its headless engine (the JVM harness swaps it). */
object HeadlessCaptureEngines {
    @Volatile
    var factory: (Context) -> HeadlessCaptureEngine = { FlutterHeadlessCaptureEngine(it) }
}

/**
 * The real headless engine: Flutter loader initialized, a [FlutterEngine]
 * with the app's plugins auto-registered (GeneratedPluginRegistrant), the
 * capture channel (the SAME handler as the activity's, minus the
 * activity-only methods) and the timezone channel installed BEFORE Dart runs,
 * then the `captureBackgroundMain` entrypoint executed.
 */
class FlutterHeadlessCaptureEngine(private val context: Context) : HeadlessCaptureEngine {
    private var engine: FlutterEngine? = null

    override fun start(onReady: (MethodChannel) -> Unit) {
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(context)
        loader.ensureInitializationComplete(context, null)
        val engine = FlutterEngine(context)
        this.engine = engine
        val messenger = engine.dartExecutor.binaryMessenger
        val channel = MethodChannel(messenger, CAPTURE_CHANNEL)
        var signalled = false
        channel.setMethodCallHandler(
            NativeCaptureChannelHandler(
                context = context,
                onDrainReady = { ready ->
                    if (ready && !signalled) {
                        signalled = true
                        onReady(channel)
                    }
                },
            ),
        )
        registerDeviceTimezoneChannel(messenger)
        // The headless bootstrap loads the same coordinated session store.
        SessionKeychainChannel.register(messenger, context)
        engine.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint(loader.findAppBundlePath(), ENTRYPOINT),
        )
    }

    override fun destroy() {
        engine?.destroy()
        engine = null
    }

    companion object {
        const val CAPTURE_CHANNEL = "money_companion/native_capture"
        const val ENTRYPOINT = "captureBackgroundMain"
    }
}

/**
 * Runs the REAL Dart drain and maps its outcome onto the work:
 *  - a live activity engine whose AppShell registered the drain host: that
 *    engine's leased drain runs (same provider graph, scope and admission);
 *  - a live activity engine without a drain host (shell not mounted, signed
 *    out, onboarding): nothing runs here; that engine drains on its own
 *    triggers (launch / resume / shell mount);
 *  - NO engine in this process (killed by the OS, after a reboot): a HEADLESS
 *    engine is started with `captureBackgroundMain`, which bootstraps only what
 *    the drain needs (`BootstrapRunner.runHeadless`) and runs the same leased
 *    drain once. It takes the database coordinator only when no other engine
 *    holds it, and yields to a foreground bootstrap at the next item boundary
 *    (the foreground always wins). The engine is destroyed only AFTER Dart
 *    answered (its databases are closed and the coordinator released by then);
 *    a run that has not answered in time is cancelled and its engine kept
 *    until it answers, never torn down under an open database.
 */
class CaptureDrainWorker(
    appContext: Context,
    params: WorkerParameters,
) : Worker(appContext, params) {
    private val main = Handler(Looper.getMainLooper())
    private val stopped = AtomicBoolean(false)
    @Volatile private var host: MethodChannel? = null

    /** WorkManager's background thread; channels and engines are driven on the main thread. */
    override fun doWork(): Result {
        CaptureBackgroundScheduler.onWorkerStarted(applicationContext)
        val outcome = AtomicReference<Result?>(null)
        val answered = CountDownLatch(1)
        fun answer(result: Result) {
            if (outcome.compareAndSet(null, result)) answered.countDown()
        }
        main.post {
            if (stopped.get()) {
                answer(Result.retry())
                return@post
            }
            val channel = CaptureDrainHost.readyChannel()
            when {
                channel != null -> runDrain(channel, null, ::answer)
                // A live engine without a drain host: it drains on its own.
                CaptureDrainHost.hasEngine() -> answer(Result.success())
                // An earlier headless run has not answered yet (it was
                // cancelled; its engine is kept until it does): never a second.
                CaptureDrainHost.headlessActive -> answer(Result.retry())
                else -> startHeadless(::answer)
            }
        }
        if (!answered.await(RUN_TIMEOUT_MS, TimeUnit.MILLISECONDS)) {
            // Stops at the next item boundary; the item in flight commits or
            // rolls back as a unit. A headless engine is destroyed only once
            // Dart answers (see runDrain), whenever that is.
            main.post { host?.invokeMethod("cancelBackgroundDrain", null) }
            answered.await(CANCEL_GRACE_MS, TimeUnit.MILLISECONDS)
            answer(Result.retry())
        }
        if (stopped.get()) return Result.retry()
        CaptureBackgroundScheduler.onWorkerFinished(applicationContext)
        return outcome.get() ?: Result.retry()
    }

    /** Main thread: no engine exists, start a headless one for this run. */
    private fun startHeadless(answer: (Result) -> Unit) {
        val engine = try {
            HeadlessCaptureEngines.factory(applicationContext)
        } catch (_: Throwable) {
            answer(Result.retry())
            return
        }
        CaptureDrainHost.headlessStarted()
        var ready = false
        val notReady = Runnable {
            // Dart never registered its drain host: it never started a
            // bootstrap either, so nothing is open. Tear down and retry later.
            if (!ready) {
                engine.destroy()
                CaptureDrainHost.headlessEnded()
                answer(Result.retry())
            }
        }
        try {
            engine.start { channel ->
                ready = true
                main.removeCallbacks(notReady)
                if (stopped.get()) {
                    engine.destroy()
                    CaptureDrainHost.headlessEnded()
                    answer(Result.retry())
                } else {
                    runDrain(channel, engine, answer)
                }
            }
        } catch (_: Throwable) {
            engine.destroy()
            CaptureDrainHost.headlessEnded()
            answer(Result.retry())
            return
        }
        if (!ready) main.postDelayed(notReady, READY_TIMEOUT_MS)
    }

    /** Main thread: one Dart drain; a headless engine is destroyed after it answered. */
    private fun runDrain(channel: MethodChannel, engine: HeadlessCaptureEngine?, answer: (Result) -> Unit) {
        host = channel
        fun finish(result: Result) {
            if (engine != null) {
                engine.destroy()
                CaptureDrainHost.headlessEnded()
            }
            if (host === channel) host = null
            answer(result)
        }
        channel.invokeMethod(
            "runBackgroundDrain",
            null,
            object : MethodChannel.Result {
                override fun success(result: Any?) = finish(
                    if (CaptureDrainSchedulePolicy.succeeded(result as? String)) {
                        Result.success()
                    } else {
                        Result.retry()
                    },
                )

                override fun error(code: String, message: String?, details: Any?) =
                    finish(Result.retry())

                // The engine has no drain handler (shell not mounted).
                override fun notImplemented() = finish(Result.success())
            },
        )
    }

    override fun onStopped() {
        stopped.set(true)
        CaptureBackgroundScheduler.onWorkerStopped()
        // The Dart pass stops at its next item boundary; an item in flight
        // commits or rolls back as a unit and is acknowledged only after commit.
        main.post { host?.invokeMethod("cancelBackgroundDrain", null) }
    }

    companion object {
        /** Under WorkManager's 10-minute execution limit. */
        private const val RUN_TIMEOUT_MS = 8 * 60_000L

        /** After a cancel: the item in flight finishes or rolls back. */
        private const val CANCEL_GRACE_MS = 60_000L

        /** Dart must register its drain host this soon after the engine starts. */
        private const val READY_TIMEOUT_MS = 60_000L
    }
}
