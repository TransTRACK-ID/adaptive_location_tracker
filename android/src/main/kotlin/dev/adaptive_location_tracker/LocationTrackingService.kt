package dev.adaptive_location_tracker

import android.Manifest
import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.Service
import android.content.Context
import android.content.Intent
import android.content.IntentFilter
import android.content.SharedPreferences
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.net.ConnectivityManager
import android.net.Network
import android.net.NetworkCapabilities
import android.net.NetworkRequest
import android.net.Uri
import android.os.BatteryManager
import android.os.Build
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import androidx.core.app.NotificationCompat
import androidx.core.content.ContextCompat
import com.google.android.gms.location.FusedLocationProviderClient
import com.google.android.gms.location.LocationAvailability
import com.google.android.gms.location.LocationCallback
import com.google.android.gms.location.LocationRequest
import com.google.android.gms.location.LocationResult
import com.google.android.gms.location.LocationServices
import com.google.android.gms.location.Priority
import java.net.HttpURLConnection
import java.net.URL
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.TimeZone
import java.util.concurrent.atomic.AtomicBoolean
import android.location.LocationManager

/**
 * Generic native Android foreground service for live GPS tracking.
 *
 * Mirrors the iOS kill-survival service's architecture:
 *   - FusedLocationProviderClient for location updates
 *   - Movement mode inferred from GPS speed (see [LocationFilter]) --
 *     no ActivityRecognitionClient / ACTIVITY_RECOGNITION permission needed
 *   - ConnectivityManager.NetworkCallback triggers an immediate flush on
 *     reconnect
 *   - Handler heartbeat requests a fresh fix + flush on an interval
 *   - [LocationQueue] (SQLite) persists fixes that failed to send
 *   - SharedPreferences persists config + the last-sent-fix cache, shared
 *     with the host app's Dart `LocationCache`
 *
 * Every backend-shape assumption (query param names, the subject/id value)
 * is read from [trackingPrefs], set via [AdaptiveLocationTrackerPlugin.setTrackingConfig]
 * -- see `NativeEndpointConfig`/`NativeFieldKeys` on the Dart side.
 */
class LocationTrackingService : Service() {

    companion object {
        const val ACTION_START = "dev.adaptive_location_tracker.action.START"
        const val ACTION_STOP = "dev.adaptive_location_tracker.action.STOP"
        const val ACTION_FLUSH = "dev.adaptive_location_tracker.action.FLUSH"

        const val TRACKING_PREFS = "dev.adaptive_location_tracker.config"
        const val KEY_IS_ACTIVE = "is_active"
        const val KEY_TRACKING_URL = "tracking_url"
        const val KEY_SUBJECT_ID = "subject_id"

        // Field-key overrides -- one entry per NativeFieldKeys member.
        // Falls back to the same defaults as NativeFieldKeys() on the Dart side.
        const val KEY_FIELD_PREFIX = "field_"

        // loc_cache_* keys shared with Dart's LocationCache.
        // Dart setDouble -> Android putFloat, so we match that convention.
        private const val KEY_CACHE_LAT = "flutter.adaptive_location_tracker_loc_cache_lat"
        private const val KEY_CACHE_LON = "flutter.adaptive_location_tracker_loc_cache_lon"
        private const val KEY_CACHE_HEADING = "flutter.adaptive_location_tracker_loc_cache_heading"
        private const val KEY_CACHE_SPEED = "flutter.adaptive_location_tracker_loc_cache_speed"
        private const val KEY_CACHE_TIMESTAMP = "flutter.adaptive_location_tracker_loc_cache_timestamp"

        // Driving-floor interval hint for the FLP request; the mode-specific
        // floor is applied on top by LocationFilter.
        private const val FLP_INTERVAL_MS = 5_000L
        private const val FLP_MIN_DIST_M = 15f

        // Suppresses GPS warm-up / cached-fix artefacts right after (re)start.
        private const val STARTUP_GRACE_MS = 10_000L

        private const val HEARTBEAT_MS = 60_000L

        private const val NOTIF_CHANNEL_ID = "adaptive_location_tracker"
        private const val NOTIF_ID = 1001
    }

    private lateinit var fusedClient: FusedLocationProviderClient
    private lateinit var locationCallback: LocationCallback

    private val heartbeatHandler = Handler(Looper.getMainLooper())
    private val flushLock = AtomicBoolean(false)

    private var startTimeMs = 0L

    @Volatile private var lastFix: LastFix? = null
    @Volatile private var secondToLast: LastFix? = null

    private lateinit var trackingPrefs: SharedPreferences
    private lateinit var flutterPrefs: SharedPreferences
    private lateinit var queue: LocationQueue

    private var networkCallback: ConnectivityManager.NetworkCallback? = null

    // ── Field-key resolution (defaults mirror NativeFieldKeys() on Dart) ──────

    private fun fieldKey(name: String, default: String): String =
        trackingPrefs.getString(KEY_FIELD_PREFIX + name, default) ?: default

    // ── Service lifecycle ─────────────────────────────────────────────────────

    override fun onCreate() {
        super.onCreate()

        trackingPrefs = getSharedPreferences(TRACKING_PREFS, Context.MODE_PRIVATE)
        flutterPrefs = getSharedPreferences(LocationFilter.FLUTTER_PREFS, Context.MODE_PRIVATE)
        queue = LocationQueue.get(this)
        fusedClient = LocationServices.getFusedLocationProviderClient(this)

        locationCallback = object : LocationCallback() {
            override fun onLocationResult(result: LocationResult) {
                result.lastLocation?.let { onLocation(it) }
            }
            override fun onLocationAvailability(availability: LocationAvailability) {
                if (!availability.isLocationAvailable) {
                    flushQueue()
                }
            }
        }

        createNotificationChannel()
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) {
            startForeground(NOTIF_ID, buildNotification(), ServiceInfo.FOREGROUND_SERVICE_TYPE_LOCATION)
        } else {
            startForeground(NOTIF_ID, buildNotification())
        }

        loadCacheFromPrefs()
        registerNetworkCallback()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        when (intent?.action) {
            ACTION_START -> {
                trackingPrefs.edit().putBoolean(KEY_IS_ACTIVE, true).apply()
                startTimeMs = System.currentTimeMillis()
                startLocationUpdates()
                startHeartbeat()
            }
            ACTION_STOP -> {
                trackingPrefs.edit().putBoolean(KEY_IS_ACTIVE, false).apply()
                stopLocationUpdates()
                stopHeartbeat()
                queue.clear()
                ModeHysteresis.reset()
                stopForegroundAndCancelNotification()
                stopSelf()
                return START_NOT_STICKY
            }
            ACTION_FLUSH -> {
                if (trackingPrefs.getBoolean(KEY_IS_ACTIVE, false)) {
                    flushQueue()
                } else {
                    // Spun up only to service a flush request while no session
                    // is active -- retract the notification we were forced to
                    // post immediately and stop.
                    stopForegroundAndCancelNotification()
                    stopSelf()
                    return START_NOT_STICKY
                }
            }
            null -> {
                // Restarted by Android after being killed (START_STICKY).
                if (trackingPrefs.getBoolean(KEY_IS_ACTIVE, false)) {
                    startTimeMs = System.currentTimeMillis()
                    startLocationUpdates()
                    startHeartbeat()
                    flushQueue()
                }
            }
        }
        return START_STICKY
    }

    override fun onDestroy() {
        super.onDestroy()
        stopForegroundAndCancelNotification()
        stopLocationUpdates()
        stopHeartbeat()
        unregisterNetworkCallback()
    }

    override fun onBind(intent: Intent?): IBinder? = null

    // ── Location updates ──────────────────────────────────────────────────────

    private fun startLocationUpdates() {
        try {
            if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
                != PackageManager.PERMISSION_GRANTED
            ) return

            val request = LocationRequest.Builder(Priority.PRIORITY_HIGH_ACCURACY, FLP_INTERVAL_MS)
                .setMinUpdateDistanceMeters(FLP_MIN_DIST_M)
                .setWaitForAccurateLocation(false)
                .build()

            fusedClient.requestLocationUpdates(request, locationCallback, Looper.getMainLooper())

            // Forced fix before declaring the stream live, so the last-sent
            // cache baseline is a real GPS reading, not FLP's first (possibly
            // stale cached) delivery.
            fusedClient.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                .addOnSuccessListener { location ->
                    location ?: return@addOnSuccessListener
                    val url = trackingPrefs.getString(KEY_TRACKING_URL, "") ?: ""
                    val subjectId = trackingPrefs.getString(KEY_SUBJECT_ID, "") ?: ""
                    if (url.isEmpty() || subjectId.isEmpty()) return@addOnSuccessListener
                    val battery = getBatteryPct()
                    Thread {
                        val status = httpSend(url, subjectId, location, battery)
                        if (status in 200..299) {
                            val now = System.currentTimeMillis()
                            updateCacheOptimistic(location, now)
                            persistCacheToPrefs(location, now)
                        }
                    }.start()
                }
        } catch (e: Exception) {
            startLegacyLocationUpdates()
        }
    }

    private fun startLegacyLocationUpdates() {
        val lm = getSystemService(Context.LOCATION_SERVICE) as LocationManager
        if (ContextCompat.checkSelfPermission(this, Manifest.permission.ACCESS_FINE_LOCATION)
            != PackageManager.PERMISSION_GRANTED
        ) return
        lm.requestLocationUpdates(
            LocationManager.GPS_PROVIDER, 5_000L, 15f,
            { location -> onLocation(location) },
            Looper.getMainLooper(),
        )
    }

    private fun stopLocationUpdates() {
        fusedClient.removeLocationUpdates(locationCallback)
    }

    // ── Heartbeat ─────────────────────────────────────────────────────────────

    private val heartbeatRunnable = object : Runnable {
        override fun run() {
            if (!trackingPrefs.getBoolean(KEY_IS_ACTIVE, false)) return

            if (ContextCompat.checkSelfPermission(
                    this@LocationTrackingService,
                    Manifest.permission.ACCESS_FINE_LOCATION,
                ) == PackageManager.PERMISSION_GRANTED
            ) {
                fusedClient.getCurrentLocation(Priority.PRIORITY_HIGH_ACCURACY, null)
                    .addOnSuccessListener { loc -> loc?.let { onLocation(it) } }
            }
            flushQueue()
            heartbeatHandler.postDelayed(this, HEARTBEAT_MS)
        }
    }

    private fun startHeartbeat() =
        heartbeatHandler.postDelayed(heartbeatRunnable, HEARTBEAT_MS)

    private fun stopHeartbeat() =
        heartbeatHandler.removeCallbacks(heartbeatRunnable)

    // ── Core location callback ────────────────────────────────────────────────

    private fun onLocation(location: android.location.Location) {
        if (System.currentTimeMillis() - startTimeMs < STARTUP_GRACE_MS) return

        val url = trackingPrefs.getString(KEY_TRACKING_URL, "") ?: ""
        val subjectId = trackingPrefs.getString(KEY_SUBJECT_ID, "") ?: ""
        if (url.isEmpty() || subjectId.isEmpty()) return

        val battery = getBatteryPct()

        if (!LocationFilter.shouldSend(location, lastFix, secondToLast, battery, flutterPrefs)) return

        // Optimistic in-memory update -- prevents a burst of near-duplicate
        // fixes during the HTTP round-trip. Not reverted on failure: the
        // queued row is what guarantees no data is lost, and reverting would
        // re-open the duplicate-burst window.
        val sentAtMs = System.currentTimeMillis()
        updateCacheOptimistic(location, sentAtMs)

        Thread {
            val status = httpSend(url, subjectId, location, battery)
            when {
                status in 200..299 -> {
                    persistCacheToPrefs(location, sentAtMs)
                }
                status == -1 || status in 500..599 -> {
                    // Discard WiFi/cell-only fixes with no valid altitude --
                    // altitudeAccuracy <= 0 means no barometric measurement.
                    val hasValidAlt = location.altitude != 0.0 ||
                        (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O &&
                            location.verticalAccuracyMeters > 0)
                    if (hasValidAlt) {
                        queue.enqueue(
                            LocationEntry(
                                id = 0,
                                lat = location.latitude,
                                lon = location.longitude,
                                timestampSec = location.time / 1000.0,
                                accuracy = location.accuracy.toDouble(),
                                speed = location.speed.toDouble(),
                                heading = if (location.hasBearing()) location.bearing.toDouble() else -1.0,
                                altitude = location.altitude,
                                battery = battery,
                            ),
                        )
                    }
                }
                // 4xx -- malformed, don't queue
            }
        }.start()
    }

    // ── Queue flush ───────────────────────────────────────────────────────────

    private fun flushQueue() {
        if (!flushLock.compareAndSet(false, true)) return

        val url = trackingPrefs.getString(KEY_TRACKING_URL, "") ?: ""
        val subjectId = trackingPrefs.getString(KEY_SUBJECT_ID, "") ?: ""
        if (url.isEmpty() || subjectId.isEmpty()) {
            flushLock.set(false)
            return
        }

        Thread {
            try {
                val rows = queue.dequeueAll()
                if (rows.isEmpty()) return@Thread

                AdaptiveLocationTrackerPlugin.postSyncBegin(rows.size)

                var sent = 0
                var kept = 0
                var discarded = 0

                for (entry in rows) {
                    val status = httpSendEntry(url, subjectId, entry)
                    when {
                        status in 200..299 -> {
                            queue.delete(entry.id)
                            updateCacheFromEntry(entry)
                            persistCacheFromEntry(entry)
                            sent++
                        }
                        status in 400..499 -> {
                            queue.delete(entry.id) // malformed, won't ever succeed
                            discarded++
                        }
                        status == -1 -> {
                            kept += rows.size - sent - discarded
                            break
                        }
                        else -> kept++
                    }
                }
                AdaptiveLocationTrackerPlugin.postSyncEnd(sent, kept, discarded)
            } finally {
                flushLock.set(false)
            }
        }.start()
    }

    // ── HTTP ──────────────────────────────────────────────────────────────────
    //
    // Query param names are configurable per NativeFieldKeys (Dart side) so
    // this native sender can match any backend's contract without a fork.

    private fun httpSend(
        baseUrl: String,
        subjectId: String,
        location: android.location.Location,
        battery: Int,
    ): Int {
        val uri = Uri.parse(baseUrl).buildUpon()
            .appendQueryParameter(fieldKey("subjectId", "id"), subjectId)
            .appendQueryParameter(fieldKey("timestamp", "timestamp"), "${location.time / 1000L}")
            .appendQueryParameter(fieldKey("latitude", "lat"), "%.7f".format(location.latitude))
            .appendQueryParameter(fieldKey("longitude", "lon"), "%.7f".format(location.longitude))
            .appendQueryParameter(fieldKey("speed", "speed"), "%.2f".format(location.speed * 3.6))
            .appendQueryParameter(
                fieldKey("bearing", "bearing"),
                "%.1f".format(if (location.hasBearing()) location.bearing else 0f),
            )
            .appendQueryParameter(fieldKey("altitude", "altitude"), "%.1f".format(location.altitude))
            .appendQueryParameter(fieldKey("accuracy", "accuracy"), "%.1f".format(location.accuracy))
            .appendQueryParameter(fieldKey("battery", "batt"), "$battery")
            .build().toString()
        return httpPost(uri)
    }

    private fun httpSendEntry(baseUrl: String, subjectId: String, entry: LocationEntry): Int {
        val uri = Uri.parse(baseUrl).buildUpon()
            .appendQueryParameter(fieldKey("subjectId", "id"), subjectId)
            .appendQueryParameter(fieldKey("timestamp", "timestamp"), "%.0f".format(entry.timestampSec))
            .appendQueryParameter(fieldKey("latitude", "lat"), "%.7f".format(entry.lat))
            .appendQueryParameter(fieldKey("longitude", "lon"), "%.7f".format(entry.lon))
            .appendQueryParameter(fieldKey("speed", "speed"), "%.2f".format(entry.speed * 3.6))
            .appendQueryParameter(fieldKey("bearing", "bearing"), "%.1f".format(entry.heading))
            .appendQueryParameter(fieldKey("altitude", "altitude"), "%.1f".format(entry.altitude))
            .appendQueryParameter(fieldKey("accuracy", "accuracy"), "%.1f".format(entry.accuracy))
            .appendQueryParameter(fieldKey("battery", "batt"), "${entry.battery}")
            .build().toString()
        return httpPost(uri)
    }

    private fun httpPost(url: String): Int {
        return try {
            val conn = URL(url).openConnection() as HttpURLConnection
            conn.requestMethod = "POST"
            conn.connectTimeout = 20_000
            conn.readTimeout = 20_000
            try { conn.responseCode } finally { conn.disconnect() }
        } catch (e: Exception) {
            -1
        }
    }

    // ── In-memory cache management ────────────────────────────────────────────

    private fun updateCacheOptimistic(location: android.location.Location, sentAtMs: Long) {
        secondToLast = lastFix
        lastFix = LastFix(
            lat = location.latitude,
            lon = location.longitude,
            heading = if (location.hasBearing()) location.bearing.toDouble() else -1.0,
            speedKmh = location.speed * 3.6,
            sentAtMs = sentAtMs,
        )
    }

    private fun updateCacheFromEntry(entry: LocationEntry) {
        secondToLast = lastFix
        lastFix = LastFix(
            lat = entry.lat,
            lon = entry.lon,
            heading = entry.heading,
            speedKmh = entry.speed * 3.6,
            sentAtMs = System.currentTimeMillis(),
        )
    }

    // ── SharedPreferences cache (shared with Dart LocationCache) ───────────────
    // Written after confirmed 2xx so Dart's filter baseline is always accurate.
    // Read on service (re)start so the baseline survives process death.

    private fun persistCacheToPrefs(location: android.location.Location, sentAtMs: Long) {
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSSSS", Locale.US).apply {
            timeZone = TimeZone.getTimeZone("UTC")
        }.format(Date(sentAtMs))

        flutterPrefs.edit()
            .putFloat(KEY_CACHE_LAT, location.latitude.toFloat())
            .putFloat(KEY_CACHE_LON, location.longitude.toFloat())
            .putFloat(KEY_CACHE_HEADING, if (location.hasBearing()) location.bearing else -1f)
            .putFloat(KEY_CACHE_SPEED, location.speed)
            .putString(KEY_CACHE_TIMESTAMP, iso)
            .apply()
    }

    private fun loadCacheFromPrefs() {
        val lat = flutterPrefs.getFloat(KEY_CACHE_LAT, 0f).toDouble()
        val lon = flutterPrefs.getFloat(KEY_CACHE_LON, 0f).toDouble()
        val tsStr = flutterPrefs.getString(KEY_CACHE_TIMESTAMP, null) ?: return
        if (lat == 0.0 && lon == 0.0) return

        val formats = listOf(
            "yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            "yyyy-MM-dd'T'HH:mm:ss.SSS",
            "yyyy-MM-dd'T'HH:mm:ss",
        )
        var sentAtMs = 0L
        for (fmt in formats) {
            runCatching {
                SimpleDateFormat(fmt, Locale.US).also { it.timeZone = TimeZone.getTimeZone("UTC") }
                    .parse(tsStr)?.time?.also { sentAtMs = it }
            }
            if (sentAtMs != 0L) break
        }
        if (sentAtMs == 0L) return

        lastFix = LastFix(
            lat = lat,
            lon = lon,
            heading = flutterPrefs.getFloat(KEY_CACHE_HEADING, -1f).toDouble(),
            speedKmh = flutterPrefs.getFloat(KEY_CACHE_SPEED, 0f).toDouble() * 3.6,
            sentAtMs = sentAtMs,
        )
    }

    private fun persistCacheFromEntry(entry: LocationEntry) {
        val iso = SimpleDateFormat("yyyy-MM-dd'T'HH:mm:ss.SSSSSS", Locale.US)
            .apply { timeZone = TimeZone.getTimeZone("UTC") }
            .format(Date(System.currentTimeMillis()))
        flutterPrefs.edit()
            .putFloat(KEY_CACHE_LAT, entry.lat.toFloat())
            .putFloat(KEY_CACHE_LON, entry.lon.toFloat())
            .putFloat(KEY_CACHE_HEADING, entry.heading.toFloat())
            .putFloat(KEY_CACHE_SPEED, entry.speed.toFloat())
            .putString(KEY_CACHE_TIMESTAMP, iso)
            .apply()
    }

    // ── Connectivity monitor ──────────────────────────────────────────────────

    private fun registerNetworkCallback() {
        val cm = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        val req = NetworkRequest.Builder()
            .addCapability(NetworkCapabilities.NET_CAPABILITY_INTERNET)
            .build()
        val cb = object : ConnectivityManager.NetworkCallback() {
            override fun onAvailable(network: Network) { flushQueue() }
        }
        cm.registerNetworkCallback(req, cb)
        networkCallback = cb
    }

    private fun unregisterNetworkCallback() {
        networkCallback?.let {
            (getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager)
                .unregisterNetworkCallback(it)
            networkCallback = null
        }
    }

    // ── Battery ───────────────────────────────────────────────────────────────

    private fun getBatteryPct(): Int {
        val intent = registerReceiver(null, IntentFilter(Intent.ACTION_BATTERY_CHANGED)) ?: return 0
        val level = intent.getIntExtra(BatteryManager.EXTRA_LEVEL, 0)
        val scale = intent.getIntExtra(BatteryManager.EXTRA_SCALE, 100)
        return if (scale > 0) (level * 100 / scale) else 0
    }

    // ── Notification ──────────────────────────────────────────────────────────
    //
    // A generic default; host apps can override by declaring their own
    // notification via a future `NotificationConfig` (not yet exposed --
    // v1 ships this fixed copy, see MIGRATION.md).

    private fun createNotificationChannel() {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O) return
        val channel = NotificationChannel(
            NOTIF_CHANNEL_ID,
            "Location Tracking",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Active while tracking your location"
            setShowBadge(false)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager)
            .createNotificationChannel(channel)
    }

    private fun buildNotification(): Notification {
        return NotificationCompat.Builder(this, NOTIF_CHANNEL_ID)
            .setContentTitle("Tracking active")
            .setContentText("Location is being recorded")
            .setSmallIcon(android.R.drawable.ic_menu_mylocation)
            .setOngoing(true)
            .setForegroundServiceBehavior(NotificationCompat.FOREGROUND_SERVICE_IMMEDIATE)
            .build()
    }

    // stopSelf() alone does not guarantee the notification disappears if this
    // service's process wasn't already alive when ACTION_STOP arrives (killed
    // in the background, low memory, etc.) -- Android has to spin up a fresh
    // instance just to deliver the stop intent, and onCreate() re-posts the
    // notification (required within 5s of startForegroundService()) before
    // onStartCommand() ever runs. Called from the ACTION_STOP handler and
    // again from onDestroy() as a defensive backstop.
    private fun stopForegroundAndCancelNotification() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        } else {
            @Suppress("DEPRECATION")
            stopForeground(true)
        }
        (getSystemService(NOTIFICATION_SERVICE) as NotificationManager).cancel(NOTIF_ID)
    }
}
