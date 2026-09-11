#import <Foundation/Foundation.h>

// Borne volontairement les sessions ; une reconnexion de l'app ne prolonge jamais une session.
BOOL TMLidDurationAllowed(NSInteger minutes);
NSString *TMLidStopReason(double batteryPercent, NSInteger thermalState, double now,
                         double deadline, double lastHeartbeat);
NSDictionary *TMLidParsePowerSettings(NSString *text);

@protocol TMLidBackend <NSObject>
- (NSDictionary *)powerSettings;
- (BOOL)setSleepDisabled:(BOOL)disabled;
- (BOOL)setPowerMode:(NSInteger)mode battery:(BOOL)battery;
- (NSDictionary *)loadJournal;
- (BOOL)saveJournal:(NSDictionary *)journal;
- (BOOL)clearJournal;
@end

@interface TMLidMode : NSObject
- (instancetype)initWithBackend:(id<TMLidBackend>)backend;
@property (readonly) BOOL active;
@property (readonly) BOOL restorationPending;
@property (readonly) double deadline;
@property (readonly, copy) NSString *message;
- (void)recover;
- (void)startMinutes:(NSInteger)minutes battery:(double)battery thermal:(NSInteger)thermal now:(double)now;
- (void)heartbeatAt:(double)now;
- (void)tickBattery:(double)battery thermal:(NSInteger)thermal now:(double)now;
- (void)stop:(NSString *)reason;
@end
