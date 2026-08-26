package com.aurikology.kore

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Context
import android.os.Build

/**
 * Renders the strain tier. Nothing here decides *whether* to speak - that is
 * `StrainNotifier` on the Dart side, and it has to stay there: the rule is
 * about episodes and foreground state, neither of which this file can see.
 *
 * Written against `android.app.Notification` rather than
 * `androidx.core.app.NotificationCompat`. AndroidX is on the classpath
 * transitively through the Flutter embedding, but nothing in this repo
 * *declares* it, so compiling against it would be a dependency the build file
 * does not record - and not recording dependencies is the whole point
 * `docs/hardware-seam.md` makes about doing this in-repo. `minSdk` is 24, so
 * the compat class would be earning its keep on exactly one branch (the pre-O
 * channel fallback below), which is cheaper to write out than to depend on.
 */
object StrainNotification {

    /**
     * One id, reused. The spec says the tier "does not escalate if ignored";
     * at the platform level that sentence *is* this constant. Posting with a
     * fresh id per update would stack banners in the shade - escalation by
     * accumulation, even though no single notification ever changed.
     */
    private const val ID = 1

    /**
     * The id the Dart docs name. Stable on purpose: renaming it orphans the
     * user's per-channel settings and silently resurrects a channel they had
     * turned off.
     */
    private const val CHANNEL_ID = "kore_strain"

    /**
     * Button copy lives here rather than crossing the channel. The *body* is
     * Dart's - it carries the measurement and the duration, and the host must
     * not touch it - but these two labels are fixed chrome from
     * `docs/design/mobile.md` and never vary with the reading.
     */
    private const val RESET_LABEL = "Reset"
    private const val DISMISS_LABEL = "Not now"

    /**
     * Posts, or updates in place when one is already showing.
     *
     * Takes the rendered body and nothing else. The raw index used to cross
     * beside it and was never drawn: the body already states the number, and
     * the only slot a bare integer fits is `setNumber`, where 78 reads as
     * seventy-eight notifications. A second copy of the same fact on the far
     * side of a channel is a second thing that can disagree with the first, so
     * it is not carried until something here needs it.
     */
    fun show(context: Context, body: String) {
        val manager = context.getSystemService(NotificationManager::class.java) ?: return
        ensureChannel(manager)

        val notification = newBuilder(context)
            .setSmallIcon(R.drawable.ic_stat_kore)
            .setContentTitle("KORE")
            .setContentText(body)
            .setCategory(Notification.CATEGORY_STATUS)
            // Tapping the body means Reset. `NotificationAction.reset` on the
            // Dart side documents it, and the alternative - a tap that merely
            // opens the app - makes the two most obvious gestures on the same
            // banner do different things.
            .setContentIntent(KoreActions.resetIntent(context))
            .setAutoCancel(true)
            // The update path fires whenever the stated duration rolls over a
            // whole minute. Without this, each of those re-alerts, and a banner
            // that buzzes once a minute is the escalation this tier promises
            // not to be.
            .setOnlyAlertOnce(true)
            .addAction(action(RESET_LABEL, KoreActions.resetIntent(context)))
            .addAction(action(DISMISS_LABEL, KoreActions.dismissIntent(context)))
            // No setOngoing: a reading the user has decided not to act on must
            // still be swipeable. No setColor either - the palette has no alarm
            // colour on purpose, and inventing one here would be the host
            // contradicting the design.
            .build()

        manager.notify(ID, notification)
    }

    /** Safe when nothing is showing: `cancel` on an absent id is a no-op. */
    fun clear(context: Context) {
        context.getSystemService(NotificationManager::class.java)?.cancel(ID)
    }

    @Suppress("DEPRECATION")
    private fun newBuilder(context: Context): Notification.Builder =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O) {
            Notification.Builder(context, CHANNEL_ID)
        } else {
            // Pre-O has no channels, so importance is per-notification. DEFAULT,
            // not HIGH: HIGH is a heads-up banner thrown over whatever the user
            // is doing, and KORE states a bad reading plainly rather than
            // alarming about it. Nothing on this path calls setSound or
            // setDefaults, which is what keeps it silent - a pre-O notification
            // is quiet unless asked not to be.
            Notification.Builder(context).setPriority(Notification.PRIORITY_DEFAULT)
        }

    /**
     * Null icon, deliberately. Current Android does not draw action icons in
     * the shade, and AndroidX passes null here itself for a compat action that
     * carries none. Filling the slot with the KORE glyph would put the same
     * mark against two opposite choices.
     */
    private fun action(label: String, intent: PendingIntent): Notification.Action =
        Notification.Action.Builder(null, label, intent).build()

    /**
     * Created before each post rather than once at startup.
     * `createNotificationChannel` is idempotent for an id that already exists,
     * and creating it in `onCreate` instead would tie the tier's ability to
     * speak to the activity having run in this process - which is exactly not
     * true of a notification posted after a cold start.
     *
     * Sound and vibration are switched off explicitly: an IMPORTANCE_DEFAULT
     * channel plays the system notification sound unless told otherwise, so
     * "no sound, no vibration" is not the default here the way it is pre-O.
     * These stick - the user owns the channel after first creation, and
     * changing them in a later build will not move a channel already made.
     */
    private fun ensureChannel(manager: NotificationManager) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "Cognitive load",
            NotificationManager.IMPORTANCE_DEFAULT,
        ).apply {
            description = "Reports a measured cognitive load reading while an " +
                "episode of strain is running. It states the reading; it does " +
                "not alarm."
            setSound(null, null)
            enableVibration(false)
            enableLights(false)
        }
        manager.createNotificationChannel(channel)
    }
}
