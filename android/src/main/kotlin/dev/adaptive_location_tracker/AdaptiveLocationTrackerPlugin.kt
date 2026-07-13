package dev.adaptive_location_tracker

import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import androidx.annotation.NonNull
import androidx.core.content.ContextCompat
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result

/**
 * Flutter <-> Kotlin bridge for the location tracking service.
 *
 * A standard [FlutterPlugin] -- registered automatically via Flutter's
 * plugin registry (declared in pubspec.yaml's `flutter.plugin.platforms`),
 * no manual MainActivity wiring required.
 *
 * Channel names match `native_bridge.dart` exactly so the same Dart code
 * works unmodified on iOS.
 */
class AdaptiveLocationTrackerPlugin : FlutterPlugin, MethodCallHandler {

    companion object {
        private const val METHOD_CHANNEL = "dev.adaptive_location_tracker/channel"
        private const val EVENT_CHANNEL = "dev.adaptive_location_tracker/sync_events"

        // Non-null only while Flutter is actively listening for sync events.
        // Always posted on the main thread -- EventSink isn't thread-safe.
        @Volatile private var eventSink: EventChannel.EventSink? = null
        private val mainHandler = Handler(Looper.getMainLooper())

        /** Called from [LocationTrackingService] when a background flush completes. */
        fun postSyncBegin(count: Int) {
            mainHandler.post {
                eventSink?.success(mapOf("type" to "begin", "count" to count))
            }
        }

        fun postSyncEnd(sent: Int, kept: Int, discarded: Int) {
            mainHandler.post {
                eventSink?.success(
                    mapOf(
                        "type" to "end",
                        "sent" to sent,
                        "kept" to kept,
                        "discarded" to discarded,
                    ),
                )
            }
        }
    }

    private lateinit var context: Context
    private lateinit var methodChannel: MethodChannel
    private lateinit var eventChannel: EventChannel

    override fun onAttachedToEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext

        methodChannel = MethodChannel(binding.binaryMessenger, METHOD_CHANNEL)
        methodChannel.setMethodCallHandler(this)

        eventChannel = EventChannel(binding.binaryMessenger, EVENT_CHANNEL)
        eventChannel.setStreamHandler(object : EventChannel.StreamHandler {
            override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
                eventSink = events
            }
            override fun onCancel(arguments: Any?) {
                eventSink = null
            }
        })
    }

    override fun onDetachedFromEngine(@NonNull binding: FlutterPlugin.FlutterPluginBinding) {
        methodChannel.setMethodCallHandler(null)
        eventChannel.setStreamHandler(null)
        eventSink = null
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "start" -> {
                startService(LocationTrackingService.ACTION_START)
                result.success(null)
            }

            "stop" -> {
                startService(LocationTrackingService.ACTION_STOP)
                result.success(null)
            }

            "setTrackingConfig" -> {
                val args = call.arguments as? Map<*, *>
                val url = args?.get("url") as? String ?: ""
                val subjectId = args?.get("subjectId") as? String ?: ""
                @Suppress("UNCHECKED_CAST")
                val fieldKeys = args?.get("fieldKeys") as? Map<String, String> ?: emptyMap()

                val editor = context.getSharedPreferences(
                    LocationTrackingService.TRACKING_PREFS, Context.MODE_PRIVATE,
                ).edit()
                    .putString(LocationTrackingService.KEY_TRACKING_URL, url)
                    .putString(LocationTrackingService.KEY_SUBJECT_ID, subjectId)

                for ((key, value) in fieldKeys) {
                    editor.putString(LocationTrackingService.KEY_FIELD_PREFIX + key, value)
                }
                editor.apply()
                result.success(null)
            }

            "flush" -> {
                startService(LocationTrackingService.ACTION_FLUSH)
                result.success(null)
            }

            // iOS-only concerns (native SQLite queue is fully self-managed on
            // Android; no debug log file on this platform) -- stubs kept so
            // Dart's NativeBridge works identically on either platform.
            "getQueue" -> result.success(emptyList<Any>())
            "deleteEntry" -> result.success(null)
            "readLog" -> result.success("")
            "clearLog" -> result.success(null)

            else -> result.notImplemented()
        }
    }

    private fun startService(action: String) {
        val intent = Intent(context, LocationTrackingService::class.java).apply {
            this.action = action
        }
        ContextCompat.startForegroundService(context, intent)
    }
}
