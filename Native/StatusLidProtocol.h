#import <Foundation/Foundation.h>
#define TMLidServiceName @"com.raphael.status.lid-helper"
#define TMLidServicePlist @"com.raphael.status.lid-helper.plist"
@protocol TMLidService
- (void)statusWithReply:(void (^)(NSDictionary *))reply;
- (void)startMinutes:(NSInteger)minutes reply:(void (^)(NSDictionary *))reply;
- (void)stopWithReply:(void (^)(NSDictionary *))reply;
@end
// Les deux processus exigent la même identité de signature ET l'identifiant exact du pair.
NSString *TMLidPeerRequirement(NSString *identifier);
