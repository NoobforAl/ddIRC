package dev.ddirc.ddirc

import android.content.Intent
import android.content.pm.PackageManager
import android.os.Bundle
import io.flutter.embedding.android.FlutterFragmentActivity
import io.flutter.embedding.engine.FlutterEngine

/**
 * The window, and not much more than the window.
 *
 * Everything about *when* to run in the background is decided in Dart, next to
 * the setting and the connections it is about. Everything Dart cannot do for
 * itself is in [AppEngine], which outlives this class — deliberately, because
 * the whole point of staying connected in the background is that the app goes
 * on after its window does not.
 *
 * What is left here is what genuinely belongs to an activity: being the thing
 * on screen, being what Android hands a permission answer to, and being where a
 * tapped notification arrives.
 *
 * A `FlutterFragmentActivity` rather than a plain `FlutterActivity` — the base
 * class `local_auth_android` requires, since a biometric prompt is shown
 * through a `DialogFragment`, which needs a `FragmentActivity` host to attach
 * to.
 */
class MainActivity : FlutterFragmentActivity() {

    /**
     * Attach to the engine [AppEngine] keeps, rather than making one.
     *
     * Answering this at all is what puts Flutter on its cached-engine path,
     * where the engine is something the app owns and lends to a window instead
     * of something a window brings with it and takes away again.
     */
    override fun getCachedEngineId(): String = AppEngine.ENGINE_ID

    /**
     * Never — and this is not the decision it sounds like.
     *
     * Flutter reads this once, while the fragment is being built, and bakes the
     * answer in. That is far too early to know: the service may not have
     * started yet on a launch that is about to start it, and may have been
     * turned off since on one that did. So the answer here is a flat no, and
     * the real decision is made in [onDestroy], where it can be made with the
     * facts in front of it.
     */
    override fun shouldDestroyEngineWithHost(): Boolean = false

    override fun onCreate(savedInstanceState: Bundle?) {
        // Before `super`, which builds the fragment that goes looking for the
        // engine under the id above and throws if nothing is there.
        AppEngine.warm(this)
        super.onCreate(savedInstanceState)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        // Deliberately not `super`, which registers the plugins. This engine is
        // shared and long-lived, so this runs again every time a window
        // attaches to it, and a second registration is a warning per plugin
        // about work already done. [AppEngine.warm] is where it happens once.
        AppEngine.attach(this)
        // A notification tapped while the app was not running launches the
        // activity, and the intent that did it is the one already sitting here.
        // Delivered now that the engine is attached; onNewIntent covers the
        // case where the app was running already.
        deliverConversation(intent)
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        AppEngine.detach(this)
    }

    /**
     * Whether anything is left when this window closes.
     *
     * The engine is not destroyed with the activity, so something has to decide
     * — and this is the first moment with enough information to. If the
     * foreground service is up, the user has asked ddIRC to stay connected and
     * the engine goes on without a window, which is what makes a swipe from
     * Recents survivable. If it is not, nothing is holding the process up and a
     * Dart isolate left running in it would be a leak with an app around it.
     */
    override fun onDestroy() {
        super.onDestroy()
        if (isChangingConfigurations) return
        if (!ConnectionService.isRunning) AppEngine.shutdown()
    }

    /**
     * A message notification tapped while the app was already running.
     *
     * The activity is `singleTop`, so it is not started again — the intent
     * arrives here instead, and setting it is what makes `getIntent()` return
     * the new one rather than the launch intent for the rest of this instance's
     * life.
     */
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        setIntent(intent)
        deliverConversation(intent)
    }

    /**
     * Tell Dart which conversation a tap was about, if it was about one.
     *
     * The extras are cleared afterwards so that an activity recreated for an
     * unrelated reason — a rotation, a configuration change — does not replay
     * a tap that happened some time ago and jump the user somewhere they did
     * not ask to go a second time.
     */
    private fun deliverConversation(intent: Intent?) {
        if (intent == null) return
        val profileId = intent.getStringExtra(MessageNotifications.EXTRA_PROFILE) ?: return
        val conversation =
            intent.getStringExtra(MessageNotifications.EXTRA_CONVERSATION) ?: return

        intent.removeExtra(MessageNotifications.EXTRA_PROFILE)
        intent.removeExtra(MessageNotifications.EXTRA_CONVERSATION)

        AppEngine.openConversation(profileId, conversation)
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode != AppEngine.PERMISSION_REQUEST) return
        AppEngine.onPermissionResult(
            grantResults.isNotEmpty() &&
                grantResults[0] == PackageManager.PERMISSION_GRANTED,
        )
    }
}
