package dev.ddirc.ddirc

import android.Manifest
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * The activity, and the one channel the Android half of the app speaks over.
 *
 * Everything about *when* to run in the background is decided in Dart, next to
 * the setting and the connections it is about. What crosses this channel is
 * only what Dart cannot do for itself: start and stop a service, ask about a
 * permission, and hear that the notification's Quit button was pressed.
 */
class MainActivity : FlutterActivity() {

    private companion object {
        const val CHANNEL = "dev.ddirc/background"
        const val PERMISSION_REQUEST = 1001
    }

    private var channel: MethodChannel? = null

    /** In flight while the user is looking at the permission dialog. */
    private var pendingPermission: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val channel = MethodChannel(flutterEngine.dartExecutor.binaryMessenger, CHANNEL)
        this.channel = channel

        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "start" -> {
                    send(ConnectionService.ACTION_START, call.argument("status"))
                    result.success(null)
                }

                "update" -> {
                    send(ConnectionService.ACTION_UPDATE, call.argument("status"))
                    result.success(null)
                }

                "stop" -> {
                    send(ConnectionService.ACTION_STOP, null)
                    result.success(null)
                }

                "notificationsAllowed" -> result.success(notificationsAllowed())

                "requestNotifications" -> requestNotifications(result)

                else -> result.notImplemented()
            }
        }

        // The notification's Quit button, and a swipe from Recents, both arrive
        // in the service. Neither can say goodbye to a server on its own, so
        // both are handed back to Dart, which closes the connections and then
        // asks for the service to stop.
        ConnectionService.onQuitRequested = {
            runOnUiThread { this.channel?.invokeMethod("quit", null) }
        }
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Cleared rather than left dangling: once the engine is gone there is
        // nobody to ask, and the service is written to stop itself instead.
        ConnectionService.onQuitRequested = null
        channel?.setMethodCallHandler(null)
        channel = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    private fun send(action: String, status: String?) {
        val intent = Intent(this, ConnectionService::class.java)
            .setAction(action)
            .putExtra(ConnectionService.EXTRA_STATUS, status.orEmpty())

        if (action == ConnectionService.ACTION_START &&
            Build.VERSION.SDK_INT >= Build.VERSION_CODES.O
        ) {
            // Only ever called while the app is on screen — the user has just
            // moved the switch, or the app has just launched — which is the
            // condition Android 12 and later put on starting one of these.
            startForegroundService(intent)
        } else {
            startService(intent)
        }
    }

    /**
     * Whether the notification would actually be seen.
     *
     * The service runs either way; this is only about whether the user is told
     * it is running, which from Android 13 is a permission they may refuse.
     */
    private fun notificationsAllowed(): Boolean {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return true
        return checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS) ==
            PackageManager.PERMISSION_GRANTED
    }

    private fun requestNotifications(result: MethodChannel.Result) {
        if (notificationsAllowed()) {
            result.success(true)
            return
        }
        // Two dialogs at once would leave the first without an answer.
        if (pendingPermission != null) {
            result.success(false)
            return
        }
        pendingPermission = result
        requestPermissions(arrayOf(Manifest.permission.POST_NOTIFICATIONS), PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != PERMISSION_REQUEST) return
        val granted = grantResults.isNotEmpty() &&
            grantResults[0] == PackageManager.PERMISSION_GRANTED
        pendingPermission?.success(granted)
        pendingPermission = null
    }
}
