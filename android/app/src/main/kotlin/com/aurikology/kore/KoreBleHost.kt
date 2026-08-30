package com.aurikology.kore

import android.Manifest
import android.app.Activity
import android.bluetooth.BluetoothAdapter
import android.bluetooth.BluetoothDevice
import android.bluetooth.BluetoothGatt
import android.bluetooth.BluetoothGattCallback
import android.bluetooth.BluetoothGattCharacteristic
import android.bluetooth.BluetoothGattDescriptor
import android.bluetooth.BluetoothManager
import android.bluetooth.BluetoothProfile
import android.bluetooth.BluetoothStatusCodes
import android.bluetooth.le.ScanCallback
import android.bluetooth.le.ScanFilter
import android.bluetooth.le.ScanResult
import android.bluetooth.le.ScanSettings
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.pm.PackageManager
import android.location.LocationManager
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.os.ParcelUuid
import android.provider.Settings
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.util.UUID

/**
 * The Android half of `lib/services/kore_ble.dart`.
 *
 * The file name is the one `docs/hardware-seam.md` promised; the *type* is not
 * a `FlutterPlugin`, because this repo has no plugin registry to register with.
 * `MainActivity` wires the channels by hand, exactly as it does for
 * `kore/platform`, and for the reason that whole seam exists: a `MethodChannel`
 * written here adds nothing to `pubspec.yaml` and no `dependencies` block to
 * `android/app/build.gradle.kts`. Everything below is `android.bluetooth.*`
 * from the framework - not a line of AndroidX, for the reason
 * `StrainNotification.kt` sets out at length: it is on the classpath through
 * the embedding, but nothing here *declares* it, and an undeclared dependency
 * is precisely the thing the in-repo channel was chosen to avoid.
 *
 * ## This is a pipe, and that is the whole design
 *
 * It scans, connects, negotiates an MTU, subscribes, hands bytes up, and says
 * what the link is doing. It decides nothing. It does not parse [KorePacket],
 * does not count gaps, does not measure the sample rate and does not judge a
 * payload malformed - all four live in `BleEegSource` on the Dart side, where
 * they run on the host VM against a fake channel. That is the only reason any
 * of this is checkable before there is a patch to check it against, and every
 * byte of parsing moved down here would be a byte of behaviour no test on this
 * machine can see.
 *
 * The consequence for a corrupt notification is worth stating plainly, because
 * the instinct is to be helpful: a payload that looks wrong is forwarded
 * anyway. `KorePacket.decode` refuses it whole and emits nothing, and the
 * *next* packet reports the gap exactly through its own `firstSampleIndex`.
 * A host that dropped it instead would remove the evidence and leave Dart
 * differencing against an index the device abandoned.
 *
 * ## One stream, one handler, one order
 *
 * Payloads and link transitions share `kore/ble/stream` so they stay ordered
 * with respect to each other - `kore_ble.dart` calls that ordering load-bearing
 * and it is: a `reconnecting` that overtook the last packets of a dying stream
 * would clear Dart's expected sample index while those packets were still in
 * flight, and the first packet after it would be differenced against nothing.
 *
 * `BluetoothGattCallback` runs on a binder thread and `EventChannel.EventSink`
 * is main-thread-only, so both have to hop. They hop through **one**
 * [handler], never two and never a mix of a posted path and a direct call:
 * a single FIFO queue is what turns "these happened in this order down here"
 * into "these arrive in this order up there". This is where the host differs
 * from `KoreActions`, whose KDoc gets to claim main-thread-only access as the
 * reason it needs no lock. Nothing here is main-thread-only on arrival; the
 * post is what makes it so, and every mutable field below is read and written
 * only from inside a posted block for exactly that reason.
 *
 * ## Failures travel up the stream, never back down the method channel
 *
 * `AndroidKoreBle._invoke` catches `PlatformException`, `debugPrint`s it and
 * returns normally, so `BleEegSource.start()`'s try/catch around `startScan`
 * can never fire. A `result.error(...)` from here is therefore invisible: the
 * pairing screen would sit on "scanning" forever with nothing on it to read.
 * Both methods answer `success(null)` unconditionally and every user-visible
 * failure is a `failed` event with a *sentence* in it.
 */
object KoreBleHost : EventChannel.StreamHandler {

    /**
     * Provisional, and they must match the firmware the day there is firmware.
     *
     * There is no patch yet, so these are invented - deliberately in one place
     * and deliberately not derived from the Bluetooth SIG base, so a reader can
     * tell at a glance that they are KORE's own and not a standard profile
     * something else might also answer to. `6b6f7265` is "kore" in ASCII.
     *
     * Nothing else in this repo may restate them. A second copy of a UUID is a
     * second thing that can disagree with the first, and the disagreement shows
     * up as a patch that advertises, connects, and then has no service on it.
     */
    private val KORE_SERVICE_UUID: UUID =
        UUID.fromString("6b6f7265-0001-4b4f-9245-524500000001")
    private val KORE_STREAM_UUID: UUID =
        UUID.fromString("6b6f7265-0002-4b4f-9245-524500000002")

    /**
     * Standard, not provisional. The Battery Service is a SIG profile, so if
     * the patch exposes one at all it exposes it here - 0x180F with the level
     * at 0x2A19.
     */
    private val BATTERY_SERVICE_UUID: UUID =
        UUID.fromString("0000180f-0000-1000-8000-00805f9b34fb")
    private val BATTERY_LEVEL_UUID: UUID =
        UUID.fromString("00002a19-0000-1000-8000-00805f9b34fb")

    /**
     * The Client Characteristic Configuration Descriptor, universal.
     *
     * `setCharacteristicNotification` sets a flag inside the Android stack
     * meaning "deliver this to my callback" and sends nothing over the air.
     * The peripheral starts sending when *this* is written. Skip either half
     * and the failure is silent in its own direction: without the local call
     * the patch streams and Android throws the notifications away, without the
     * descriptor write the callback is armed and nothing ever arrives.
     */
    private val CCCD_UUID: UUID =
        UUID.fromString("00002902-0000-1000-8000-00805f9b34fb")

    /**
     * The six names `BleLinkState` will accept, spelled once.
     *
     * `BleLinkEvent.fromMap` matches these against the enum by `.name` and
     * returns null for anything else, and a null there drops the *entire*
     * message - state, name, battery and failure together, with no error on
     * either side. "Streaming" with a capital S is a pairing screen that scans
     * forever. Hence constants rather than literals at eight call sites.
     */
    private const val STATE_IDLE = "idle"
    private const val STATE_SCANNING = "scanning"
    private const val STATE_CONNECTING = "connecting"
    private const val STATE_STREAMING = "streaming"
    private const val STATE_RECONNECTING = "reconnecting"
    private const val STATE_FAILED = "failed"

    /**
     * The request code for the Bluetooth runtime permissions.
     *
     * It lives here rather than beside `REQUEST_POST_NOTIFICATIONS` in
     * `MainActivity`'s companion because this object is what calls
     * `requestPermissions`, and a code owned by one file and issued by another
     * is a pair that can drift. `MainActivity` only forwards the result, and it
     * branches on this constant by name. Same idiom as its neighbour: 'BE'.
     */
    const val REQUEST_PERMISSIONS = 0x4245 // 'BE'

    /**
     * 517 is the largest ATT MTU Android will ask for, and asking for it is not
     * optional.
     *
     * A notification payload is capped at MTU minus 3, and the default MTU is
     * 23 - so twenty bytes, against a `KorePacket` whose header alone is twelve
     * before a four-pad table adds twelve more. `KorePacket.decode` requires
     * the length to match its header *exactly*, so at the default every single
     * notification is refused and `BleEegSource._onPacket` returns without
     * publishing and without reporting a fault. The symptom of forgetting this
     * line is a link that reaches `streaming`, notifies at full rate, and
     * produces no readings at all, with nothing anywhere saying why.
     *
     * The firmware sizes its packet to the negotiated MTU. The host never
     * reassembles and never splits: one notification is one whole packet, by
     * construction, because the format carries no length prefix to stitch on.
     */
    private const val MTU = 517

    /**
     * Twenty seconds of not finding a patch is an answer; forever is not.
     *
     * Twenty rather than ten because a patch advertising on a slow interval to
     * save battery can genuinely take that long to be seen, and a scan that
     * gives up early reports "no patch found" for one that is sitting there.
     */
    private const val SCAN_TIMEOUT_MS = 20_000L

    /**
     * Since Android 7.0 - which is this app's `minSdk` - the framework keeps
     * the last five scan windows per app over a rolling thirty seconds and
     * refuses the sixth. Below API 31 it refuses it *silently*: `startScan`
     * returns, `onScanFailed` never fires, and no result ever arrives. A retry
     * loop reaches that state in seconds and then looks exactly like a patch
     * that is switched off, so the limit is enforced here where it can be said
     * out loud instead of discovered in logcat.
     */
    private const val SCAN_WINDOW_MS = 30_000L
    private const val SCAN_WINDOW_STARTS = 5

    /** `autoConnect = false` gives up around thirty seconds; beat it slightly. */
    private const val CONNECT_TIMEOUT_MS = 25_000L

    /** `autoConnect = true` has no timeout of its own, so it needs one. */
    private const val RECONNECT_TIMEOUT_MS = 20_000L

    /** Reconnecting immediately after a drop returns status 133. Let it settle. */
    private const val RECONNECT_SETTLE_MS = 500L

    /** After this many, "reconnecting" has stopped being true. */
    private const val MAX_RECONNECTS = 3

    /**
     * `close()` releases the GATT client interface; skipping it leaks one
     * permanently. If the graceful teardown's callback never comes, this fires
     * anyway - see [closeGatt].
     */
    private const val CLOSE_FALLBACK_MS = 2_000L

    /** Used when the advertisement carries no name. Never fabricated further. */
    private const val UNNAMED_PATCH = "KORE patch"

    /**
     * The user-facing name of the toggle, which is not the name of the
     * permission. On API 31+ the switch in Settings says "Nearby devices";
     * telling someone to enable "BLUETOOTH_SCAN" sends them looking for
     * something that is not there.
     */
    private val PERMISSION_SENTENCE: String
        get() = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            "KORE needs the Nearby devices permission to find your patch."
        } else {
            "KORE needs the Location permission to find your patch - Android " +
                "requires it for Bluetooth scanning on this version."
        }

    private val handler = Handler(Looper.getMainLooper())

    /**
     * Held only to ask for permissions, which is the one thing an application
     * context cannot do. [appContext] is what the GATT and the receiver get, so
     * a connection outlives an activity recreate rather than holding a
     * destroyed one - and both are nulled in [detach], because a singleton with
     * an `Activity` in it is a leaked window.
     */
    private var activity: Activity? = null
    private var appContext: Context? = null

    private var sink: EventChannel.EventSink? = null

    /**
     * The last link transition, replayed to a sink that arrives after it.
     *
     * A slot, not a queue, for the reason `KoreActions` gives about its own:
     * only the newest matters, and a queue would deliver a stale `scanning`
     * behind the `streaming` that superseded it. Two things make it necessary.
     * `AndroidKoreBle` subscribes from its constructor while `BleEegSource`
     * calls `startScan` afterwards on a *different* channel, and the two
     * messages are not ordered against each other - so a `scanning` emitted
     * inside `startScan` can be handed to a sink that does not exist yet, after
     * which Dart sits on the state it published locally and never hears
     * anything again. And the hardware-seam case proper: a patch that
     * reconnected while there was no engine would otherwise leave Dart at
     * `idle` forever.
     *
     * Payloads get none of this - see [forward].
     */
    private var latched: HashMap<String, Any?>? = null

    private var scanning = false
    private var scanOnceGranted = false
    private val scanStarts = ArrayDeque<Long>()

    private var gatt: BluetoothGatt? = null
    private var streamCharacteristic: BluetoothGattCharacteristic? = null

    private var deviceAddress: String? = null
    private var deviceName: String? = null
    private var batteryPercent: Int? = null

    /**
     * Whether this device has ever streamed since the scan that found it. It is
     * what separates "the connection dropped" - which is a `reconnecting` -
     * from "it never came up", which is a `failed` and must not be retried
     * silently behind a screen claiming to be reconnecting to something it
     * never reached.
     */
    private var linkedOnce = false
    private var reconnects = 0

    /** Set only for a teardown we asked for, so the drop is not read as a loss. */
    private var tearingDown = false

    private var adapterWatch: BroadcastReceiver? = null

    // ---------------------------------------------------------------- wiring

    /**
     * Called from `configureFlutterEngine`, at the same point `kore/platform`
     * is wired. Unlike `KoreActions.attach` this needs no first-frame dance:
     * an `EventChannel` tells the host when Dart is listening, through
     * [onListen], which is a stronger handshake than a rendered frame.
     */
    fun attach(host: Activity) {
        activity = host
        appContext = host.applicationContext
        watchAdapter()
    }

    /**
     * Everything goes, including the link.
     *
     * The alternative - keeping a GATT alive across an engine teardown so a
     * session survives - would need a foreground service with
     * `connectedDevice` type, and that is a scope decision rather than a
     * plumbing one. Without it the process is reaped at the OS's discretion
     * anyway, so a connection held past this point is one nothing is left to
     * read from. Leaking it, on the other hand, is permanent: Android has
     * around thirty-two GATT client interfaces system-wide and an unclosed
     * `BluetoothGatt` holds one until the process dies. Leak enough across hot
     * restarts and *every* `connectGatt` starts failing with status 133, with
     * nothing anywhere saying why.
     */
    fun detach() {
        unwatchAdapter()
        stopScanning()
        closeGatt()
        handler.removeCallbacksAndMessages(null)
        sink = null
        latched = null
        scanOnceGranted = false
        deviceAddress = null
        deviceName = null
        batteryPercent = null
        linkedOnce = false
        reconnects = 0
        activity = null
        appContext = null
    }

    /**
     * Two methods, both without arguments, both answered `success(null)`.
     *
     * Not `result.error` in the else branch, for the reason `MainActivity`
     * gives about its own: a Dart build newer than the installed APK should
     * degrade rather than throw into the frame that called it, and
     * `AndroidKoreBle._invoke` is written to treat an unimplemented method as
     * the inert case.
     */
    fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            // Completing means scanning *started*, not that a patch was found.
            // The find arrives on the stream, which is also where every way
            // this can fail arrives.
            "startScan" -> {
                result.success(null)
                beginScan()
            }

            // Safe with nothing scanning and nothing connected, and safe called
            // twice: Dart's `stop()` calls it after it has already cancelled
            // its own subscriptions, and a `start()` racing in behind it has to
            // find a host it can scan from again.
            "disconnect" -> {
                result.success(null)
                goIdle()
            }

            else -> result.notImplemented()
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
        // Drain the slot rather than clear it: `AndroidKoreBle.dispose()` and a
        // later constructor are a normal pair across a hot restart, and the
        // second subscriber deserves the same answer the first got.
        val pending = latched ?: return
        events?.success(pending)
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    /**
     * Forwarded by `MainActivity`, which owns the override.
     *
     * A denial has to be *said*. Silence here is a pairing screen that scans
     * forever, and the user has no way to connect the dialog they dismissed a
     * moment ago to the patch that never appears.
     */
    fun onPermissionsResult(permissions: Array<out String>, grantResults: IntArray) {
        val wanted = scanOnceGranted
        scanOnceGranted = false
        // Empty grantResults means the request was cancelled, which is a
        // refusal as far as the app is concerned - same reading
        // `MainActivity.onRequestPermissionsResult` already takes.
        val granted = grantResults.isNotEmpty() &&
            grantResults.all { it == PackageManager.PERMISSION_GRANTED }
        if (granted) {
            if (wanted) beginScan()
            return
        }
        val permanent = permissions.isNotEmpty() &&
            activity?.shouldShowRequestPermissionRationale(permissions[0]) == false
        fail(
            if (permanent) {
                PERMISSION_SENTENCE + " Turn it on in Settings to pair a patch."
            } else {
                PERMISSION_SENTENCE
            },
        )
    }

    // ------------------------------------------------------------- emitting

    /**
     * Every hop to the sink, and the only one.
     *
     * The `try` is not defensive noise. A `SecurityException` from a GATT call
     * on a binder thread - the shape a missing `BLUETOOTH_CONNECT` takes on
     * API 31+ - would otherwise take the process down with nothing having
     * reached Dart, so it is caught here and turned into the sentence that
     * describes it.
     */
    private fun onMain(block: () -> Unit) {
        handler.post {
            try {
                block()
            } catch (denied: SecurityException) {
                fail(PERMISSION_SENTENCE)
            }
        }
    }

    /**
     * One notification in, one `ByteArray` out, posted through [handler] with
     * everything else so the interleaving survives the trip.
     *
     * A `ByteArray` and nothing else: the standard codec sends it as the
     * `Uint8List` `AndroidKoreBle._onHostMessage` type-tests for, while a
     * `List<Byte>`, a `ByteBuffer` or a base64 `String` all fall through into
     * `BleLinkEvent.fromMap`, decode to null, and vanish with no error on
     * either side.
     *
     * Dropped when nothing is listening, never buffered. A queued packet
     * delivered late is differenced against a newer index, and
     * `KorePacket.samplesMissingSince` reads that backwards jump as a stream
     * restart rather than as a gap - so the corruption arrives silently, which
     * is worse than the loss. The loss is *countable*: `firstSampleIndex` is on
     * the wire precisely so a missing notification is arithmetic rather than
     * guesswork.
     */
    private fun forward(payload: ByteArray) {
        handler.post { sink?.success(payload) }
    }

    /**
     * One link transition.
     *
     * `name` and `battery` travel together or not at all, and that is enforced
     * here rather than remembered at each call site, because both halves of the
     * rule bite. `BleEegSource._identityFrom` returns the *previous*
     * `PatchIdentity` untouched when the name is absent, so a battery sent
     * without one is thrown away; and it builds a brand-new identity from the
     * single event when the name is present, so a name sent without a battery
     * nulls a level that was known a second ago and the screen reads "not
     * reported" for a patch that is fine.
     *
     * Absent means *unchanged*, which is the whole reason a `reconnecting`
     * passes neither: Dart keeps the patch it already has rather than blanking
     * the pairing screen while the link comes back.
     *
     * `battery` is only ever a real 0-100 reading or nothing. There is no 0xFF
     * sentinel on this path - `BleLinkEvent.fromMap` range-checks and nulls
     * anything outside - and a fabricated 100% is a worse answer than an
     * absent one, which is what `PatchIdentity` says in as many words.
     */
    private fun emit(
        state: String,
        name: String? = null,
        battery: Int? = null,
        failure: String? = null,
    ) {
        val event = HashMap<String, Any?>(4)
        event["state"] = state
        if (name != null) {
            event["name"] = name
            event["battery"] = if (battery != null && battery in 0..100) battery else null
        }
        if (failure != null) event["failure"] = failure
        // Delivered inline when this is already the main thread, posted when it
        // is not - and the difference is the ordering guarantee, not a
        // micro-optimisation.
        //
        // Payloads and transitions share one sink so they stay ordered with
        // respect to each other. [forward] is called straight from a binder
        // thread and costs exactly one hop. Almost every caller here is already
        // inside an [onMain] block, so an unconditional post cost *two*, and a
        // transition raised before a notification arrived would be delivered
        // after it. Dart would then clear its expected sample index behind
        // packets from the stream that index belonged to - which is the exact
        // failure the single stream exists to prevent, arriving through the
        // machinery meant to prevent it.
        if (Looper.myLooper() == handler.looper) {
            latched = event
            sink?.success(event)
        } else {
            handler.post {
                latched = event
                sink?.success(event)
            }
        }
    }

    // -------------------------------------------------------------- scanning

    /**
     * The order of the checks is the order of the honest answers.
     *
     * `bluetoothLeScanner` returns null whenever the adapter is off, so asking
     * `isEnabled` first is what turns "the radio is unavailable" into
     * "Bluetooth is turned off" - a sentence the user can act on.
     */
    private fun beginScan() {
        if (scanning) return
        // Already linked, or already on the way there. `BleEegSource.start()`
        // is idempotent on its side too; this is the second half of that.
        //
        // A GATT that is *being torn down* is neither, and treating it as a
        // live link is how a scan gets silently swallowed. [goIdle] leaves the
        // object alive on purpose so `dropped` can close it on the callback, so
        // for the two seconds of [CLOSE_FALLBACK_MS] this field is non-null
        // while nothing is connected. Cancel on the pairing screen and then Try
        // again inside that window is an ordinary thing for a person to do:
        // Dart's `stop()` returns the moment the method channel replies, its
        // `start()` publishes `scanning` locally and calls through - and this
        // would have returned without scanning and without saying so, leaving
        // the screen waiting on a scan that was never started. Finish the
        // teardown instead, which is what the caller is asking for anyway.
        if (gatt != null) {
            if (!tearingDown) return
            closeGatt()
        }

        val context = appContext
        val adapter = adapter()
        if (context == null || adapter == null) {
            fail("This phone has no Bluetooth radio, so KORE cannot reach a patch.")
            return
        }

        val missing = requiredPermissions().filter {
            context.checkSelfPermission(it) != PackageManager.PERMISSION_GRANTED
        }
        if (missing.isNotEmpty()) {
            val host = activity
            if (host == null || host.isFinishing || host.isDestroyed) {
                fail(PERMISSION_SENTENCE)
                return
            }
            // The Dart call has already been answered `success(null)`, so
            // nothing is held across the dialog and no Future is stranded by
            // it. The answer arrives at `onPermissionsResult`, which either
            // restarts this or says why it will not.
            scanOnceGranted = true
            host.requestPermissions(missing.toTypedArray(), REQUEST_PERMISSIONS)
            return
        }

        if (!adapter.isEnabled) {
            fail("Bluetooth is turned off.")
            return
        }
        if (locationServicesOff()) {
            // Below API 31 a scan is legally a location capability, and the
            // master toggle being off makes it return zero results with no
            // error and no callback - indistinguishable from a patch that is
            // not there.
            fail("Location needs to be switched on for Android to find Bluetooth devices.")
            return
        }
        if (scanThrottled()) {
            fail(
                "Android is limiting how often KORE can search for your patch. " +
                    "Wait half a minute and try again.",
            )
            return
        }

        val scanner = adapter.bluetoothLeScanner
        if (scanner == null) {
            fail("The Bluetooth radio is not available just now.")
            return
        }

        // Filtered, and not as an optimisation: since API 26 an *unfiltered*
        // scan returns nothing at all while the screen is off, silently. A
        // service-UUID filter is also offloaded to the controller, so it costs
        // a fraction of the battery an unfiltered one does.
        val filter = ScanFilter.Builder()
            .setServiceUuid(ParcelUuid(KORE_SERVICE_UUID))
            .build()
        val settings = ScanSettings.Builder()
            .setScanMode(ScanSettings.SCAN_MODE_LOW_LATENCY)
            .setCallbackType(ScanSettings.CALLBACK_TYPE_ALL_MATCHES)
            .setMatchMode(ScanSettings.MATCH_MODE_AGGRESSIVE)
            .setNumOfMatches(ScanSettings.MATCH_NUM_ONE_ADVERTISEMENT)
            .build()

        try {
            scanner.startScan(listOf(filter), settings, scanCallback)
        } catch (denied: SecurityException) {
            fail(PERMISSION_SENTENCE)
            return
        }
        scanning = true
        scanStarts.addLast(System.currentTimeMillis())
        handler.postDelayed(scanTimeout, SCAN_TIMEOUT_MS)
        // Only here, and only once per scan. `scanning` maps to a `SourceLink`
        // with a null patch, so emitting it again after a device has been named
        // erases the name and the battery from the pairing screen.
        emit(STATE_SCANNING)
    }

    private fun stopScanning() {
        handler.removeCallbacks(scanTimeout)
        if (!scanning) return
        scanning = false
        try {
            adapter()?.bluetoothLeScanner?.stopScan(scanCallback)
        } catch (denied: SecurityException) {
            // Nothing left to say: the scan is already over as far as this host
            // is concerned, and the caller is on its way to a failure or an
            // idle that will be reported on its own.
        }
    }

    /** Five starts in thirty seconds is the framework's limit, kept here too. */
    private fun scanThrottled(): Boolean {
        val cutoff = System.currentTimeMillis() - SCAN_WINDOW_MS
        while (scanStarts.isNotEmpty() && scanStarts.first() < cutoff) {
            scanStarts.removeFirst()
        }
        return scanStarts.size >= SCAN_WINDOW_STARTS
    }

    private val scanTimeout = Runnable {
        stopScanning()
        fail("No KORE patch found. Check that it is switched on and close by.")
    }

    private val scanCallback = object : ScanCallback() {
        override fun onScanResult(callbackType: Int, result: ScanResult) = onMain {
            // Results keep arriving for a moment after `stopScan` returns, and
            // the second one would open a second GATT against the first.
            if (!scanning) return@onMain
            stopScanning()
            // `scanRecord.deviceName`, not `result.device.name`: the advertised
            // name needs no permission, while `getName()` wants
            // BLUETOOTH_CONNECT on API 31+ and returns null for an unbonded
            // device the phone has never cached - which a patch being paired
            // for the first time is by definition.
            connect(result.device, result.scanRecord?.deviceName ?: UNNAMED_PATCH)
        }

        override fun onScanFailed(errorCode: Int) = onMain {
            // Through stopScanning, not by clearing the flag by hand:
            // SCAN_FAILED_ALREADY_STARTED means a scan *is* registered, and
            // dropping the flag without unregistering leaks it until the
            // process dies - after which the throttle counts it forever.
            stopScanning()
            fail(
                when (errorCode) {
                    // The throttle, on the releases that bother to report it.
                    SCAN_FAILED_SCANNING_TOO_FREQUENTLY ->
                        "Android is limiting how often KORE can search for your " +
                            "patch. Wait half a minute and try again."
                    SCAN_FAILED_FEATURE_UNSUPPORTED ->
                        "This phone does not support Bluetooth Low Energy."
                    SCAN_FAILED_OUT_OF_HARDWARE_RESOURCES ->
                        "The Bluetooth radio is busy. Close other Bluetooth apps " +
                            "and try again."
                    // ALREADY_STARTED and APPLICATION_REGISTRATION_FAILED both
                    // mean the stack is in a state only a restart clears, and
                    // neither has a distinct thing to tell the user.
                    else -> "Bluetooth could not start searching. Switch it off and on again."
                },
            )
        }
    }

    // ------------------------------------------------------------ connecting

    private fun connect(device: BluetoothDevice, name: String) {
        deviceAddress = device.address
        deviceName = name
        batteryPercent = null
        linkedOnce = false
        reconnects = 0
        // The earliest moment the patch has an identity, and the first event
        // that carries one - which matters beyond the pairing screen's label:
        // until a `PatchIdentity` exists, `BleEegSource._updateBattery` drops
        // the battery byte out of every packet too.
        emit(STATE_CONNECTING, name = name, battery = null)
        openGatt(device, autoConnect = false, timeout = CONNECT_TIMEOUT_MS)
    }

    /**
     * `autoConnect = false` for the connect straight off a scan, `true` only
     * for the reconnect after a drop.
     *
     * They are different operations wearing one flag. False is a *direct*
     * connect: an aggressive scan window, about a second to link, and a
     * timeout around thirty seconds that produces a status this host can turn
     * into a sentence. True queues a background connect with **no timeout at
     * all** - it never fails, so there is no moment at which the host could
     * honestly say the connection did not happen, which makes it wrong for a
     * user standing in front of a pairing screen and exactly right for a patch
     * that walked out of range and will walk back.
     *
     * `TRANSPORT_LE` is not optional. The three-argument overload defaults to
     * `TRANSPORT_AUTO`, which lets the stack try BR/EDR on a dual-mode device
     * and fail with status 133 for no discoverable reason.
     */
    private fun openGatt(device: BluetoothDevice, autoConnect: Boolean, timeout: Long) {
        val context = appContext ?: return
        closeGatt()
        tearingDown = false
        val opened = try {
            device.connectGatt(context, autoConnect, gattCallback, BluetoothDevice.TRANSPORT_LE)
        } catch (denied: SecurityException) {
            fail(PERMISSION_SENTENCE)
            return
        }
        if (opened == null) {
            fail("Could not open a connection to your patch.")
            return
        }
        gatt = opened
        handler.postDelayed(connectTimeout, timeout)
    }

    private val connectTimeout = Runnable {
        if (gatt == null) return@Runnable
        closeGatt()
        if (linkedOnce) retryOrGiveUp() else fail("Could not connect to your patch.")
    }

    /**
     * The GATT chain, strictly serial: one operation outstanding at a time,
     * each step started only by the callback of the one before it.
     *
     * The Android stack has no queue of its own, so two overlapping operations
     * make the second return false - or `ERROR_GATT_WRITE_REQUEST_BUSY` - and
     * simply not happen. The battery read is deliberately last, after the
     * subscribe has been confirmed, for exactly that reason: fired alongside
     * the descriptor write it is the usual way this bug arrives.
     */
    private val gattCallback = object : BluetoothGattCallback() {

        override fun onConnectionStateChange(g: BluetoothGatt, status: Int, newState: Int) =
            onMain {
                // A callback from a GATT we have already replaced or closed.
                // Closing is idempotent; acting on it would drive the state
                // machine from a connection that no longer exists.
                if (g !== gatt) return@onMain
                when (newState) {
                    BluetoothProfile.STATE_CONNECTED -> {
                        if (status != BluetoothGatt.GATT_SUCCESS) {
                            dropped(status)
                            return@onMain
                        }
                        g.discoverServices()
                    }
                    BluetoothProfile.STATE_DISCONNECTED -> dropped(status)
                    else -> Unit // CONNECTING and DISCONNECTING are not transitions Dart has.
                }
            }

        override fun onServicesDiscovered(g: BluetoothGatt, status: Int) = onMain {
            if (g !== gatt) return@onMain
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("Your patch did not describe itself. Switch it off and on again.")
                return@onMain
            }
            val characteristic = g.getService(KORE_SERVICE_UUID)
                ?.getCharacteristic(KORE_STREAM_UUID)
            if (characteristic == null) {
                // Android caches a peripheral's service table across
                // connections, so during firmware development this also fires
                // for a patch whose UUIDs changed under a cache the app cannot
                // clear - `BluetoothGatt.refresh()` is a hidden API and has
                // been blocked since API 28. Unpairing the patch, or toggling
                // Bluetooth, is the only cure and the sentence has to be one
                // an ordinary user can follow anyway.
                fail("That device is not a KORE patch, or its firmware is too old.")
                return@onMain
            }
            streamCharacteristic = characteristic
            // Refused rather than failed: a stack that will not negotiate is
            // not a reason to abandon the link, it is a reason to let the
            // firmware send smaller packets. Stalling here would be.
            if (!g.requestMtu(MTU)) subscribe()
        }

        override fun onMtuChanged(g: BluetoothGatt, mtu: Int, status: Int) = onMain {
            if (g !== gatt) return@onMain
            // Either status. A refused negotiation leaves the default MTU and
            // the firmware sizes down to it; the host does not forward the
            // number to Dart, because sizing is the one thing about the wire it
            // is allowed to know and nothing above it decides anything with.
            subscribe()
        }

        override fun onDescriptorWrite(
            g: BluetoothGatt,
            descriptor: BluetoothGattDescriptor,
            status: Int,
        ) = onMain {
            if (g !== gatt || descriptor.uuid != CCCD_UUID) return@onMain
            if (status != BluetoothGatt.GATT_SUCCESS) {
                fail("Your patch would not start sending readings.")
                return@onMain
            }
            handler.removeCallbacks(connectTimeout)
            linkedOnce = true
            reconnects = 0
            // Here and nowhere earlier. This is the first instant the
            // peripheral has actually been told to send, and `streaming` is the
            // only state in which a number on screen means anything.
            emit(STATE_STREAMING, name = deviceName, battery = batteryPercent)
            readBattery(g)
        }

        /**
         * The API 33+ form, which hands over a fresh array.
         *
         * No `super`. The framework's default implementation of this overload
         * re-dispatches to the deprecated two-argument one, so calling it would
         * deliver every notification twice - and Dart would read the repeated
         * `firstSampleIndex` as a stream restart rather than a duplicate,
         * because `samplesMissingSince` treats a backwards jump as exactly
         * that. The corruption would be silent.
         */
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
        ) {
            if (g !== gatt || characteristic.uuid != KORE_STREAM_UUID) return
            forward(value.copyOf())
        }

        /**
         * The pre-33 form, and the one that makes the copy mandatory.
         *
         * `characteristic.value` is a buffer the stack reuses. Because delivery
         * is deferred to the main thread, the next notification can overwrite it
         * before the post runs, and a half-overwritten frame does not fail
         * `KorePacket.decode`'s length check - it decodes into plausible
         * nonsense. Copy on the callback thread, post the copy.
         */
        @Suppress("DEPRECATION")
        override fun onCharacteristicChanged(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
        ) {
            if (g !== gatt || characteristic.uuid != KORE_STREAM_UUID) return
            forward(characteristic.value?.copyOf() ?: return)
        }

        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            value: ByteArray,
            status: Int,
        ) {
            // No `super`, same reason as the notification overload above.
            if (status != BluetoothGatt.GATT_SUCCESS) return
            onBatteryRead(g, characteristic, value)
        }

        @Suppress("DEPRECATION")
        override fun onCharacteristicRead(
            g: BluetoothGatt,
            characteristic: BluetoothGattCharacteristic,
            status: Int,
        ) {
            if (status != BluetoothGatt.GATT_SUCCESS) return
            onBatteryRead(g, characteristic, characteristic.value ?: return)
        }
    }

    private fun subscribe() = onMain {
        val g = gatt ?: return@onMain
        val characteristic = streamCharacteristic ?: return@onMain
        if (!g.setCharacteristicNotification(characteristic, true)) {
            fail("Your patch would not start sending readings.")
            return@onMain
        }
        val cccd = characteristic.getDescriptor(CCCD_UUID)
        if (cccd == null) {
            fail("Your patch's firmware cannot stream readings to this app.")
            return@onMain
        }
        val enable = BluetoothGattDescriptor.ENABLE_NOTIFICATION_VALUE
        // Split at API 33 the same way `StrainNotification.newBuilder` is split
        // at O, and for the same reason: `minSdk` is 24, so the old branch is
        // not legacy tidying, it is half the installed base.
        val written = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            g.writeDescriptor(cccd, enable) == BluetoothStatusCodes.SUCCESS
        } else {
            @Suppress("DEPRECATION")
            run {
                cccd.value = enable
                g.writeDescriptor(cccd)
            }
        }
        if (!written) fail("Your patch would not start sending readings.")
    }

    /**
     * Optional work, and it stays optional.
     *
     * `KorePacket` carries a battery byte of its own that Dart folds in, so a
     * patch with no Battery Service loses nothing here. What must never happen
     * is a number being invented to fill the gap: `PatchIdentity` documents
     * that an absent level renders as "not reported", and a fabricated 100% is
     * a worse answer than that.
     */
    private fun readBattery(g: BluetoothGatt) {
        val level = g.getService(BATTERY_SERVICE_UUID)
            ?.getCharacteristic(BATTERY_LEVEL_UUID)
            ?: return
        g.readCharacteristic(level)
    }

    private fun onBatteryRead(
        g: BluetoothGatt,
        characteristic: BluetoothGattCharacteristic,
        value: ByteArray,
    ) =
        onMain {
            // The same identity check every other callback makes, and the one
            // place it was missing. A battery read is fired the instant the CCCD
            // write confirms; if the patch walks out of range before answering,
            // the disconnect arrives first and the read result second. Without
            // this, the read would emit `streaming` *after* `reconnecting` -
            // forging the one state in which a number on screen means anything,
            // for a link that no longer exists.
            if (g !== gatt || tearingDown || !linkedOnce) return@onMain
            if (characteristic.uuid != BATTERY_LEVEL_UUID || value.isEmpty()) return@onMain
            val level = value[0].toInt() and 0xFF
            // Out of range means "not measured", and the honest way to say that
            // on this path is to say nothing - `BleLinkEvent.fromMap` nulls
            // anything outside 0-100 anyway, so a sentinel would be dropped
            // rather than interpreted.
            if (level !in 0..100 || level == batteryPercent) return@onMain
            batteryPercent = level
            // Re-sent with the name beside it, because Dart rebuilds the whole
            // identity from whichever event carries one - a battery arriving
            // alone would be discarded.
            emit(STATE_STREAMING, name = deviceName, battery = level)
        }

    // ---------------------------------------------------------- coming apart

    /**
     * A disconnection, of which there are three kinds and only one is a loss.
     */
    private fun dropped(status: Int) {
        if (tearingDown) {
            closeGatt()
            emit(STATE_IDLE)
            return
        }
        closeGatt()
        if (linkedOnce) {
            retryOrGiveUp()
            return
        }
        fail(
            when (status) {
                // 133 is the stack's catch-all and it is the one that actually
                // turns up. Naming the number would put a status code on a
                // pairing screen; the causes a user can do something about are
                // range and power, so those are what the sentence says.
                BluetoothGatt.GATT_SUCCESS ->
                    "Your patch disconnected before it started sending."
                else ->
                    "Could not connect to your patch. Move it closer and check it is charged."
            },
        )
    }

    /**
     * `reconnecting` carries no name, and that is the contract working rather
     * than an omission: absent means *unchanged*, so Dart keeps the
     * `PatchIdentity` it has and the pairing screen keeps saying which patch it
     * is waiting for. It is also emitted here - after the last packet of the
     * dying stream and before the first of the new one - because it is what
     * clears Dart's expected sample index and withdraws the measured rate.
     */
    private fun retryOrGiveUp() {
        val address = deviceAddress
        val adapter = adapter()
        if (address == null || adapter == null || reconnects >= MAX_RECONNECTS) {
            fail("Lost the connection to your patch.")
            return
        }
        reconnects += 1
        emit(STATE_RECONNECTING)
        // Reconnecting the instant a link drops returns status 133 on most
        // stacks. Half a second is the difference between a retry and three
        // wasted ones.
        handler.postDelayed(reconnectAttempt, RECONNECT_SETTLE_MS)
    }

    /**
     * A field, not a lambda handed straight to `postDelayed`.
     *
     * An anonymous Runnable cannot be cancelled, and this one has half a second
     * in which the user can press Cancel. Untracked, it would fire after
     * [goIdle] had already published `idle`, open a fresh GATT nobody asked
     * for, and leave a live radio behind a screen that says the link is down -
     * the one outcome the intentional stop is supposed to guarantee against.
     * [closeGatt] cancels it alongside the other two pending callbacks.
     *
     * The address and the adapter are read at run time rather than captured, so
     * a stale attempt cannot reconnect to a device the host has since forgotten.
     */
    private val reconnectAttempt = Runnable {
        val address = deviceAddress
        val adapter = adapter()
        if (address == null || adapter == null) return@Runnable
        val device = try {
            adapter.getRemoteDevice(address)
        } catch (unknown: IllegalArgumentException) {
            null
        }
        if (device == null) {
            fail("Lost the connection to your patch.")
        } else {
            openGatt(device, autoConnect = true, timeout = RECONNECT_TIMEOUT_MS)
        }
    }

    /**
     * The hard close: releases the client interface immediately and accepts
     * that no further callback will ever arrive on that object.
     *
     * `disconnect()` alone asks for a graceful teardown and keeps the interface
     * registered; `close()` is what gives it back. [goIdle] does the graceful
     * pair with a delayed fallback into here, because a teardown that waits for
     * a callback that never comes has leaked an interface permanently and a
     * teardown that closes at once tells the peripheral nothing.
     */
    private fun closeGatt() {
        handler.removeCallbacks(connectTimeout)
        handler.removeCallbacks(closeFallback)
        handler.removeCallbacks(reconnectAttempt)
        streamCharacteristic = null
        val live = gatt ?: return
        gatt = null
        tearingDown = false
        try {
            live.disconnect()
            live.close()
        } catch (denied: SecurityException) {
            // The interface is gone with the process either way; there is
            // nothing left to tell the user about a connection being torn down.
        }
    }

    private val closeFallback = Runnable {
        closeGatt()
        emit(STATE_IDLE)
    }

    /**
     * The intentional stop. Safe with nothing scanning, nothing connected, and
     * safe called twice - `disconnect` arrives from Dart's `stop()`, which may
     * itself run twice around a `start()`.
     */
    private fun goIdle() {
        stopScanning()
        handler.removeCallbacks(reconnectAttempt)
        scanOnceGranted = false
        deviceAddress = null
        deviceName = null
        batteryPercent = null
        linkedOnce = false
        reconnects = 0
        val live = gatt
        if (live == null) {
            emit(STATE_IDLE)
            return
        }
        // Graceful: ask for the teardown, let `dropped` close on the callback,
        // and close anyway if it does not come.
        tearingDown = true
        try {
            live.disconnect()
        } catch (denied: SecurityException) {
            closeGatt()
            emit(STATE_IDLE)
            return
        }
        handler.postDelayed(closeFallback, CLOSE_FALLBACK_MS)
    }

    private fun fail(sentence: String) {
        stopScanning()
        closeGatt()
        scanOnceGranted = false
        // No name, so Dart keeps whichever patch it already knew about. The
        // failure is about the link, not about which device it was to.
        emit(STATE_FAILED, failure = sentence)
    }

    // -------------------------------------------------------------- the radio

    /**
     * The adapter being switched off stops every GATT callback without
     * producing one, so without this the host sits in `connecting` forever and
     * the screen waits for a patch that cannot arrive.
     */
    private fun watchAdapter() {
        val context = appContext ?: return
        if (adapterWatch != null) return
        val receiver = object : BroadcastReceiver() {
            override fun onReceive(received: Context, intent: Intent) {
                if (intent.action != BluetoothAdapter.ACTION_STATE_CHANGED) return
                val state = intent.getIntExtra(
                    BluetoothAdapter.EXTRA_STATE,
                    BluetoothAdapter.ERROR,
                )
                if (state != BluetoothAdapter.STATE_TURNING_OFF &&
                    state != BluetoothAdapter.STATE_OFF
                ) {
                    return
                }
                // `onReceive` is already on the main thread, but this goes
                // through the same queue as everything else so it cannot
                // overtake packets that are still on it.
                onMain { fail("Bluetooth is turned off.") }
            }
        }
        val filter = IntentFilter(BluetoothAdapter.ACTION_STATE_CHANGED)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.TIRAMISU) {
            // A protected system broadcast is exempt from the API 34 rule, but
            // declaring the intent is free and keeps the exemption from being
            // the thing this depends on.
            context.registerReceiver(receiver, filter, Context.RECEIVER_NOT_EXPORTED)
        } else {
            context.registerReceiver(receiver, filter)
        }
        adapterWatch = receiver
    }

    private fun unwatchAdapter() {
        val receiver = adapterWatch ?: return
        adapterWatch = null
        try {
            appContext?.unregisterReceiver(receiver)
        } catch (never: IllegalArgumentException) {
            // Registered against a context that has already gone. Nothing to do
            // and nothing worth failing a teardown over.
        }
    }

    private fun adapter(): BluetoothAdapter? =
        appContext?.getSystemService(BluetoothManager::class.java)?.adapter

    /**
     * Both of the API 31+ permissions, together, rather than scan first and
     * connect when it is needed. A scan that succeeds and a connect that then
     * throws `SecurityException` from a binder thread is the worst split of the
     * two - the failure lands nowhere the user can see it and the patch is
     * visibly right there.
     *
     * Below 31, fine location and not coarse: a coarse-only grant yields a scan
     * that delivers nothing at all on API 29-30, with no error.
     */
    private fun requiredPermissions(): Array<String> =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
            arrayOf(
                Manifest.permission.BLUETOOTH_SCAN,
                Manifest.permission.BLUETOOTH_CONNECT,
            )
        } else {
            arrayOf(Manifest.permission.ACCESS_FINE_LOCATION)
        }

    /**
     * Only asked below API 31. With `neverForLocation` on `BLUETOOTH_SCAN` the
     * modern scan is not a location capability at all, so the toggle is not
     * this host's business there.
     */
    private fun locationServicesOff(): Boolean {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) return false
        val context = appContext ?: return false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            return context.getSystemService(LocationManager::class.java)
                ?.isLocationEnabled != true
        }
        @Suppress("DEPRECATION")
        return Settings.Secure.getInt(
            context.contentResolver,
            Settings.Secure.LOCATION_MODE,
            Settings.Secure.LOCATION_MODE_OFF,
        ) == Settings.Secure.LOCATION_MODE_OFF
    }
}
