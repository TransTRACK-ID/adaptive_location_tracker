package dev.adaptive_location_tracker

import android.content.SharedPreferences
import android.location.Location
import kotlin.math.abs
import kotlin.math.max

// ── Movement mode ─────────────────────────────────────────────────────────────

enum class MovementMode { STATIONARY, WALKING, CYCLING, DRIVING }

// ── Hysteresis (prevents mode flapping) ──────────────────────────────────────

object ModeHysteresis {
    var committed: MovementMode = MovementMode.STATIONARY; private set
    var candidate: MovementMode = MovementMode.STATIONARY; private set
    var candidateMs: Long = 0L; private set

    private val thresholdMs = mapOf(
        MovementMode.STATIONARY to 60_000L,
        MovementMode.WALKING to 30_000L,
        MovementMode.CYCLING to 15_000L,
        MovementMode.DRIVING to 0L,
    )

    fun commit(raw: MovementMode): MovementMode {
        val now = System.currentTimeMillis()
        if (raw == candidate) {
            val stable = now - candidateMs
            val required = thresholdMs[raw] ?: 0L
            val isUpgrade = raw.ordinal > committed.ordinal
            if (isUpgrade || stable >= required) committed = raw
        } else {
            candidate = raw
            candidateMs = now
            if (raw.ordinal > committed.ordinal) committed = raw
        }
        return committed
    }

    fun reset() {
        committed = MovementMode.STATIONARY
        candidate = MovementMode.STATIONARY
        candidateMs = 0L
    }
}

// ── Snapshot of the last successfully sent fix ────────────────────────────────

data class LastFix(
    val lat: Double,
    val lon: Double,
    val heading: Double, // degrees, -1 if unavailable
    val speedKmh: Double,
    val sentAtMs: Long,
)

/**
 * Movement-mode-aware send filter. Runs entirely natively so tracking keeps
 * working while the Flutter engine isn't running.
 *
 * Thresholds are read from Flutter's SharedPreferences file so both Dart's
 * [in-package] adaptive filter and this native filter share one source of
 * truth ("adaptive_location_tracker_filter_*" keys) -- override any of them from Dart
 * via `AdaptiveFilterConfig` at configure time.
 */
object LocationFilter {

    const val FLUTTER_PREFS = "FlutterSharedPreferences"
    private const val FP = "flutter."

    fun pDouble(p: SharedPreferences, key: String, default: Double): Double {
        val v = p.all[FP + key] ?: return default
        return when (v) {
            is Float -> v.toDouble()
            is Double -> v
            is Int -> v.toDouble()
            is Long -> v.toDouble()
            else -> default
        }
    }

    fun distM(lat1: Double, lon1: Double, lat2: Double, lon2: Double): Double {
        val r = FloatArray(1)
        Location.distanceBetween(lat1, lon1, lat2, lon2, r)
        return r[0].toDouble()
    }

    // distFilter = max(minDist, speedMps x targetWindow)
    fun adaptiveDist(mode: MovementMode, speedMps: Double): Double {
        val (minDist, window) = when (mode) {
            MovementMode.WALKING -> 15.0 to 15.0
            MovementMode.CYCLING -> 40.0 to 10.0
            MovementMode.DRIVING -> 75.0 to 7.0
            else -> return 0.0
        }
        return max(minDist, if (speedMps > 0) speedMps * window else minDist)
    }

    // > 50% -> 1x   20-50% -> 1.5x   < 20% -> 2.5x
    fun batteryMult(batteryPct: Int): Double = when {
        batteryPct > 50 -> 1.0
        batteryPct > 20 -> 1.5
        else -> 2.5
    }

    fun detectMode(
        location: Location,
        last: LastFix?,
        elapsedSec: Double,
        prefs: SharedPreferences,
    ): MovementMode {
        val speedKmh = if (location.hasSpeed() && location.speed >= 0) {
            location.speed * 3.6
        } else if (last != null && elapsedSec > 0) {
            (distM(last.lat, last.lon, location.latitude, location.longitude) / elapsedSec) * 3.6
        } else {
            pDouble(prefs, "adaptive_location_tracker_filter_speed_driving_kmh", 40.0)
        }

        val walkBound = pDouble(prefs, "adaptive_location_tracker_filter_speed_kmh", 5.0)
        val cyclingBound = pDouble(prefs, "adaptive_location_tracker_filter_speed_cycling_kmh", 15.0)
        val drivingBound = pDouble(prefs, "adaptive_location_tracker_filter_speed_driving_kmh", 40.0)

        val raw = when {
            speedKmh < walkBound -> MovementMode.STATIONARY
            speedKmh < cyclingBound -> MovementMode.WALKING
            speedKmh < drivingBound -> MovementMode.CYCLING
            else -> MovementMode.DRIVING
        }
        return ModeHysteresis.commit(raw)
    }

    /**
     * @param location      incoming fix from FusedLocationProviderClient
     * @param last          last successfully sent fix (null on first fix)
     * @param secondToLast  fix before last (null until >= 2 sends) -- anti-oscillation guard
     * @param batteryPct    current battery % for the interval multiplier
     * @param prefs         FlutterSharedPreferences (filter config)
     */
    fun shouldSend(
        location: Location,
        last: LastFix?,
        secondToLast: LastFix?,
        batteryPct: Int,
        prefs: SharedPreferences,
    ): Boolean {
        if (last == null) return true

        val nowMs = System.currentTimeMillis()
        val elapsedSec = (nowMs - last.sentAtMs) / 1000.0

        // Exact-duplicate guard: FLP re-delivers the cached last-known
        // coordinate while stationary; reject anything within 1m.
        val distToLast = distM(last.lat, last.lon, location.latitude, location.longitude)
        if (distToLast < 1.0) return false

        // Staleness gate: FLP may deliver a cached fix from hours ago on cold start.
        val fixAgeMs = nowMs - location.time
        if (fixAgeMs > 30_000L) return false

        val speedMps = if (location.hasSpeed() && location.speed >= 0) location.speed.toDouble() else 0.0
        val speedKmh = speedMps * 3.6

        val mode = detectMode(location, last, elapsedSec, prefs)
        val battMult = batteryMult(batteryPct)

        val maxAcc = when (mode) {
            MovementMode.WALKING -> pDouble(prefs, "adaptive_location_tracker_filter_accuracy_walking_m", 20.0)
            MovementMode.CYCLING -> pDouble(prefs, "adaptive_location_tracker_filter_accuracy_cycling_m", 30.0)
            else -> pDouble(prefs, "adaptive_location_tracker_filter_accuracy_m", 50.0)
        }
        if (location.accuracy > maxAcc) return false

        val fastestSec = when (mode) {
            MovementMode.DRIVING -> pDouble(prefs, "adaptive_location_tracker_filter_fastest_driving_sec", 5.0)
            MovementMode.CYCLING -> pDouble(prefs, "adaptive_location_tracker_filter_fastest_cycling_sec", 8.0)
            MovementMode.WALKING -> pDouble(prefs, "adaptive_location_tracker_filter_fastest_sec", 15.0)
            MovementMode.STATIONARY -> 0.0
        }
        if (elapsedSec < fastestSec * battMult) return false

        if (mode == MovementMode.STATIONARY) {
            val heartbeatSec = pDouble(prefs, "adaptive_location_tracker_filter_heartbeat_sec", 60.0)
            return elapsedSec >= heartbeatSec
        }

        val adaptiveDistM = adaptiveDist(mode, speedMps)
        val intervalSec = pDouble(prefs, "adaptive_location_tracker_filter_interval_sec", 15.0) * battMult

        if (elapsedSec >= intervalSec) return true

        // Anti-oscillation guard: reject a distance-triggered fix that lands
        // back within minDistance of the second-to-last sent position (the
        // hallmark of FLP alternating between a GPS and a WiFi/cell anchor).
        if (distToLast >= adaptiveDistM) {
            if (secondToLast != null) {
                val distToSecond = distM(
                    secondToLast.lat, secondToLast.lon,
                    location.latitude, location.longitude,
                )
                val minDist = when (mode) {
                    MovementMode.WALKING -> 15.0
                    MovementMode.CYCLING -> 40.0
                    MovementMode.DRIVING -> 75.0
                    else -> 0.0
                }
                if (distToSecond < minDist) return false
            }
            return true
        }

        val lastHeading = last.heading
        if (mode != MovementMode.WALKING && lastHeading >= 0 &&
            location.hasBearing() && speedKmh > 8.0
        ) {
            val threshold = if (mode == MovementMode.CYCLING) 45.0
            else pDouble(prefs, "adaptive_location_tracker_filter_angle_deg", 25.0)
            var diff = abs(location.bearing - lastHeading).toDouble()
            if (diff > 180) diff = 360 - diff
            if (diff >= threshold) return true
        }

        return false
    }
}
