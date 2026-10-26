// Mode capot fermé sur MacBook Air : profil sans ventilateur et session constante.
// Les modèles sont toujours injectés : aucun test ne dépend du Mac qui les exécute.
#import <Foundation/Foundation.h>
#import "StatusLidMode.h"
#import "StatusMachine.h"
#include <math.h>
static int checks = 0, failures = 0;
static void Check(BOOL ok, NSString *label) { checks++; if (!ok) { failures++; NSLog(@"FAIL: %@", label); } }

@interface AirPower : NSObject <TMLidBackend>
@property NSMutableDictionary *power;
@property NSDictionary *journal;
@property BOOL failLowPower;
@property NSUInteger modeWrites;
@end
@implementation AirPower
- (instancetype)init { if ((self = [super init])) _power = [@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2} mutableCopy]; return self; }
- (NSDictionary *)powerSettings { return [self.power copy]; }
- (BOOL)setSleepDisabled:(BOOL)disabled { self.power[@"sleepDisabled"] = @(disabled); return YES; }
- (BOOL)setPowerMode:(NSInteger)mode battery:(BOOL)battery { self.modeWrites++; if (mode == 1 && self.failLowPower) return NO; self.power[battery ? @"batteryMode" : @"acMode"] = @(mode); return YES; }
- (NSDictionary *)loadJournal { return self.journal; }
- (BOOL)saveJournal:(NSDictionary *)journal { self.journal = [journal copy]; return YES; }
- (BOOL)clearJournal { self.journal = nil; return YES; }
@end

static NSString *const Air = @"Mac15,12";   // MacBook Air 13" M3
static NSString *const Pro = @"Mac16,6";    // MacBook Pro 16" M4 Max
static TMLidMode *ModeOn(NSString *model, AirPower *backend) {
    TMLidMode *mode = [[TMLidMode alloc] initWithBackend:backend];
    mode.machineModel = model;
    return mode;
}

int main(void) { @autoreleasepool {
    // ── Détection : liste fermée d'identifiants Apple Silicon ─────────────────────────────────────────
    for (NSString *model in TMFanlessMacBookModels()) Check(TMMachineIsFanlessMacBook(model), [@"reconnu : " stringByAppendingString:model]);
    Check(TMFanlessMacBookModels().count == 7, @"sept identifiants : M1, puis M2, M3 et M4 en 13 et 15 pouces");
    for (NSString *model in @[@"Mac16,6", @"Mac16,5", @"Mac15,3", @"Mac14,10", @"MacBookPro18,1", @"Mac14,3", @"Mac15,14", @"Mac16,1", @"MacBookAir9,1", @"MacBookAir8,2", @""])
        Check(!TMMachineIsFanlessMacBook(model), [@"pas un Air sans ventilateur : " stringByAppendingString:model]);
    Check(!TMMachineIsFanlessMacBook(nil) && !TMMachineIsFanlessMacBook((id)@5) && !TMMachineIsFanlessMacBook((id)NSNull.null), @"modèle absent ou invalide : jamais un Air");
    Check(!TMMachineIsFanlessMacBook(@"mac15,12") && !TMMachineIsFanlessMacBook(@" Mac15,12"), @"comparaison exacte : pas de variante de casse ni d'espace");
    NSString *real = TMMachineModel();
    Check(real == nil || real.length > 0, @"le modèle réel se lit (ou renvoie nil), jamais une chaîne vide");

    // ── Règle d'arrêt : profil à ventilateurs inchangé ────────────────────────────────────────────────
    Check(!TMLidStopReasonForProfile(80, 0, 100, 200, 90, NO, NO), @"Pro : état nominal admis");
    for (NSInteger thermal = 1; thermal <= 3; thermal++)
        Check(TMLidStopReasonForProfile(80, thermal, 100, 200, 90, NO, NO) != nil, @"Pro : toute pression thermique arrête, dès fair");
    for (NSInteger thermal = 1; thermal <= 3; thermal++)
        Check([TMLidStopReason(80, thermal, 100, 200, 90) isEqual:TMLidStopReasonForProfile(80, thermal, 100, 200, 90, NO, NO)], @"l'ancienne fonction vaut le profil Pro");

    // ── Règle d'arrêt : profil MacBook Air ────────────────────────────────────────────────────────────
    Check(!TMLidStopReasonForProfile(80, 1, 100, 200, 90, YES, NO), @"Air : « fair » n'arrête plus");
    Check(!TMLidStopReasonForProfile(80, 2, 100, 200, 90, YES, NO), @"Air : « serious » n'arrête plus (bridage ordinaire, comme ouvert)");
    Check(TMLidStopReasonForProfile(80, 3, 100, 200, 90, YES, NO) != nil, @"Air : « critical » arrête toujours");
    Check([TMLidStopReasonForProfile(80, 3, 100, 200, 90, YES, YES) containsString:@"critique"], @"Air : le motif dit « critique »");
    Check(TMLidStopReasonForProfile(30, 0, 100, 200, 90, YES, NO) != nil && TMLidStopReasonForProfile(30, 0, 100, 0, 90, YES, YES) != nil, @"Air : batterie à 30 % arrête, constant ou non");
    Check(!TMLidStopReasonForProfile(31, 0, 100, 200, 90, YES, YES), @"Air : 31 % suffit");
    Check(TMLidStopReasonForProfile(NAN, 0, 100, 200, 90, YES, YES) != nil && TMLidStopReasonForProfile(-1, 0, 100, 200, 90, YES, YES) != nil
          && TMLidStopReasonForProfile(101, 0, 100, 200, 90, YES, YES) != nil, @"Air : batterie illisible refuse");
    Check(TMLidStopReasonForProfile(80, 0, 200, 200, 199, YES, NO) != nil, @"Air minutée : l'échéance arrête");
    Check(!TMLidStopReasonForProfile(80, 0, 1e9, 0, 1e9 - 1, YES, YES), @"Air constante : aucune échéance, même très tard");
    Check(TMLidStopReasonForProfile(80, 0, 121, 0, 100, YES, YES) != nil, @"Air constante : Status muet 21 s arrête quand même");
    Check(TMLidStopReasonForProfile(80, 0, 100, 0, 101, YES, YES) != nil, @"Air constante : horloge qui recule arrête");

    // ── Session sur Pro : le mode constant est refusé, rien n'est modifié ─────────────────────────────
    AirPower *b = [AirPower new]; TMLidMode *m = ModeOn(Pro, b);
    [m startMinutes:TMLidConstantMinutes battery:80 thermal:0 now:100];
    Check(!m.active && !m.constant && b.journal == nil, @"Pro : le mode constant ne démarre pas");
    Check([m.message containsString:@"MacBook Air"], @"Pro : le message explique la réserve aux MacBook Air");
    Check([b.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"Pro : aucun réglage touché");
    for (id unknown in @[@"Mac99,1", @"", [NSNull null]]) {
        b = [AirPower new]; m = ModeOn(unknown == NSNull.null ? nil : unknown, b);
        if (m.machineModel == nil) m.machineModel = @"";   // modèle illisible
        [m startMinutes:0 battery:80 thermal:0 now:100];
        Check(!m.active, @"modèle inconnu ou illisible : constant refusé");
    }
    b = [AirPower new]; m = ModeOn(Pro, b);
    [m startMinutes:17 battery:65 thermal:0 now:100];
    Check(m.active && !m.constant && !m.fanlessProfile && m.deadline == 1120, @"Pro : une session minutée reste comme avant");
    [m tickBattery:80 thermal:1 now:110];
    Check(!m.active, @"Pro : la pression thermique arrête toujours la session");

    // ── Session sur Air : constante ────────────────────────────────────────────────────────────────────
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:TMLidConstantMinutes battery:80 thermal:0 now:100];
    Check(m.active && m.constant && m.fanlessProfile && m.deadline == 0, @"Air : session constante, sans échéance");
    Check([b.power isEqual:@{@"sleepDisabled":@1, @"batteryMode":@0, @"acMode":@2}], @"Air : seule la veille est bloquée, les modes d'énergie ne sont pas touchés");
    Check(b.modeWrites == 0, @"Air : aucune écriture de mode d'énergie");
    Check(b.journal != nil && [b.journal[@"lowPowerForced"] isEqual:@0], @"Air : journal écrit d'abord, et il dit qu'aucune faible consommation n'a été imposée");
    [m heartbeatAt:105]; [m tickBattery:79 thermal:0 now:110];
    Check(m.active, @"Air : le battement de cœur maintient la session");
    // Un jour, un mois, un an plus tard : toujours active tant que Status répond et que la batterie tient.
    double t = 110;
    for (int i = 0; i < 2000; i++) { t += 5; [m heartbeatAt:t]; [m tickBattery:60 thermal:(i % 3 == 0 ? 2 : 1) now:t]; }
    Check(m.active, @"Air : 2000 ticks (≈ 2 h 45) sous bridage thermique ordinaire : toujours active");
    t = 5e7; [m heartbeatAt:t]; [m tickBattery:60 thermal:0 now:t];
    Check(m.active, @"Air : plus d'un an plus tard, toujours active (aucune échéance cachée)");
    [m tickBattery:60 thermal:3 now:t];
    Check(!m.active && [b.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"Air : contrainte critique : arrêt et réglages restaurés exactement");
    Check(!m.constant && !m.fanlessProfile && b.journal == nil, @"Air : après l'arrêt, plus de profil ni de journal");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    [m tickBattery:30 thermal:0 now:110];
    Check(!m.active && [b.power[@"sleepDisabled"] isEqual:@0], @"Air : batterie à 30 % : la session constante s'arrête et restaure");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    [m tickBattery:80 thermal:0 now:121];
    Check(!m.active, @"Air constante : Status muet 21 s : arrêt");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    [m stop:@"Arrêt demandé."];
    Check(!m.active && !m.constant && [m.message isEqual:@"Arrêt demandé."] && [b.power[@"sleepDisabled"] isEqual:@0], @"Air : arrêt manuel");

    // ── Démarrage refusé sur Air quand les conditions ne sont pas réunies ─────────────────────────────
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:30 thermal:0 now:100];
    Check(!m.active && b.journal == nil && [m.message containsString:@"30"], @"Air : pas de démarrage à 30 % de batterie");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:3 now:100];
    Check(!m.active && b.journal == nil, @"Air : pas de démarrage sous contrainte thermique critique");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:2 now:100];
    Check(m.active, @"Air : démarrage possible sous bridage « serious » (comme ouvert)");
    [m stop:nil];
    b = [AirPower new]; b.power[@"sleepDisabled"] = @1; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    Check(!m.active, @"Air : ne s'approprie pas un blocage extérieur de la veille");
    // Un second démarrage ne change rien à une session constante.
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    [m startMinutes:30 battery:80 thermal:0 now:200];
    Check(m.active && m.constant && m.deadline == 0, @"Air : un second démarrage ne transforme pas la session constante en minutée");
    [m stop:nil];

    // ── Session minutée sur Air : profil sans ventilateur aussi ───────────────────────────────────────
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:30 battery:80 thermal:0 now:100];
    Check(m.active && !m.constant && m.fanlessProfile && m.deadline == 1900, @"Air : session minutée, échéance conservée");
    [m heartbeatAt:105]; [m tickBattery:80 thermal:2 now:110];
    Check(m.active, @"Air : une session minutée ne s'arrête pas non plus au bridage ordinaire");
    [m heartbeatAt:1900]; [m tickBattery:80 thermal:0 now:1900];
    Check(!m.active, @"Air : mais l'échéance arrête la session minutée");

    // ── Recovery : un journal laissé par le service est restauré, constant ou non ─────────────────────
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    AirPower *after = [AirPower new]; after.power = [b.power mutableCopy]; after.journal = b.journal;
    TMLidMode *recovered = ModeOn(Air, after);
    [recovered recover];
    Check(!recovered.active && after.journal == nil && [after.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"service relancé après un crash en mode constant : réglages restaurés");

    // ── Économie d'énergie : jamais imposée sur un Air, toujours sur un Pro ────────────────────────────
    b = [AirPower new]; b.failLowPower = YES; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    Check(m.active, @"Air : un refus du mode faible consommation n'empêche rien (il n'est jamais demandé)");
    [m stop:nil];
    b = [AirPower new]; b.failLowPower = YES; m = ModeOn(Pro, b);
    [m startMinutes:17 battery:80 thermal:0 now:100];
    Check(!m.active, @"Pro : un refus du mode faible consommation annule la session, comme avant");
    b = [AirPower new]; m = ModeOn(Pro, b);
    [m startMinutes:17 battery:80 thermal:0 now:100];
    Check([b.power isEqual:@{@"sleepDisabled":@1, @"batteryMode":@1, @"acMode":@1}] && [b.journal[@"lowPowerForced"] isEqual:@1], @"Pro : faible consommation imposée et journalisée");
    [m stop:nil];
    Check([b.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"Pro : restauration exacte inchangée");
    // Sur un Air, l'utilisateur peut changer le mode d'énergie pendant la session : elle continue, et rien n'est « remis ».
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    b.power[@"batteryMode"] = @1; b.power[@"acMode"] = @1;
    [m heartbeatAt:105]; [m tickBattery:80 thermal:0 now:110];
    Check(m.active, @"Air : activer le mode économie d'énergie à la main n'arrête pas la session");
    [m stop:nil];
    Check([b.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@1, @"acMode":@1}], @"Air : à l'arrêt, le choix de l'utilisateur est respecté (rien de restauré, sauf la veille)");
    b = [AirPower new]; m = ModeOn(Air, b);
    [m startMinutes:0 battery:80 thermal:0 now:100];
    b.power[@"sleepDisabled"] = @0;   // un autre outil rend la veille
    [m heartbeatAt:105]; [m tickBattery:80 thermal:0 now:110];
    Check(!m.active, @"Air : si la veille n'est plus bloquée, la session s'arrête");
    // Pro : comportement d'avant, un mode d'énergie changé pendant la session l'arrête.
    b = [AirPower new]; m = ModeOn(Pro, b);
    [m startMinutes:17 battery:80 thermal:0 now:100];
    b.power[@"batteryMode"] = @0;
    [m heartbeatAt:105]; [m tickBattery:80 thermal:0 now:110];
    Check(!m.active, @"Pro : le mode d'énergie modifié arrête toujours la session");

    // ── Récupération : le journal dit ce qui a été imposé ──────────────────────────────────────────────
    AirPower *crash = [AirPower new]; crash.power = [@{@"sleepDisabled":@1, @"batteryMode":@1, @"acMode":@1} mutableCopy];
    crash.journal = @{@"version":@1, @"sleepDisabled":@0, @"lowPowerForced":@0, @"batteryMode":@1, @"acMode":@1};
    TMLidMode *rec = ModeOn(Air, crash); [rec recover];
    Check([crash.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@1, @"acMode":@1}] && crash.journal == nil && crash.modeWrites == 0,
          @"récupération Air : seule la veille est rendue, les modes de l'utilisateur ne sont pas touchés");
    crash = [AirPower new]; crash.power = [@{@"sleepDisabled":@1, @"batteryMode":@1, @"acMode":@1} mutableCopy];
    crash.journal = @{@"version":@1, @"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2};   // ancien journal : pas de clé
    rec = ModeOn(Pro, crash); [rec recover];
    Check([crash.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"ancien journal sans clé : restauré comme avant (faible consommation supposée imposée)");
    crash = [AirPower new]; crash.power = [@{@"sleepDisabled":@1, @"batteryMode":@1, @"acMode":@1} mutableCopy];
    crash.journal = @{@"version":@1, @"sleepDisabled":@0, @"lowPowerForced":@1, @"batteryMode":@0, @"acMode":@2};
    rec = ModeOn(Pro, crash); [rec recover];
    Check([crash.power isEqual:@{@"sleepDisabled":@0, @"batteryMode":@0, @"acMode":@2}], @"journal Pro : restauré exactement");
    for (id bad in @[@"yes", @2, @-1, [NSNull null]]) {
        crash = [AirPower new]; crash.journal = @{@"version":@1, @"sleepDisabled":@0, @"lowPowerForced":bad, @"batteryMode":@0, @"acMode":@2};
        rec = ModeOn(Air, crash); [rec recover];
        Check(rec.restorationPending && !rec.active, @"journal avec une clé lowPowerForced invalide : refusé, activation bloquée");
    }

    printf("Capot fermé Air : %d vérifications, %d échecs.\n", checks, failures);
    return failures ? 1 : 0;
}}
