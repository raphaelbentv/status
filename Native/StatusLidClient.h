#import <Foundation/Foundation.h>
@interface TMLidClient : NSObject
@property (copy) void (^onChange)(void);
@property (readonly, copy) NSDictionary *snapshot;
- (void)refresh;
- (void)requestAuthorization;
- (void)startMinutes:(NSInteger)minutes;
- (void)stop;
- (void)invalidate;
@end
