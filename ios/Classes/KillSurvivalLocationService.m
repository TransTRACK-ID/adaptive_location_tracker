// ios/Classes/KillSurvivalLocationService.m
//
// Generic iOS kill-survival background location service.
//
//   - CLLocationManager significant-change monitoring wakes the app after
//     kill (~500m change) even when Flutter isn't running.
//   - A second CLLocationManager (trackingManager) does high-accuracy
//     continuous tracking, armed only while backgrounded.
//   - CMMotionActivityManager drives movement-mode detection, falling back
//     to GPS-speed heuristics when no fresh activity sample is available.
//   - NWPathMonitor triggers an immediate queue flush on connectivity restore.
//   - LocationQueue (SQLite) persists fixes that failed to send.
//   - NSUserDefaults persists config + the last-sent-fix cache, shared with
//     the host app's Dart `LocationCache` (same key names).
//
// Every backend-shape assumption (query param names, the subject/id value)
// is configured via -setTrackingURL:subjectId:fieldKeys: -- see
// `NativeEndpointConfig`/`NativeFieldKeys` on the Dart side.

#import "KillSurvivalLocationService.h"
#import "LocationQueue.h"
#import <UIKit/UIKit.h>
#import <Network/Network.h>
#import <CoreMotion/CoreMotion.h>

// ── Persistence keys (shared with the Dart package where noted) ──────────

static NSString *const kLastWakeLatKey    = @"adaptive_location_tracker_ks_last_wake_lat";
static NSString *const kLastWakeLonKey    = @"adaptive_location_tracker_ks_last_wake_lon";
static NSString *const kLastWakeTimeKey   = @"adaptive_location_tracker_ks_last_wake_time";
static NSString *const kSubjectIdKey      = @"adaptive_location_tracker_ks_subject_id";
static NSString *const kTrackingURLKey    = @"adaptive_location_tracker_ks_tracking_url";
static NSString *const kIsActiveKey       = @"adaptive_location_tracker_ks_is_active";
static NSString *const kFieldKeysKey      = @"adaptive_location_tracker_ks_field_keys"; // archived NSDictionary

// Ownership flag -- shared with Dart's LocationFilterConfig.kOwner.
// "flutter" -> Dart stream owns capture; native trackingManager must skip.
// "native"  -> native trackingManager owns capture; Dart stream must skip.
static NSString *const kOwnerKey          = @"adaptive_location_tracker_ks_owner";
static NSString *const kOwnerFlutter      = @"flutter";
static NSString *const kOwnerNative       = @"native";

// Cross-layer flush mutex -- shared with Dart's LocationFilterConfig.kFlushing.
static NSString *const kFlushingKey       = @"adaptive_location_tracker_ks_flushing";

// Last-sent cache -- SAME keys as Dart's LocationCache so both layers share
// a single source of truth via NSUserDefaults / SharedPreferences.
static NSString *const kLastSentLatKey     = @"adaptive_location_tracker_loc_cache_lat";
static NSString *const kLastSentLonKey     = @"adaptive_location_tracker_loc_cache_lon";
static NSString *const kLastSentHeadingKey = @"adaptive_location_tracker_loc_cache_heading";
static NSString *const kLastSentSpeedKey   = @"adaptive_location_tracker_loc_cache_speed";
static NSString *const kLastSentTimeKey    = @"adaptive_location_tracker_loc_cache_timestamp"; // ISO-8601 string

// Sync indicator NSNotifications -- relayed to Flutter by AdaptiveLocationTrackerPlugin.
NSString *const KSAutoFlushDidBeginNotification = @"KSAutoFlushDidBegin";
NSString *const KSAutoFlushDidEndNotification   = @"KSAutoFlushDidEnd";

// Suppresses the stale cached fix / GPS warm-up burst CLLocationManager
// delivers on start. Not shared with Dart -- iOS-hardware-specific.
static const double kStartupGracePeriod   = 10.0; // seconds

// ── Single source of truth: read filter thresholds from SharedPreferences ─
//
// Flutter's shared_preferences plugin writes to [NSUserDefaults standardUserDefaults]
// with the same "adaptive_location_tracker_filter_*" keys used by the Dart adaptive filter
// (AdaptiveFilterConfig). Reading them here means any user-configured or
// runtime-tuned value is honoured natively without a MethodChannel round-trip.
static double ksFilterPref(NSString *key, double fallback) {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    id val = [d objectForKey:key];
    return val ? [val doubleValue] : fallback;
}

static inline double kMinAccuracyWalkingM(void) { return ksFilterPref(@"adaptive_location_tracker_filter_accuracy_walking_m", 20.0); }
static inline double kMinAccuracyCyclingM(void) { return ksFilterPref(@"adaptive_location_tracker_filter_accuracy_cycling_m", 30.0); }
static inline double kMinAccuracyM(void)        { return ksFilterPref(@"adaptive_location_tracker_filter_accuracy_m",         50.0); }

static inline double kIntervalSec(void)         { return ksFilterPref(@"adaptive_location_tracker_filter_interval_sec",       15.0); }
static inline double kHeartbeatSec(void)        { return ksFilterPref(@"adaptive_location_tracker_filter_heartbeat_sec",      60.0); }
static inline double kFastestWalkingSec(void)   { return ksFilterPref(@"adaptive_location_tracker_filter_fastest_sec",        15.0); }
static inline double kFastestCyclingSec(void)   { return ksFilterPref(@"adaptive_location_tracker_filter_fastest_cycling_sec", 8.0); }
static inline double kFastestDrivingSec(void)   { return ksFilterPref(@"adaptive_location_tracker_filter_fastest_driving_sec", 5.0); }
static inline double kSpeedThresholdKmh(void)   { return ksFilterPref(@"adaptive_location_tracker_filter_speed_kmh",           5.0); }
static inline double kSpeedCyclingKmh(void)     { return ksFilterPref(@"adaptive_location_tracker_filter_speed_cycling_kmh",  15.0); }
static inline double kSpeedDrivingKmh(void)     { return ksFilterPref(@"adaptive_location_tracker_filter_speed_driving_kmh",  40.0); }
static inline double kAngleDrivingDeg(void)     { return ksFilterPref(@"adaptive_location_tracker_filter_angle_deg",          25.0); }

// > 50% -> 1x   20-50% -> 1.5x   < 20% -> 2.5x
static double ksBatteryMultiplier(void) {
    float level = [UIDevice currentDevice].batteryLevel;
    if (level < 0) return 1.0;
    int pct = (int)(level * 100.0f);
    if (pct > 50) return 1.0;
    if (pct > 20) return 1.5;
    return 2.5;
}

typedef NS_ENUM(NSInteger, KSMovementMode) {
    KSModeStationary = 0,
    KSModeWalking    = 1,
    KSModeCycling    = 2,
    KSModeDriving    = 3,
};

// distFilter = max(minDist, speedMps x targetWindow)
static double ksAdaptiveDistanceFilter(KSMovementMode mode, double speedMps) {
    double minDist, targetWindow;
    switch (mode) {
        case KSModeWalking: minDist = 15.0; targetWindow = 15.0; break;
        case KSModeCycling: minDist = 40.0; targetWindow = 10.0; break;
        case KSModeDriving: minDist = 75.0; targetWindow =  7.0; break;
        default: return 0.0;
    }
    if (speedMps <= 0) return minDist;
    double computed = speedMps * targetWindow;
    return computed > minDist ? computed : minDist;
}

// ── Hysteresis (mode-flap prevention) ──────────────────────────────────────
static KSMovementMode _ksCommittedMode  = KSModeStationary;
static KSMovementMode _ksCandidateMode  = KSModeStationary;
static NSTimeInterval _ksCandidateSince = 0;

static int ksHysteresisThresholdSec(KSMovementMode mode) {
    switch (mode) {
        case KSModeStationary: return 60;
        case KSModeWalking:    return 30;
        case KSModeCycling:    return 15;
        case KSModeDriving:    return  0;
    }
    return 30;
}

static KSMovementMode ksCommitMode(KSMovementMode raw) {
    NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
    if (raw == _ksCandidateMode) {
        int stableSec = (int)(now - _ksCandidateSince);
        BOOL isUpgrade = raw > _ksCommittedMode;
        if (isUpgrade || stableSec >= ksHysteresisThresholdSec(raw)) {
            _ksCommittedMode = raw;
        }
    } else {
        _ksCandidateMode  = raw;
        _ksCandidateSince = now;
        if (raw > _ksCommittedMode) _ksCommittedMode = raw;
    }
    return _ksCommittedMode;
}

@interface KillSurvivalLocationService() <CLLocationManagerDelegate, NSURLSessionDelegate>

@property (nonatomic, strong) CLLocationManager *significantManager;
@property (nonatomic, strong) CLLocationManager *trackingManager;
@property (nonatomic, strong) NSTimer           *heartbeatTimer;
@property (nonatomic, strong) nw_path_monitor_t  pathMonitor;

@property (nonatomic, copy)   NSString          *subjectId;
@property (nonatomic, copy)   NSString          *trackingURL;
@property (nonatomic, copy)   NSDictionary<NSString *, NSString *> *fieldKeys;

@property (nonatomic, strong) NSURLSession      *bgSession;
@property (nonatomic, assign) UIBackgroundTaskIdentifier currentBgTask;
@property (nonatomic, assign) NSTimeInterval     startTime;
@property (nonatomic, assign) BOOL               isWatching;

@property (nonatomic, assign) double             lastLat;
@property (nonatomic, assign) double             lastLon;
@property (nonatomic, assign) double             lastHeading;
@property (nonatomic, assign) double             lastSpeedKmh;
@property (nonatomic, assign) NSTimeInterval     lastSentTime;
@property (nonatomic, assign) BOOL               hasLastFix;

@property (nonatomic, assign) BOOL               isFlushing;

@property (nonatomic, strong) CMMotionActivityManager *activityManager;
@property (nonatomic, strong) CMMotionActivity        *lastActivity;

@end

@implementation KillSurvivalLocationService

+ (instancetype)shared {
    static KillSurvivalLocationService *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];

    self.significantManager = [[CLLocationManager alloc] init];
    self.significantManager.delegate = self;
    self.significantManager.allowsBackgroundLocationUpdates = YES;

    self.trackingManager = [[CLLocationManager alloc] init];
    self.trackingManager.delegate = self;
    self.trackingManager.desiredAccuracy = kCLLocationAccuracyBestForNavigation;
    self.trackingManager.allowsBackgroundLocationUpdates = YES;
    self.trackingManager.pausesLocationUpdatesAutomatically = NO;
    self.trackingManager.showsBackgroundLocationIndicator = YES;

    self.currentBgTask = UIBackgroundTaskInvalid;
    self.isFlushing    = NO;
    [UIDevice currentDevice].batteryMonitoringEnabled = YES;

    NSURLSessionConfiguration *config = [NSURLSessionConfiguration
            backgroundSessionConfigurationWithIdentifier:@"dev.adaptive_location_tracker.location_sender"];
    config.discretionary            = NO;
    config.sessionSendsLaunchEvents = YES;
    self.bgSession = [NSURLSession sessionWithConfiguration:config
                                                   delegate:self
                                              delegateQueue:nil];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    self.trackingURL = [d stringForKey:kTrackingURLKey] ?: @"";
    self.subjectId   = [d stringForKey:kSubjectIdKey]   ?: @"";
    self.fieldKeys   = [d dictionaryForKey:kFieldKeysKey] ?: @{};
    [self loadLastSentCache];

    [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(appDidEnterBackground)
                   name:UIApplicationDidEnterBackgroundNotification
                 object:nil];
    [[NSNotificationCenter defaultCenter]
            addObserver:self
               selector:@selector(appWillEnterForeground)
                   name:UIApplicationWillEnterForegroundNotification
                 object:nil];

    [self startPathMonitor];
    [self startActivityUpdates];

    return self;
}

#pragma mark - Field-key resolution (defaults mirror NativeFieldKeys() on Dart)

- (NSString *)fieldKeyFor:(NSString *)name fallback:(NSString *)fallback {
    NSString *v = self.fieldKeys[name];
    return v.length > 0 ? v : fallback;
}

#pragma mark - Core Motion Activity Recognition

- (void)startActivityUpdates {
    if (![CMMotionActivityManager isActivityAvailable]) return;
    self.activityManager = [[CMMotionActivityManager alloc] init];
    NSOperationQueue *q  = [[NSOperationQueue alloc] init];
    __weak typeof(self) weakSelf = self;
    [self.activityManager startActivityUpdatesToQueue:q withHandler:^(CMMotionActivity *activity) {
        if (!activity || activity.unknown) return;
        weakSelf.lastActivity = activity;

        // Write to NSUserDefaults so the Dart ActivityBridge can read it.
        NSString *type = nil;
        if      (activity.stationary)  type = @"stationary";
        else if (activity.walking)     type = @"walking";
        else if (activity.running)     type = @"walking"; // treat running as walking
        else if (activity.cycling)     type = @"cycling";
        else if (activity.automotive)  type = @"automotive";
        else                            type = @"unknown";

        NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
        [d setObject:type forKey:@"adaptive_location_tracker_activity_type"];
        [d setInteger:(NSInteger)([[NSDate date] timeIntervalSince1970] * 1000)
               forKey:@"adaptive_location_tracker_activity_type_ts"];
        [d synchronize];
    }];
}

/// Derives the KSMovementMode from the latest CMMotionActivity.
/// Falls back to GPS-speed classification if no fresh activity is available.
- (KSMovementMode)movementModeForLocation:(CLLocation *)location speedKmh:(double)speedKmh {
    CMMotionActivity *act = self.lastActivity;
    if (act) {
        NSTimeInterval ageMs = -[act.startDate timeIntervalSinceNow] * 1000.0;
        if (ageMs < 30000) {
            KSMovementMode raw;
            if      (act.stationary)  raw = KSModeStationary;
            else if (act.cycling)     raw = KSModeCycling;
            else if (act.automotive)  raw = KSModeDriving;
            else                       raw = KSModeWalking;
            return ksCommitMode(raw);
        }
    }
    KSMovementMode raw;
    if      (speedKmh < kSpeedThresholdKmh()) raw = KSModeStationary;
    else if (speedKmh < kSpeedCyclingKmh())   raw = KSModeWalking;
    else if (speedKmh < kSpeedDrivingKmh())   raw = KSModeCycling;
    else                                        raw = KSModeDriving;
    return ksCommitMode(raw);
}

#pragma mark - Credentials

- (void)setTrackingURL:(NSString *)url
              subjectId:(NSString *)subjectId
              fieldKeys:(NSDictionary<NSString *, NSString *> *)fieldKeys {
    self.trackingURL = url;
    self.subjectId   = subjectId;
    self.fieldKeys   = fieldKeys ?: @{};

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:url          forKey:kTrackingURLKey];
    [d setObject:subjectId    forKey:kSubjectIdKey];
    [d setObject:self.fieldKeys forKey:kFieldKeysKey];
    [d setBool:YES            forKey:kIsActiveKey];
    [d synchronize];
}

#pragma mark - Start / Stop

- (void)startWatchingForKill {
    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    if (![ud boolForKey:kIsActiveKey]) return;
    if (self.isWatching) return;

    self.isWatching = YES;
    self.startTime  = [[NSDate date] timeIntervalSince1970];

    [self.significantManager startMonitoringSignificantLocationChanges];

    UIApplicationState appState = [UIApplication sharedApplication].applicationState;
    if (appState != UIApplicationStateActive) {
        // Background / killed relaunch: Flutter Geolocator stream is not
        // running. Set owner = native, arm trackingManager, flush any queue.
        [self setOwnerNative];
        [self startBackgroundTracking];
        [self autoFlushQueueIfNeeded];
    }
}

- (void)stopWatching {
    [self.significantManager stopMonitoringSignificantLocationChanges];
    [self stopBackgroundTracking];
    self.isWatching = NO;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:NO forKey:kIsActiveKey];
    [ud synchronize];
}

#pragma mark - Ownership flag

- (void)setOwnerNative {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kOwnerNative forKey:kOwnerKey];
    [d synchronize];
}

- (void)setOwnerFlutter {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setObject:kOwnerFlutter forKey:kOwnerKey];
    [d synchronize];
}

#pragma mark - Background Tracking Helpers

- (void)startBackgroundTracking {
    // Walking-minimum hardware pre-filter; shouldSendLocation: applies the
    // adaptive (speed-based) threshold on top.
    double distFilter = 15.0;
    self.trackingManager.distanceFilter = distFilter;
    [self.trackingManager startUpdatingLocation];
    self.startTime = [[NSDate date] timeIntervalSince1970];

    double heartbeat = kHeartbeatSec();
    self.heartbeatTimer = [NSTimer scheduledTimerWithTimeInterval:heartbeat
                                                           target:self
                                                         selector:@selector(heartbeatTick)
                                                         userInfo:nil
                                                          repeats:YES];
}

- (void)stopBackgroundTracking {
    [self.trackingManager stopUpdatingLocation];
    [self.heartbeatTimer invalidate];
    self.heartbeatTimer = nil;
}

- (void)heartbeatTick {
    [self.trackingManager requestLocation];
    [self autoFlushQueueIfNeeded];
}

#pragma mark - App Lifecycle

- (void)appDidEnterBackground {
    if (!self.isWatching) return;
    [self setOwnerNative];
    [self startBackgroundTracking];
    [self autoFlushQueueIfNeeded];
}

- (void)appWillEnterForeground {
    // The host app's Dart foreground stream + flush-on-resume take over.
    // Stop native tracking to avoid duplicate sends.
    [self setOwnerFlutter];
    [self stopBackgroundTracking];
}

#pragma mark - NWPathMonitor (connectivity-restore flush)

- (void)startPathMonitor {
    self.pathMonitor = nw_path_monitor_create();
    nw_path_monitor_t monitor = self.pathMonitor;
    __weak typeof(self) weakSelf = self;

    nw_path_monitor_set_update_handler(monitor, ^(nw_path_t path) {
        if (nw_path_get_status(path) == nw_path_status_satisfied) {
            [weakSelf autoFlushQueueIfNeeded];
        }
    });

    nw_path_monitor_set_queue(monitor,
                              dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0));
    nw_path_monitor_start(monitor);
}

#pragma mark - CLLocationManagerDelegate

- (void)locationManager:(CLLocationManager *)manager
     didUpdateLocations:(NSArray<CLLocation *> *)locations {

    CLLocation *location = locations.lastObject;

    if (manager == self.trackingManager) {
        NSUserDefaults *ud  = [NSUserDefaults standardUserDefaults];
        NSString *owner = [ud stringForKey:kOwnerKey] ?: kOwnerFlutter;

        if (![owner isEqualToString:kOwnerNative]) return;

        NSTimeInterval now = [[NSDate date] timeIntervalSince1970];
        if (self.startTime > 0 && (now - self.startTime) < kStartupGracePeriod) return;

        if (location.horizontalAccuracy <= 0 || location.horizontalAccuracy > kMinAccuracyM()) return;

        NSTimeInterval age = -[location.timestamp timeIntervalSinceNow];
        if (age > 30.0) return;

        if (![self shouldSendLocation:location now:now]) return;

        [self sendLocationToServer:location tag:@"continuous"];
        return;
    }

    if (manager == self.significantManager) {
        __block UIBackgroundTaskIdentifier bgTask = UIBackgroundTaskInvalid;
        bgTask = [[UIApplication sharedApplication]
                beginBackgroundTaskWithName:@"AdaptiveLocationTrackerSigChange"
                          expirationHandler:^{
                              [[UIApplication sharedApplication] endBackgroundTask:bgTask];
                              bgTask = UIBackgroundTaskInvalid;
                          }];
        self.currentBgTask = bgTask;

        NSDate *now = [NSDate date];

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setDouble:location.coordinate.latitude  forKey:kLastWakeLatKey];
        [defaults setDouble:location.coordinate.longitude forKey:kLastWakeLonKey];
        [defaults setDouble:now.timeIntervalSince1970      forKey:kLastWakeTimeKey];
        [defaults synchronize];

        [self enqueueIfAcceptable:location tag:@"sig-change-coarse" maxAccuracy:500.0];
        [self autoFlushQueueIfNeeded];

        if (self.currentBgTask != UIBackgroundTaskInvalid) {
            [[UIApplication sharedApplication] endBackgroundTask:self.currentBgTask];
            self.currentBgTask = UIBackgroundTaskInvalid;
        }
    }
}

- (void)locationManager:(CLLocationManager *)manager
       didFailWithError:(NSError *)error {
    // Non-fatal -- CoreLocation retries on its own; kCLErrorLocationUnknown
    // in particular is expected and transient.
}

#pragma mark - Filter (reads live from shared NSUserDefaults / SharedPreferences)

/// Mirrors AdaptiveLocationFilter.shouldSend (Dart) / LocationFilter.shouldSend
/// (Android) exactly, so all three layers agree on when a fix is worth
/// sending. All threshold values are read live at call time.
- (BOOL)shouldSendLocation:(CLLocation *)current now:(NSTimeInterval)now {

    if (!self.hasLastFix) return YES;

    NSTimeInterval elapsed = now - self.lastSentTime;
    double speedKmh = current.speed >= 0 ? current.speed * 3.6 : -1;
    double speedMps = current.speed >= 0 ? current.speed : 0;

    if (speedKmh < 0 && elapsed > 0) {
        CLLocation *prev = [[CLLocation alloc] initWithLatitude:self.lastLat
                                                      longitude:self.lastLon];
        double inferredDistM = [current distanceFromLocation:prev];
        speedKmh = (inferredDistM / elapsed) * 3.6;
        speedMps = inferredDistM / elapsed;
    } else if (speedKmh < 0) {
        speedKmh = kSpeedDrivingKmh();
        speedMps = speedKmh / 3.6;
    }

    KSMovementMode mode = [self movementModeForLocation:current speedKmh:speedKmh];

    double maxAccuracy;
    switch (mode) {
        case KSModeWalking: maxAccuracy = kMinAccuracyWalkingM(); break;
        case KSModeCycling: maxAccuracy = kMinAccuracyCyclingM(); break;
        default:            maxAccuracy = kMinAccuracyM();        break;
    }
    if (current.horizontalAccuracy > maxAccuracy) return NO;

    double battMult = ksBatteryMultiplier();
    double fastest;
    switch (mode) {
        case KSModeDriving:    fastest = kFastestDrivingSec() * battMult; break;
        case KSModeCycling:    fastest = kFastestCyclingSec() * battMult; break;
        case KSModeWalking:    fastest = kFastestWalkingSec() * battMult; break;
        case KSModeStationary: fastest = 0; break;
    }
    if (elapsed < fastest) return NO;

    CLLocation *prevLoc = [[CLLocation alloc] initWithLatitude:self.lastLat
                                                     longitude:self.lastLon];
    double distanceM = [current distanceFromLocation:prevLoc];

    if (mode == KSModeStationary) {
        double heartbeat = kHeartbeatSec();
        return elapsed >= heartbeat;
    }

    // Moving modes -- time OR distance (whichever fires first). A brief stop
    // (red light, junction) shouldn't delay the next send by a full extra
    // interval just because distanceM reset to zero.
    double interval     = kIntervalSec() * battMult;
    double adaptiveDist = ksAdaptiveDistanceFilter(mode, speedMps);

    if (elapsed >= interval) return YES;
    if (distanceM >= adaptiveDist) return YES;

    // Heading-change threshold -- mode-specific, speed-gated.
    if (mode != KSModeWalking && self.lastHeading >= 0 && current.course >= 0
        && speedKmh > 8.0) {
        double angleThreshold = (mode == KSModeCycling) ? 45.0 : kAngleDrivingDeg();
        double diff = fabs(current.course - self.lastHeading);
        if (diff > 180.0) diff = 360.0 - diff;
        if (diff >= angleThreshold && angleThreshold > 0) return YES;
    }

    return NO;
}

#pragma mark - Auto-flush

- (void)requestFlush {
    [self autoFlushQueueIfNeeded];
}

- (void)autoFlushQueueIfNeeded {
    if (self.isFlushing) return;
    if (self.trackingURL.length == 0 || self.subjectId.length == 0) return;

    NSArray<NSDictionary *> *rows = [[LocationQueue shared] dequeueAll];
    if (rows.count == 0) return;

    self.isFlushing = YES;

    NSUserDefaults *ud = [NSUserDefaults standardUserDefaults];
    [ud setBool:YES forKey:kFlushingKey];
    [ud synchronize];

    dispatch_async(dispatch_get_main_queue(), ^{
        [[NSNotificationCenter defaultCenter]
                postNotificationName:KSAutoFlushDidBeginNotification
                              object:@(rows.count)];
    });

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_BACKGROUND, 0), ^{
        NSUInteger sent = 0, kept = 0, discarded = 0;

        for (NSDictionary *row in rows) {
            NSInteger entryId = [row[@"id"] integerValue];

            CLLocationCoordinate2D coord = {
                    [row[@"lat"] doubleValue],
                    [row[@"lon"] doubleValue],
            };
            NSDate *fixDate = [NSDate dateWithTimeIntervalSince1970:
                    [row[@"timestamp"] doubleValue]];
            CLLocation *loc = [[CLLocation alloc]
                    initWithCoordinate:coord
                              altitude:[row[@"altitude"] doubleValue]
                    horizontalAccuracy:[row[@"accuracy"] doubleValue]
                      verticalAccuracy:-1
                                course:[row[@"heading"] doubleValue]
                                 speed:[row[@"speed"] doubleValue]
                             timestamp:fixDate];

            NSInteger status = [self flushSendLocation:loc
                                               battery:[row[@"battery"] integerValue]];

            if (status >= 200 && status < 300) {
                [[LocationQueue shared] deleteEntryWithId:entryId];
                NSTimeInterval sentAt = [[NSDate date] timeIntervalSince1970];
                [self saveLastSentCache:loc sentAt:sentAt];
                sent++;
            } else if (status >= 400 && status < 500) {
                [[LocationQueue shared] deleteEntryWithId:entryId];
                discarded++;
            } else if (status == -1) {
                kept += rows.count - sent - discarded;
                break;
            } else {
                kept++;
            }
        }

        NSUserDefaults *defaults = [NSUserDefaults standardUserDefaults];
        [defaults setBool:NO forKey:kFlushingKey];
        [defaults synchronize];
        self.isFlushing = NO;

        dispatch_async(dispatch_get_main_queue(), ^{
            [[NSNotificationCenter defaultCenter]
                    postNotificationName:KSAutoFlushDidEndNotification
                                  object:@[@(sent), @(kept), @(discarded)]];
        });
    });
}

/// Builds the query-string URL for a fix using the configured field keys.
- (NSURL *)buildRequestURLForLat:(double)lat lon:(double)lon
                        timestamp:(NSTimeInterval)ts speed:(double)speedMps
                          bearing:(double)bearing altitude:(double)altitude
                         accuracy:(double)accuracy battery:(double)battPct {
    NSURLComponents *comps = [NSURLComponents componentsWithString:self.trackingURL];
    comps.queryItems = @[
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"subjectId" fallback:@"id"]
                                        value:self.subjectId],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"timestamp" fallback:@"timestamp"]
                                        value:[NSString stringWithFormat:@"%.0f", ts]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"latitude" fallback:@"lat"]
                                        value:[NSString stringWithFormat:@"%.7f", lat]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"longitude" fallback:@"lon"]
                                        value:[NSString stringWithFormat:@"%.7f", lon]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"speed" fallback:@"speed"]
                                        value:[NSString stringWithFormat:@"%.2f", speedMps * 3.6]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"bearing" fallback:@"bearing"]
                                        value:[NSString stringWithFormat:@"%.1f", bearing]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"altitude" fallback:@"altitude"]
                                        value:[NSString stringWithFormat:@"%.1f", altitude]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"accuracy" fallback:@"accuracy"]
                                        value:[NSString stringWithFormat:@"%.1f", accuracy]],
            [NSURLQueryItem queryItemWithName:[self fieldKeyFor:@"battery" fallback:@"batt"]
                                        value:[NSString stringWithFormat:@"%.1f", battPct]],
    ];
    return comps.URL;
}

/// Synchronous HTTP send used only by the flush path.
/// Returns HTTP status code, or -1 on network/timeout error.
- (NSInteger)flushSendLocation:(CLLocation *)loc battery:(NSInteger)battPct {
    NSURL *url = [self buildRequestURLForLat:loc.coordinate.latitude
                                          lon:loc.coordinate.longitude
                                    timestamp:loc.timestamp.timeIntervalSince1970
                                        speed:loc.speed
                                      bearing:loc.course
                                     altitude:loc.altitude
                                     accuracy:loc.horizontalAccuracy
                                      battery:battPct];
    if (!url) return -1;

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 20.0;

    __block NSInteger statusCode = -1;
    dispatch_semaphore_t sem = dispatch_semaphore_create(0);

    [[[NSURLSession sharedSession]
            dataTaskWithRequest:req
              completionHandler:^(NSData *d, NSURLResponse *r, NSError *e) {
                  if (!e) statusCode = ((NSHTTPURLResponse *)r).statusCode;
                  dispatch_semaphore_signal(sem);
              }] resume];

    dispatch_semaphore_wait(sem, dispatch_time(DISPATCH_TIME_NOW, 25 * NSEC_PER_SEC));
    return statusCode;
}

#pragma mark - Send (live fixes, async)

- (void)sendLocationToServer:(CLLocation *)location tag:(NSString *)tag {
    if (self.trackingURL.length == 0 || self.subjectId.length == 0) {
        [[LocationQueue shared] enqueue:location];
        return;
    }

    NSTimeInterval ts     = location.timestamp.timeIntervalSince1970;
    NSTimeInterval sentAt = [[NSDate date] timeIntervalSince1970];
    float batt     = [UIDevice currentDevice].batteryLevel;
    double battPct = (batt >= 0) ? batt * 100.0 : 0;

    NSURL *url = [self buildRequestURLForLat:location.coordinate.latitude
                                          lon:location.coordinate.longitude
                                    timestamp:ts
                                        speed:location.speed
                                      bearing:location.course
                                     altitude:location.altitude
                                     accuracy:location.horizontalAccuracy
                                      battery:battPct];
    if (!url) {
        [[LocationQueue shared] enqueue:location];
        return;
    }

    NSMutableURLRequest *req = [NSMutableURLRequest requestWithURL:url];
    req.HTTPMethod      = @"POST";
    req.timeoutInterval = 20.0;

    // Optimistic in-memory update BEFORE dispatching the async request --
    // otherwise every CLLocation callback arriving during the HTTP
    // round-trip (200ms - 3s typical) would see the stale lastSentTime and
    // pass shouldSendLocation:, producing a burst of near-duplicate points.
    // Not reverted on failure: the location is queued on failure instead, so
    // no data is lost, and reverting would re-open the duplicate-burst
    // window. NSUserDefaults (on-disk) is only written on confirmed 2xx so
    // the persisted baseline stays clean for crash-recovery loads.
    self.lastLat      = location.coordinate.latitude;
    self.lastLon      = location.coordinate.longitude;
    self.lastHeading  = location.course;
    self.lastSpeedKmh = location.speed * 3.6;
    self.lastSentTime = sentAt;
    self.hasLastFix   = YES;

    __block CLLocation    *sentLocation = location;
    __block NSTimeInterval sentTime     = sentAt;

    NSURLSessionDataTask *task = [[NSURLSession sharedSession]
            dataTaskWithRequest:req
              completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
                  if (error) {
                      [[LocationQueue shared] enqueue:sentLocation];
                      return;
                  }

                  NSInteger status = ((NSHTTPURLResponse *)response).statusCode;

                  if (status >= 200 && status < 300) {
                      [self saveLastSentCache:sentLocation sentAt:sentTime];
                  } else if (status >= 500) {
                      [[LocationQueue shared] enqueue:sentLocation];
                  }
                  // 4xx -- malformed; don't retry.
              }];

    [task resume];
}

#pragma mark - Last-sent cache (shared with Flutter via loc_cache_* keys)

- (void)loadLastSentCache {
    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    double lat   = [d doubleForKey:kLastSentLatKey];
    double lon   = [d doubleForKey:kLastSentLonKey];
    NSString *tsStr = [d stringForKey:kLastSentTimeKey];

    if (lat == 0 && lon == 0 && tsStr == nil) {
        self.hasLastFix = NO;
        return;
    }

    self.lastLat      = lat;
    self.lastLon      = lon;
    self.lastHeading  = [d doubleForKey:kLastSentHeadingKey];
    self.lastSpeedKmh = [d doubleForKey:kLastSentSpeedKey];

    // Flutter's DateTime.toIso8601String() can produce 3- or 6-digit
    // fractional seconds -- try both so this never silently fails and
    // leaves hasLastFix = NO (which would make every fix pass rule 1).
    NSDate *date = nil;
    NSArray<NSString *> *formats = @[
            @"yyyy-MM-dd'T'HH:mm:ss.SSSSSS",
            @"yyyy-MM-dd'T'HH:mm:ss.SSS",
            @"yyyy-MM-dd'T'HH:mm:ss",
    ];
    for (NSString *fmt in formats) {
        NSDateFormatter *iso = [[NSDateFormatter alloc] init];
        iso.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
        iso.dateFormat = fmt;
        date = [iso dateFromString:tsStr];
        if (date) break;
    }
    self.lastSentTime = date ? date.timeIntervalSince1970 : 0;
    self.hasLastFix   = (self.lastSentTime > 0);
}

- (void)saveLastSentCache:(CLLocation *)location sentAt:(NSTimeInterval)sentTime {
    self.lastLat      = location.coordinate.latitude;
    self.lastLon      = location.coordinate.longitude;
    self.lastHeading  = location.course;
    self.lastSpeedKmh = location.speed * 3.6;
    self.lastSentTime = sentTime;
    self.hasLastFix   = YES;

    NSDateFormatter *iso = [[NSDateFormatter alloc] init];
    iso.locale     = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSSSSS";
    NSString *tsStr = [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:sentTime]];

    NSUserDefaults *d = [NSUserDefaults standardUserDefaults];
    [d setDouble:self.lastLat      forKey:kLastSentLatKey];
    [d setDouble:self.lastLon      forKey:kLastSentLonKey];
    [d setDouble:self.lastHeading  forKey:kLastSentHeadingKey];
    [d setDouble:self.lastSpeedKmh forKey:kLastSentSpeedKey];
    [d setObject:tsStr             forKey:kLastSentTimeKey];
    [d synchronize];
}

#pragma mark - Helpers

- (void)enqueueIfAcceptable:(CLLocation *)loc
                        tag:(NSString *)tag
                maxAccuracy:(double)maxAcc {
    if (loc.horizontalAccuracy <= 0 || loc.horizontalAccuracy > maxAcc) return;
    [[LocationQueue shared] enqueue:loc];
}

#pragma mark - NSURLSessionDelegate

- (void)URLSession:(NSURLSession *)session
              task:(NSURLSessionTask *)task
didCompleteWithError:(NSError *)error {
    // Intentionally empty -- per-request completion handlers (above) already
    // handle success/failure; this delegate method exists only to satisfy
    // the background NSURLSession's requirement for a delegate.
}

@end
