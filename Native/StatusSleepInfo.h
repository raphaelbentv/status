// StatusSleepInfo — ce qui empêche le Mac de dormir, lu sans droits root.
//
// Deux couches, comme StatusSystemMonitor : le regroupement et le filtrage sont purs (testés sur des
// relevés fabriqués), la lecture réelle passe par IOKit (IOPMCopyAssertionsByProcess) et le registre
// (SleepDisabled). Lecture seule : Status n'exécute jamais `pmset`.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// En dessous, une assertion est du bruit (powerd, nsurlsessiond, sharingd… posent des assertions de
// quelques secondes en continu). Masquée par défaut, affichable via « Tout afficher ».
extern const NSTimeInterval TMSleepNoiseSeconds;

// Relevé IOKit { pid: [assertion] } → liste à plat des assertions qui retiennent la veille
// (système ou écran), les autres types (UserIsActive, BackgroundTask…) étant écartés :
// [{ pid, name, type, label, seconds }]. Les alias historiques sont ramenés au type canonique
// (NoIdleSleepAssertion → PreventUserIdleSystemSleep). `seconds` vaut -1 si le début est inconnu.
NSArray<NSDictionary *> *TMSleepFlattenAssertions(NSDictionary *byPid, NSDate *now);

// Regroupe par app : [{ name, pids, seconds (la plus longue), blocksSystem, blocksDisplay,
// items: [{ type, label, seconds }] }], la plus ancienne d'abord. `hidden` reçoit le bruit (assertions
// courtes ou posées par powerd/nsurlsessiond), regroupé de la même façon.
NSArray<NSDictionary *> *TMSleepGroupAssertions(NSArray<NSDictionary *> *flat,
                                                NSArray<NSDictionary *> * _Nullable * _Nullable hidden);

// SleepDisabled sans session capot fermé de Status : le mode capot fermé ne pourra pas démarrer
// (il sauvegarde puis restaure le réglage), et seul l'utilisateur peut lever ce blocage.
BOOL TMSleepDisabledBlocksLidMode(BOOL sleepDisabled, BOOL statusLidSession);

// Relevé réel : { disabled, sleepMinutes (absent si illisible), onBattery, groups, hidden }.
NSDictionary *TMSleepInfoRead(void);

NS_ASSUME_NONNULL_END
