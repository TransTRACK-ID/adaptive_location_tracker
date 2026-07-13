#import <Foundation/Foundation.h>
#import <CoreLocation/CoreLocation.h>

@interface LocationQueue : NSObject
+ (instancetype)shared;
- (void)enqueue:(CLLocation *)location;
- (NSArray<NSDictionary *> *)dequeueAll;
/// Delete a single row by its SQLite row ID.
/// Called by Flutter's flushKilledLocationQueue after each entry is
/// successfully sent (or confirmed as a 4xx non-retryable error), so only
/// failed entries remain in the queue across app sessions.
- (void)deleteEntryWithId:(NSInteger)entryId;
- (void)clear;
@end
