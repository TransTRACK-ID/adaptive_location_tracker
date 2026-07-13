import 'dart:io';

import 'package:flutter/services.dart';

import 'models.dart';

/// Thin wrapper around the platform channel shared by the Android foreground
/// service and the iOS kill-survival service.
///
/// Both native implementations expose the same channel names and method
/// contract so this class works identically on either platform:
///
///   MethodChannel "dev.adaptive_location_tracker/channel":
///     start                — arms the native tracking service
///     stop                 — disarms it and clears its queue
///     setTrackingConfig    — persists {url, subjectId, fieldKeys} for
///                            native-only HTTP sends (used when the Flutter
///                            engine may not be running)
///     flush                — triggers the native offline-queue drain
///     getQueue/deleteEntry — iOS only; Android's native queue never needs
///                            Dart to touch it directly
///     readLog/clearLog     — optional native-side debug log (iOS)
///
///   EventChannel "dev.adaptive_location_tracker/sync_events":
///     { "type": "begin", "count": N }
///     { "type": "end", "sent": S, "kept": K, "discarded": D }
class NativeBridge {
  NativeBridge._();

  static const _channel = MethodChannel('dev.adaptive_location_tracker/channel');
  static const _syncEventChannel =
      EventChannel('dev.adaptive_location_tracker/sync_events');

  static Stream<TrackingSyncEvent>? _syncStream;

  /// Broadcast stream of background sync events posted by the native layer
  /// whenever it drains its own offline queue independently of Dart.
  static Stream<TrackingSyncEvent> get syncEventStream {
    _syncStream ??= _syncEventChannel.receiveBroadcastStream().map((raw) {
      final map = Map<String, dynamic>.from(raw as Map);
      if (map['type'] == 'begin') {
        return TrackingSyncEvent.begin(map['count'] as int? ?? 0);
      }
      return TrackingSyncEvent.end(
        sent: map['sent'] as int? ?? 0,
        kept: map['kept'] as int? ?? 0,
        discarded: map['discarded'] as int? ?? 0,
      );
    });
    return _syncStream!;
  }

  static Future<void> start() async {
    await _channel.invokeMethod('start');
  }

  static Future<void> stop() async {
    await _channel.invokeMethod('stop');
  }

  static Future<void> setTrackingConfig(NativeEndpointConfig config) async {
    await _channel.invokeMethod('setTrackingConfig', config.toChannelArgs());
  }

  /// Triggers the native layer to drain its own offline queue and re-attempt
  /// sends. On Android this is fire-and-forget (the native service manages
  /// its own SQLite queue end-to-end). On iOS this only signals the native
  /// side to check for work; the actual queue is drained on the native side
  /// too when using the kill-survival service directly.
  static Future<void> flush() async {
    try {
      await _channel.invokeMethod('flush');
    } catch (_) {
      // Best-effort — a missing/failed flush call isn't fatal, the next
      // heartbeat or connectivity-restore event will retry.
    }
  }

  static Future<String> readLog() async {
    if (!Platform.isIOS) return '';
    return await _channel.invokeMethod('readLog') ?? '';
  }

  static Future<void> clearLog() async {
    if (!Platform.isIOS) return;
    await _channel.invokeMethod('clearLog');
  }
}
