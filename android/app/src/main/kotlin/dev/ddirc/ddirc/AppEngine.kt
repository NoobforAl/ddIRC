package dev.ddirc.ddirc

import android.Manifest
import android.app.Activity
import android.content.ActivityNotFoundException
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.PowerManager
import android.provider.Settings
import android.util.Log
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.FlutterEngineCache
import io.flutter.embedding.engine.dart.DartExecutor
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugins.GeneratedPluginRegistrant

/**
 * The Flutter engine, and the one channel the Android half of the app speaks
 * over.
 *
 * Both of these belonged to [MainActivity] until the app was allowed to outlive
 * its window. Now it is: with **Stay connected in the background** on, swiping
 * ddIRC out of Recents leaves the connections up — and an activity is precisely
 * the thing that gesture destroys.
 *
 * What has to survive is not the connections. Those are in the Rust core, on
 * its own threads, and never cared about the activity. It is everything between
 * a message arriving and anyone hearing about it: the events are read in Dart,
 * the decision to notify is made in Dart, and the notification is posted back
 * over this channel. An engine that died with the activity would leave the
 * sockets open with nobody listening to them, which is the worst of both.
 *
 * So the engine is made here, left in [FlutterEngineCache] for the activity to
 * attach to, and outlives any number of activities. The one thing it does not
 * outlive is having no reason to exist — see [shutdown] and
 * [MainActivity.onDestroy].
 */
object AppEngine {

    /**
     * Where [MainActivity] looks for the engine.
     *
     * Answering `getCachedEngineId` with this is what puts the activity on
     * Flutter's cached-engine path, which is the path where the engine is
     * something the app owns rather than something the window comes with.
     */
    const val ENGINE_ID = "dev.ddirc.ddirc.engine"

    /** See `background_android.dart`, which is the other end of this. */
    const val CHANNEL = "dev.ddirc/background"

    /** The notification permission dialog, which [MainActivity] hears back on. */
    const val PERMISSION_REQUEST = 1001

    private const val TAG = "ddIRC"

    @Volatile
    private var engine: FlutterEngine? = null

    private var channel: MethodChannel? = null

    /**
     * The activity, while there is one.
     *
     * Exactly one thing here genuinely needs it: asking for the notification
     * permission puts a dialog on screen, and a dialog needs a screen. Every
     * other call works from the application context, which is the whole reason
     * this object can go on working after the window is gone.
     */
    private var activity: Activity? = null

    /** In flight while the user is looking at that dialog. */
    private var pendingPermission: MethodChannel.Result? = null

    private val main = Handler(Looper.getMainLooper())

    /**
     * The engine, started if it is not already running.
     *
     * Called from two places that know nothing about each other: [MainActivity]
     * before it builds its fragment, and [ConnectionService] when Android has
     * restarted it after taking the process for memory. Whichever arrives first
     * makes it; the other finds it.
     */
    @Synchronized
    fun warm(context: Context): FlutterEngine {
        engine?.let { return it }

        val app = context.applicationContext
        // Plugins registered here rather than left to the constructor's own
        // reflective pass, so that there is one place it happens and
        // `MainActivity.configureFlutterEngine` can say plainly that it is not
        // the place. Registering twice is a warning per plugin about work
        // already done, and this engine is attached to more than once.
        val fresh = FlutterEngine(app, null, false)
        GeneratedPluginRegistrant.registerWith(fresh)

        // Dart is started here rather than left to the activity to start.
        // Flutter skips that step for a cached engine — it assumes anything
        // cached is already running — and the service has no activity to defer
        // to in the first place.
        fresh.dartExecutor.executeDartEntrypoint(
            DartExecutor.DartEntrypoint.createDefault(),
        )

        val talk = MethodChannel(fresh.dartExecutor.binaryMessenger, CHANNEL)
        talk.setMethodCallHandler { call, result -> handle(app, call, result) }

        // Cleared from the engine's own teardown rather than from either of the
        // two places that can cause it, so that neither has to remember.
        fresh.addEngineLifecycleListener(
            object : FlutterEngine.EngineLifecycleListener {
                override fun onPreEngineRestart() = Unit

                override fun onEngineWillDestroy() {
                    channel?.setMethodCallHandler(null)
                    channel = null
                    engine = null
                }
            },
        )

        channel = talk
        engine = fresh
        FlutterEngineCache.getInstance().put(ENGINE_ID, fresh)
        return fresh
    }

    /**
     * Give the engine up, and with it the last reason this process exists.
     *
     * Two ways here, and both mean the same thing: there is no window and no
     * foreground service, so a live Dart isolate is a process running for
     * nothing. One is the window closing while the setting is off; the other is
     * Quit pressed on the notification of an app that had already been swiped
     * away, where there is no activity left for Dart's own exit to finish.
     */
    fun shutdown() {
        FlutterEngineCache.getInstance().remove(ENGINE_ID)
        engine?.destroy()
    }

    fun attach(host: Activity) {
        activity = host
    }

    fun detach(host: Activity) {
        if (activity !== host) return
        activity = null
        // A permission dialog cannot outlive the activity showing it, and a
        // result that is never delivered leaves the Dart side awaiting forever.
        pendingPermission?.success(false)
        pendingPermission = null
    }

    /**
     * Ask Dart to close everything down.
     *
     * False when there is no Dart to ask, in which case the caller has to
     * settle for stopping. Dart is what knows how to say goodbye to a server,
     * so this is worth asking for whenever there is anybody to ask.
     */
    fun askToQuit(): Boolean {
        val talk = channel ?: return false
        main.post { talk.invokeMethod("quit", null) }
        return true
    }

    /** Tell Dart which conversation a tapped notification was about. */
    fun openConversation(profileId: String, conversation: String) {
        val talk = channel ?: return
        main.post {
            talk.invokeMethod(
                "openConversation",
                mapOf("profileId" to profileId, "conversation" to conversation),
            )
        }
    }

    /** The permission answer, forwarded by the activity Android told. */
    fun onPermissionResult(granted: Boolean) {
        pendingPermission?.success(granted)
        pendingPermission = null
    }

    private fun handle(
        context: Context,
        call: MethodCall,
        result: MethodChannel.Result,
    ) {
        when (call.method) {
            "start" -> {
                send(context, ConnectionService.ACTION_START, call.argument("status"))
                result.success(null)
            }

            "update" -> {
                send(context, ConnectionService.ACTION_UPDATE, call.argument("status"))
                result.success(null)
            }

            "stop" -> {
                send(context, ConnectionService.ACTION_STOP, null)
                result.success(null)
                // Dart follows a quit with `SystemNavigator.pop`, which finishes
                // the activity — and there may not be one, because the app can
                // be quit from its notification after being swiped away. With
                // the service now stopping too, nothing else would end this
                // process, so this does. Posted rather than done here so the
                // answer above is on its way first.
                if (activity == null) main.post { shutdown() }
            }

            "notificationsAllowed" -> result.success(notificationsAllowed(context))

            "requestNotifications" -> requestNotifications(context, result)

            "batteryOptimizationExempt" ->
                result.success(batteryOptimizationExempt(context))

            "requestBatteryOptimizationExemption" -> {
                requestBatteryOptimizationExemption(context)
                result.success(null)
            }

            "notifyMessage" -> {
                MessageNotifications.show(
                    context = context,
                    key = call.argument("key") ?: "",
                    profileId = call.argument("profileId") ?: "",
                    conversation = call.argument("conversation") ?: "",
                    title = call.argument("title") ?: "",
                    body = call.argument("body") ?: "",
                )
                result.success(null)
            }

            "clearMessage" -> {
                MessageNotifications.clear(context, call.argument("key") ?: "")
                result.success(null)
            }

            else -> result.notImplemented()
        }
    }

    /**
     * Reach the service.
     *
     * `startForegroundService` only for one that is not already up: that is the
     * call Android wants for a service that will promote itself, and it is the
     * one hedged about with rules on who may make it from where. A service that
     * is already running is reached with a plain start, which is both correct
     * and unrestricted.
     */
    private fun send(context: Context, action: String, status: String?) {
        val intent = Intent(context, ConnectionService::class.java)
            .setAction(action)
            .putExtra(ConnectionService.EXTRA_STATUS, status.orEmpty())

        try {
            if (action == ConnectionService.ACTION_START && !ConnectionService.isRunning) {
                context.startForegroundService(intent)
            } else {
                context.startService(intent)
            }
        } catch (e: IllegalStateException) {
            // Android refusing a background start. The setting not working is
            // not worth an exception reaching the user, and it must never be
            // worth losing a connection that is already up.
            Log.w(TAG, "could not reach the connection service", e)
        }
    }

    /**
     * Whether the notification would actually be seen.
     *
     * The service runs either way; this is only about whether the user is told
     * it is running, which from Android 13 is a permission they may refuse.
     */
    private fun notificationsAllowed(context: Context): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return context.checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotifications(context: Context, result: MethodChannel.Result) {
        if (notificationsAllowed(context)) {
            result.success(true)
            return
        }
        // Only ever asked while the user is looking at the switch they have
        // just moved, so no activity is not a case to work around — but it is
        // one to answer rather than leave hanging.
        val host = activity ?: run {
            result.success(false)
            return
        }
        // Two dialogs at once would leave the first without an answer.
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        host.requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            PERMISSION_REQUEST,
        )
    }

    /**
     * Whether Android will actually let [ConnectionService] go on running once
     * the window is gone, rather than suspending the process at its own
     * discretion some time later.
     *
     * Unlike [notificationsAllowed], nothing this app does is refused by
     * staying unexempted — the service still starts, and still runs for a
     * while. What is lost is quieter: on a phone with an aggressive battery
     * manager, the process can be cut regardless of the foreground service
     * that is supposed to protect it, and that happens with no notification,
     * no error and nothing for Dart to catch. This exemption is the one thing
     * this app can actually ask the platform for about it.
     */
    private fun batteryOptimizationExempt(context: Context): Boolean {
        val powerManager = context.getSystemService(Context.POWER_SERVICE) as PowerManager
        return powerManager.isIgnoringBatteryOptimizations(context.packageName)
    }

    /**
     * Send the user to the system prompt that grants the exemption above.
     *
     * A settings screen, not a permission dialog — there is no result to wait
     * for here the way [requestNotifications] waits for one, and no activity
     * is required to launch it, unlike that call. Dart finds out what
     * happened by asking [batteryOptimizationExempt] again once the app is
     * back in front, which is simpler than plumbing a result back through an
     * activity that may not even be the one that launched this.
     */
    private fun requestBatteryOptimizationExemption(context: Context) {
        val intent = Intent(
            Settings.ACTION_REQUEST_IGNORE_BATTERY_OPTIMIZATIONS,
            Uri.parse("package:${context.packageName}"),
        ).addFlags(Intent.FLAG_ACTIVITY_NEW_TASK)
        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            // Some OEM builds ship without this screen at all. There is
            // nothing to fall back to, and no exception worth reaching the
            // user over a request they did not know had a second step.
            Log.w(TAG, "no battery optimization settings screen on this device", e)
        }
    }
}
