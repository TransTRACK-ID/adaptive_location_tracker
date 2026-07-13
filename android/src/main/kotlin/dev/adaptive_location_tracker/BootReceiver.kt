package dev.adaptive_location_tracker

import android.content.BroadcastReceiver
import android.content.Context
import android.content.Intent
import androidx.core.content.ContextCompat

/**
 * Restarts [LocationTrackingService] after a device reboot if tracking was
 * active when the device was shut down.
 *
 * Requires the host app to declare RECEIVE_BOOT_COMPLETED and register this
 * receiver -- see MIGRATION.md / the package's AndroidManifest.xml, which is
 * merged into the host app automatically.
 */
class BootReceiver : BroadcastReceiver() {
    override fun onReceive(context: Context, intent: Intent) {
        if (intent.action != Intent.ACTION_BOOT_COMPLETED) return

        val prefs = context.getSharedPreferences(
            LocationTrackingService.TRACKING_PREFS, Context.MODE_PRIVATE,
        )
        if (!prefs.getBoolean(LocationTrackingService.KEY_IS_ACTIVE, false)) return

        val startIntent = Intent(context, LocationTrackingService::class.java).apply {
            action = LocationTrackingService.ACTION_START
        }
        ContextCompat.startForegroundService(context, startIntent)
    }
}
