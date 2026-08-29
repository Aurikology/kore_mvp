package com.aurikology.kore

import android.Manifest
import android.app.NotificationManager
import android.content.Intent
import android.content.pm.PackageManager
import android.os.Build
import android.os.Bundle
import android.view.WindowManager
import io.flutter.embedding.android.FlutterActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.embedding.engine.renderer.FlutterUiDisplayListener
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel

/**
 * The Android half of `lib/services/kore_platform.dart`.
 *
 * In-repo rather than a pub plugin, for the reason `docs/hardware-seam.md`
 * sets out: the constraint is no pub *dependency*, not no platform code. A
 * `MethodChannel` written here adds nothing to `pubspec.yaml`, needs no symlink
 * support on Windows, and loads nothing a host-VM test has to bind. The Dart
 * side falls back to an inert implementation where this file does not exist, so
 * the desktop build never learns that notifications are a thing.
 *
 * This is also the rehearsal for BLE. Getting the shape of the channel wrong
 * here costs one missing banner; getting it wrong with a radio attached costs
 * the measurement.
 */
class MainActivity : FlutterActivity() {

    private var channel: MethodChannel? = null

    /** `kore/ble`, commands out. Two methods: `startScan` and `disconnect`. */
    private var bleChannel: MethodChannel? = null

    /**
     * `kore/ble/stream`, notifications and link transitions in - one stream and
     * not two, because their ordering with respect to each other is what stops
     * a `reconnecting` overtaking the last packets of the stream it ends.
     */
    private var bleEvents: EventChannel? = null

    /**
     * The unanswered `requestNotificationPermission`, held across the system
     * dialog. At most one: a second request while the first is up is answered
     * false rather than replacing it, because a `MethodChannel.Result` may be
     * replied to exactly once and overwriting this reference strands the first
     * caller's Future forever.
     */
    private var permissionResult: MethodChannel.Result? = null

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)

        val methodChannel = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kore/platform",
        )
        methodChannel.setMethodCallHandler(::onMethodCall)
        channel = methodChannel

        // Deliberately not `KoreActions.attach(methodChannel)` here. This runs
        // before the Dart entrypoint executes, so on a cold start there is no
        // isolate yet and anything pushed now is discarded by the engine. The
        // first rendered frame is the earliest moment Dart is provably running,
        // so that is where the channel is published as live; until then
        // `deliver` finds no channel and leaves the press in the slot for
        // `takePendingAction` to pull. When an engine is reattached and already
        // displaying, this fires immediately.
        flutterEngine.renderer.addIsDisplayingFlutterUiListener(
            object : FlutterUiDisplayListener {
                override fun onFlutterUiDisplayed() {
                    flutterEngine.renderer.removeIsDisplayingFlutterUiListener(this)
                    KoreActions.attach(methodChannel)
                }

                override fun onFlutterUiNoLongerDisplayed() = Unit
            },
        )

        // The radio, wired the same way and in the same place. No display
        // listener for this one: an `EventChannel` reports its own listener
        // through `onListen`, which is a stronger claim than a rendered frame,
        // and `KoreBleHost` latches its last link transition for a sink that
        // subscribes after it.
        val bleCommands = MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kore/ble",
        )
        bleCommands.setMethodCallHandler(KoreBleHost::onMethodCall)
        bleChannel = bleCommands

        val bleStream = EventChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            "kore/ble/stream",
        )
        bleStream.setStreamHandler(KoreBleHost)
        bleEvents = bleStream

        KoreBleHost.attach(this)

        // `kAndroidBleHostInstalled` in `lib/services/kore_ble.dart` is still
        // false, deliberately, and this host does not flip it. The flag is what
        // `createEegSource()` reads, so flipping it takes the simulated source
        // off Android entirely - and the README leans on that demo. Turning it
        // on is a product decision about what an Android build *is*, not a
        // consequence of the Kotlin existing, so it is left to the repo owner
        // to make in its own commit. Until then this registration is live and
        // unreached: Dart never opens either channel.
    }

    override fun cleanUpFlutterEngine(flutterEngine: FlutterEngine) {
        // Order matters: drop the channel from the shared holder first, so an
        // action arriving during teardown is queued rather than invoked on a
        // messenger whose engine is going away.
        KoreActions.detach()
        channel?.setMethodCallHandler(null)
        channel = null
        // Same order, same reason, one rung further: the host drops its sink,
        // stops any scan and closes the GATT *before* the channels it would
        // speak on are unhooked, so nothing is emitted onto a messenger whose
        // engine is going away. Closing the GATT here rather than holding it is
        // deliberate - an unclosed `BluetoothGatt` keeps one of the system's
        // few client interfaces forever, and there is no foreground service to
        // make an outliving link worth anything.
        KoreBleHost.detach()
        bleEvents?.setStreamHandler(null)
        bleEvents = null
        bleChannel?.setMethodCallHandler(null)
        bleChannel = null
        // A Future that never completes is worse than one that answers false:
        // `StrainNotifier.requestPermission()` awaits this, and a permanently
        // pending await is a permission state the app can never leave.
        permissionResult?.success(false)
        permissionResult = null
        super.cleanUpFlutterEngine(flutterEngine)
    }

    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        consumeNotificationAction(intent)
    }

    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        consumeNotificationAction(intent)
    }

    /**
     * `Reset`, arriving either as a cold launch or - thanks to `singleTop` - as
     * a new intent on the running instance.
     *
     * The extra is removed once read. The activity keeps its launch intent, so
     * a recreate (a process-death restore, a config change outside the set the
     * manifest handles) would otherwise replay the press and start a protocol
     * the user asked for once, minutes ago.
     */
    private fun consumeNotificationAction(intent: Intent?) {
        val action = intent?.getStringExtra(KoreActions.EXTRA) ?: return
        intent.removeExtra(KoreActions.EXTRA)
        StrainNotification.clear(this)
        KoreActions.deliver(action)
    }

    private fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "requestNotificationPermission" -> requestNotificationPermission(result)

            // The cold-start half of action delivery. Dart calls this once, from
            // its constructor, because a press that started the process cannot
            // be pushed to a handler that press has not finished creating.
            // `takePending` returns and clears together, which is what keeps
            // this and the `onAction` push from both delivering the same press:
            // whichever reads the slot first is the one that empties it.
            "takePendingAction" -> result.success(KoreActions.takePending())

            "showStrain" -> {
                // The body is rendered verbatim. Dart owns this copy - it knows
                // the episode duration and the rounding rule - and a host that
                // re-pluralised or appended to it would be a second, quietly
                // different voice for the same fact.
                val body = call.argument<String>("body")
                if (body == null) {
                    result.error("bad_args", "showStrain requires a body", null)
                    return
                }
                StrainNotification.show(this, body)
                result.success(null)
            }

            "clearStrain" -> {
                StrainNotification.clear(this)
                result.success(null)
            }

            "setKeepScreenOn" -> {
                setKeepScreenOn(call.argument<Boolean>("on") == true)
                result.success(null)
            }

            // Not `result.error`. The Dart half treats an unimplemented method
            // as the inert case on purpose, so a Dart build newer than the
            // installed APK degrades instead of throwing into a frame.
            else -> result.notImplemented()
        }
    }

    /**
     * Below API 33 there is no runtime permission to ask for, so the honest
     * answer to "may I post?" is whether the user has notifications switched on
     * for the app - which is the same question, asked of the only authority
     * that has it.
     */
    private fun requestNotificationPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) {
            val manager = getSystemService(NotificationManager::class.java)
            result.success(manager?.areNotificationsEnabled() == true)
            return
        }
        if (checkSelfPermission(Manifest.permission.POST_NOTIFICATIONS)
            == PackageManager.PERMISSION_GRANTED
        ) {
            result.success(true)
            return
        }
        // No activity left to put a dialog on. False is a normal answer here -
        // every caller is required to keep working without the permission - and
        // it beats an IllegalStateException crossing the channel.
        if (isFinishing || isDestroyed || permissionResult != null) {
            result.success(false)
            return
        }
        permissionResult = result
        requestPermissions(
            arrayOf(Manifest.permission.POST_NOTIFICATIONS),
            REQUEST_POST_NOTIFICATIONS,
        )
    }

    override fun onRequestPermissionsResult(
        requestCode: Int,
        permissions: Array<out String>,
        grantResults: IntArray,
    ) {
        // super first: the embedding forwards this to the plugin registry, and
        // intercepting it before that would break anything else that asks.
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        when (requestCode) {
            REQUEST_POST_NOTIFICATIONS -> {
                val pending = permissionResult ?: return
                permissionResult = null
                // An empty grantResults means the request was cancelled, which
                // is a refusal as far as the app is concerned.
                pending.success(
                    grantResults.isNotEmpty() &&
                        grantResults[0] == PackageManager.PERMISSION_GRANTED,
                )
            }

            // Forwarded rather than answered here: the BLE answer is not a
            // `MethodChannel.Result` at all. `startScan` was already completed
            // before the dialog went up, so a denial has to travel up the event
            // stream as a `failed` with a sentence on it, and only the host
            // knows what it was about to do next.
            KoreBleHost.REQUEST_PERMISSIONS ->
                KoreBleHost.onPermissionsResult(permissions, grantResults)
        }
    }

    /**
     * Scoped to the 60 s reset, released at the end - `KorePlatform` documents
     * why, and the flag is set on the window rather than on a view because the
     * Flutter view is not this file's to reach into.
     *
     * `runOnUiThread` even though the channel handler already runs there: it is
     * a no-op when it is already true, and it is the guarantee `WindowManager`
     * actually requires rather than one inherited from the caller.
     */
    private fun setKeepScreenOn(on: Boolean) {
        runOnUiThread {
            if (isDestroyed) return@runOnUiThread
            if (on) {
                window.addFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            } else {
                window.clearFlags(WindowManager.LayoutParams.FLAG_KEEP_SCREEN_ON)
            }
        }
    }

    private companion object {
        const val REQUEST_POST_NOTIFICATIONS = 0x4B4F // 'KO'
    }
}
