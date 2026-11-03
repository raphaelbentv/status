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
// Absente des services antérieurs : n'appeler que si l'état annonce « extendSupported ».
- (void)extendMinutes:(NSInteger)minutes reply:(void (^)(NSDictionary *))reply;
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

// Propriétaire d'une session, désigné par le jeton non nul attribué à sa connexion à l'acceptation.
// Contrairement à une référence faible, une connexion déjà libérée garde son jeton : sa déconnexion
// se reconnaît toujours, et un client sans session ne se confond jamais avec « aucun propriétaire ».
@interface TMLidOwnership : NSObject
@property (readonly) uint64_t owner;  // 0 : aucun propriétaire
- (BOOL)isOwner:(uint64_t)client;
// Attribue la session à ce client si elle est libre ; YES s'il en est (désormais) propriétaire.
- (BOOL)claim:(uint64_t)client;
// YES si ce client était le propriétaire, la session étant alors libérée.
- (BOOL)releaseClient:(uint64_t)client;
- (void)clear;
@end
