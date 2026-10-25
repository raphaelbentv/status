#import <Foundation/Foundation.h>
#define TMLidServiceName @"com.raphael.status.lid-helper"
#define TMLidServicePlist @"com.raphael.status.lid-helper.plist"
// Identité de signature du helper, commune aux deux modes d'installation.
#define TMLidHelperIdentifier @"com.raphael.status.lid-helper"
// Le paquet Installer utilise un label et un nom Mach distincts : un ancien enregistrement
// SMAppService (recréé par smd après bootout) ne peut ainsi plus bloquer son bootstrap.
#define TMLidInstalledServiceName @"com.raphael.status.lid-service"
#define TMLidInstalledHelperPath @"/Library/PrivilegedHelperTools/com.raphael.status.lid-helper"
#define TMLidInstalledPlistPath @"/Library/LaunchDaemons/com.raphael.status.lid-service.plist"
@protocol TMLidService
- (void)statusWithReply:(void (^)(NSDictionary *))reply;
- (void)startMinutes:(NSInteger)minutes reply:(void (^)(NSDictionary *))reply;
- (void)stopWithReply:(void (^)(NSDictionary *))reply;
- (void)startFanBoostMinutes:(NSInteger)minutes percent:(NSInteger)percent reply:(void (^)(NSDictionary *))reply;
- (void)stopFanBoostWithReply:(void (^)(NSDictionary *))reply;
@end
// Les deux processus exigent la même identité de signature ET l'identifiant exact du pair.
NSString *TMLidPeerRequirement(NSString *identifier);

// Apple-issued chain, code integrity, and the pinned peer certificate are all required.
BOOL TMLidSigningReady(void);

// Installation classique, approuvée par l’administrateur via Installer.app.
BOOL TMLidInstallerReady(void);
BOOL TMLidInstalledServiceReady(void);
