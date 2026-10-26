#import <Foundation/Foundation.h>
#import "StatusMachine.h"

// Borne volontairement les sessions ; une reconnexion de l'app ne prolonge jamais une session.
BOOL TMLidDurationAllowed(NSInteger minutes);
// « Durée » 0 : session constante, sans échéance. Réservée aux MacBook Air (sans ventilateur) : voir StatusMachine.h.
extern const NSInteger TMLidConstantMinutes;
NSString *TMLidStopReason(double batteryPercent, NSInteger thermalState, double now,
                         double deadline, double lastHeartbeat);
// Même règle d'arrêt, avec le profil de la machine. `fanless` : MacBook Air, que macOS bride de la même façon
// ouvert ou fermé — seule une contrainte thermique CRITIQUE l'arrête, pas la première (« fair »). `constant` :
// pas d'échéance. Sans ventilateur à protéger, les autres garde-fous (batterie à 30 %, perte de contact avec
// Status, réglages modifiés) restent inchangés.
NSString *TMLidStopReasonForProfile(double batteryPercent, NSInteger thermalState, double now,
                                    double deadline, double lastHeartbeat, BOOL fanless, BOOL constant);
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
// Identifiant de modèle de la machine (« Mac16,6 »). nil : le vrai, lu par sysctl au démarrage d'une session.
// Ne se règle que dans les tests : le service n'expose aucun moyen de le fixer à distance.
@property (copy) NSString *machineModel;
@property (readonly) double deadline;
// Session sans échéance (MacBook Air) : `deadline` vaut alors 0 et ne veut rien dire.
@property (readonly) BOOL constant;
// Profil MacBook Air appliqué à la session en cours (thermique : seul « critique » arrête).
@property (readonly) BOOL fanlessProfile;
@property (readonly, copy) NSString *message;
- (void)recover;
- (void)startMinutes:(NSInteger)minutes battery:(double)battery thermal:(NSInteger)thermal now:(double)now;
- (void)heartbeatAt:(double)now;
- (void)tickBattery:(double)battery thermal:(NSInteger)thermal now:(double)now;
- (void)stop:(NSString *)reason;
@end
