#import <Foundation/Foundation.h>
@interface TMLidClient : NSObject
@property (copy) void (^onChange)(void);
@property (readonly, copy) NSDictionary *snapshot;
- (void)refresh;
- (void)requestAuthorization;
- (void)startMinutes:(NSInteger)minutes;
// Session sans échéance, réservée aux MacBook Air (sans ventilateur). Le service revérifie la machine.
- (void)startConstant;
- (void)stop;
- (void)startFanBoostMinutes:(NSInteger)minutes percent:(NSInteger)percent;
- (void)stopFanBoost;
- (void)invalidate;
@end
