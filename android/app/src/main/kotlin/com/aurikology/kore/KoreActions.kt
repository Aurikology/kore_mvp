package com.aurikology.kore

import android.app.PendingIntent
import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import io.flutter.plugin.common.MethodChannel

/**
 * Where notification presses land, and how they reach a [MethodChannel] that
 * may not exist when they land.
 *
 * A `PendingIntent` is delivered by the system to an activity or a receiver, so
 * by the time an action fires the engine is in one of two states and the host
 * does not get to pick which. Live: hand it straight over. Dead - the process
 * reaped while the banner sat in the shade, which is the *ordinary* case for a
 * notification the user gets to twenty minutes later - and there is nothing to
 * hand it to. Dropping it there is the failure that makes the tier
 * untrustworthy: a `Reset` that does nothing teaches the user once that the
 * button is a lie, and they never press it again.
 *
 * Hence one pending slot. A slot and not a queue: the tier posts one banner per
 * episode, so there is at most one unanswered action, and a queue would only
 * preserve a stale `dismiss` behind the fresh `reset` that supersedes it.
 *
 * ## Two ways out of the slot, and exactly one delivery
 *
 * The host cannot push its way out of a cold start. The press is what *creates*
 * the process, so at engine-attach time there is no `setMethodCallHandler` on
 * the Dart side to receive an `onAction` - pushing there fires into nothing.
 * So the cold path is a pull: Dart calls `takePendingAction` from
 * `AndroidKorePlatform`'s constructor, at the first instant there is somewhere
 * for an action to land. The warm path stays a push, because an action arriving
 * at `onNewIntent` on a running app should not wait for a poll that already
 * happened at startup.
 *
 * Both routes read the slot through [takePending], which returns and clears in
 * one step. That is what makes delivery exactly-once, and exactly-once is the
 * property that matters: a `Reset` press must start one protocol, never zero
 * and never two. Two is not a lesser bug than zero here - it would restart a
 * running 60 s protocol from the top.
 */
object KoreActions {
    const val RESET = "reset"
    const val DISMISS = "dismiss"

    /** Fully qualified - this rides on the launch intent of an exported activity. */
    const val EXTRA = "com.aurikology.kore.extra.NOTIFICATION_ACTION"

    private const val REQUEST_RESET = 1
    private const val REQUEST_DISMISS = 2

    /**
     * Both fields are touched only on the main thread: [attach] and [detach]
     * from the activity's lifecycle, [deliver] from `onReceive` (which Android
     * already runs there) or from the activity's own intent handling, and
     * [takePending] from the channel handler. That single thread is what makes
     * take-and-clear atomic without a lock, and a lock here would imply a
     * background caller that does not exist - and hide one if it ever appeared.
     */
    private var channel: MethodChannel? = null
    private var pending: String? = null

    /**
     * Set only once the first Flutter frame has rendered, *not* when the engine
     * is constructed. `configureFlutterEngine` runs before the Dart entrypoint
     * executes, so this field non-null is meant to carry a stronger claim than
     * "an engine object exists": it means there is provably a running isolate
     * for a pushed `onAction` to reach. Before that, [deliver] finds null and
     * leaves the action in the slot for `takePendingAction` to pull.
     */
    fun attach(methodChannel: MethodChannel) {
        channel = methodChannel
    }

    fun detach() {
        channel = null
    }

    /**
     * Returns the queued action and clears it in the same step, so whichever of
     * the two routes reads it first is the only one that delivers it. Serving
     * `takePendingAction`; also the read [deliver] uses before it pushes.
     */
    fun takePending(): String? {
        val queued = pending
        pending = null
        return queued
    }

    /**
     * Queue first, then push if there is a live channel - rather than branching
     * on the channel and only queueing in the else. The two are equivalent
     * until an exception crosses `invokeMethod`, and then this order is the one
     * that has not thrown the press away.
     *
     * `dismiss` is queued alongside `reset`, even though a stale one can arrive
     * into a session with no episode running. That is harmless - Dart scopes
     * the suppression to the episode it finds, and finds none - whereas
     * dropping it re-shows a banner the user has already declined the moment
     * they open the app.
     */
    fun deliver(action: String) {
        pending = action
        val live = channel ?: return
        val queued = takePending() ?: return
        live.invokeMethod("onAction", queued)
    }

    /**
     * Goes to the activity, not to a receiver: `Reset` has to bring the app to
     * the front, and only an activity intent does that. `singleTop` in the
     * manifest turns the re-launch into `onNewIntent` on the existing instance
     * rather than a second dashboard stacked on the first.
     */
    fun resetIntent(context: Context): PendingIntent =
        PendingIntent.getActivity(
            context,
            REQUEST_RESET,
            Intent(context, MainActivity::class.java)
                .putExtra(EXTRA, RESET)
                .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_SINGLE_TOP),
            // IMMUTABLE is required from API 31 and right everywhere else:
            // nothing downstream may rewrite which action this carries.
            // UPDATE_CURRENT so a cached instance takes the current extras
            // instead of replaying an older action.
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )

    /**
     * Goes to a receiver, so `Not now` does not raise the app. Declining a
     * reading and being shown the dashboard for your trouble is the opposite of
     * what the button says.
     */
    fun dismissIntent(context: Context): PendingIntent =
        PendingIntent.getBroadcast(
            context,
            REQUEST_DISMISS,
            Intent(context, NotificationActionReceiver::class.java)
                .setAction("$EXTRA.$DISMISS")
                .putExtra(EXTRA, DISMISS),
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
}

/**
 * Receives `Not now`. Non-exported in the manifest: nothing outside the app may
 * fire it, and a forged dismiss would silence a reading the user never saw.
 */
class NotificationActionReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        val action = intent.getStringExtra(KoreActions.EXTRA) ?: return
        // Taken down here rather than left for Dart to clear, because the
        // engine may be dead and a banner that survives the press answering it
        // is the same class of lie as one that outlives the episode.
        StrainNotification.clear(context.applicationContext)
        KoreActions.deliver(action)
    }
}
