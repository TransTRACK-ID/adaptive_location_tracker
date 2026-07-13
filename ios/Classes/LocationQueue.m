#import "LocationQueue.h"
#import <sqlite3.h>
#import <UIKit/UIKit.h>

@implementation LocationQueue {
    sqlite3 *_db;
    NSString *_dbPath;
}

+ (instancetype)shared {
    static LocationQueue *instance = nil;
    static dispatch_once_t onceToken;
    dispatch_once(&onceToken, ^{ instance = [[self alloc] init]; });
    return instance;
}

- (instancetype)init {
    self = [super init];
    NSString *docs = NSSearchPathForDirectoriesInDomains(
            NSDocumentDirectory, NSUserDomainMask, YES).firstObject;
    _dbPath = [docs stringByAppendingPathComponent:@"adaptive_location_tracker_queue.db"];
    [self openDatabase];
    return self;
}

- (void)openDatabase {
    sqlite3_open(_dbPath.UTF8String, &_db);
    sqlite3_exec(_db,
                 "CREATE TABLE IF NOT EXISTS queue ("
                 "id INTEGER PRIMARY KEY AUTOINCREMENT,"
                 "lat REAL, lon REAL, timestamp REAL,"
                 "accuracy REAL, speed REAL, heading REAL, altitude REAL,"
                 "battery INTEGER DEFAULT 0"
                 ");",
                 NULL, NULL, NULL);
    // Migrate existing databases that predate the battery column.
    sqlite3_exec(_db,
                 "ALTER TABLE queue ADD COLUMN battery INTEGER DEFAULT 0;",
                 NULL, NULL, NULL); // silently fails if column already exists
}

- (void)enqueue:(CLLocation *)loc {
    // Capture battery at fix time so flushKilledLocationQueue can pass the
    // correct historical value to sentDataWithBattery instead of the current
    // (potentially hours-later) reading.
    float rawBatt = [UIDevice currentDevice].batteryLevel;
    int battPct = (rawBatt >= 0) ? (int)(rawBatt * 100.0) : 0;

    NSString *sql = @"INSERT INTO queue "
                    "(lat, lon, timestamp, accuracy, speed, heading, altitude, battery) "
                    "VALUES (?, ?, ?, ?, ?, ?, ?, ?)";
    sqlite3_stmt *stmt;
    sqlite3_prepare_v2(_db, sql.UTF8String, -1, &stmt, NULL);
    sqlite3_bind_double(stmt, 1, loc.coordinate.latitude);
    sqlite3_bind_double(stmt, 2, loc.coordinate.longitude);
    sqlite3_bind_double(stmt, 3, loc.timestamp.timeIntervalSince1970);
    sqlite3_bind_double(stmt, 4, loc.horizontalAccuracy);
    sqlite3_bind_double(stmt, 5, loc.speed);
    sqlite3_bind_double(stmt, 6, loc.course);
    sqlite3_bind_double(stmt, 7, loc.altitude);
    sqlite3_bind_int(stmt,    8, battPct);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

- (NSArray<NSDictionary *> *)dequeueAll {
    NSMutableArray *results = [NSMutableArray new];
    sqlite3_stmt *stmt;
    sqlite3_prepare_v2(_db,
                       "SELECT id, lat, lon, timestamp, accuracy, speed, heading, altitude, battery "
                       "FROM queue ORDER BY timestamp ASC",
                       -1, &stmt, NULL);
    while (sqlite3_step(stmt) == SQLITE_ROW) {
        [results addObject:@{
                @"id":        @(sqlite3_column_int(stmt,    0)),
                @"lat":       @(sqlite3_column_double(stmt, 1)),
                @"lon":       @(sqlite3_column_double(stmt, 2)),
                @"timestamp": @(sqlite3_column_double(stmt, 3)),
                @"accuracy":  @(sqlite3_column_double(stmt, 4)),
                @"speed":     @(sqlite3_column_double(stmt, 5)),
                @"heading":   @(sqlite3_column_double(stmt, 6)),
                @"altitude":  @(sqlite3_column_double(stmt, 7)),
                @"battery":   @(sqlite3_column_int(stmt,    8)),
        }];
    }
    sqlite3_finalize(stmt);
    return results;
}

- (void)clear {
    sqlite3_exec(_db, "DELETE FROM queue;", NULL, NULL, NULL);
}

- (void)deleteEntryWithId:(NSInteger)entryId {
    sqlite3_stmt *stmt;
    sqlite3_prepare_v2(_db, "DELETE FROM queue WHERE id = ?;", -1, &stmt, NULL);
    sqlite3_bind_int64(stmt, 1, (sqlite3_int64)entryId);
    sqlite3_step(stmt);
    sqlite3_finalize(stmt);
}

@end
