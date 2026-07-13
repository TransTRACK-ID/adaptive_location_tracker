// ios/Classes/KillSurvivalLocationService.h
#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>
#import <CoreMotion/CoreMotion.h>

/// Posted on the main queue when autoFlushQueueIfNeeded begins sending queued
/// entries to the server. The `object` is an NSNumber with the entry count.
/// AdaptiveLocationTrackerPlugin relays this to Flutter via the sync-events EventChannel.
extern NSString *const KSAutoFlushDidBeginNotification;

/// Posted on the main queue when autoFlushQueueIfNeeded finishes.
/// The `object` is an NSArray<NSNumber *> containing [sent, kept, discarded].
extern NSString *const KSAutoFlushDidEndNotification;

@interface KillSurvivalLocationService : NSObject

+ (instancetype)shared;

/// @param fieldKeys Query-parameter key overrides -- one entry per
///   NativeFieldKeys member on the Dart side (subjectId, timestamp, latitude,
///   longitude, speed, bearing, altitude, accuracy, battery). Missing keys
///   fall back to the same defaults as `NativeFieldKeys()`.
- (void)setTrackingURL:(NSString *)url
              subjectId:(NSString *)subjectId
              fieldKeys:(NSDictionary<NSString *, NSString *> *)fieldKeys;
- (void)startWatchingForKill;
- (void)stopWatching;

/// Triggers an immediate offline-queue drain attempt. The service already
/// does this internally on heartbeat/connectivity-restore/significant-change
/// events; this is exposed so Dart can also request one on demand (e.g. on
/// app-resume), matching the Android native service's `flush` action.
- (void)requestFlush;

@end
