#import "StatusLidMode.h"
#import <math.h>

BOOL TMLidDurationAllowed(NSInteger minutes) { return minutes >= 1 && minutes <= 240; }
const NSInteger TMLidConstantMinutes = 0;
NSString *TMLidStopReasonForProfile(double battery, NSInteger thermal, double now, double deadline, double heartbeat,
                                    BOOL fanless, BOOL constant) {
    if (!isfinite(battery) || battery < 0 || battery > 100) return @"Niveau de batterie indisponible.";
    if (battery <= 30) return @"Batterie à 30 % ou moins.";
    if (fanless) {
        // MacBook Air : macOS le bride de la même façon ouvert ou fermé, sans ventilateur à étouffer. « fair » et
        // « serious » sont du bridage ordinaire ; seul « critical » rend la main.
        if (thermal >= NSProcessInfoThermalStateCritical) return @"Contrainte thermique critique détectée par macOS.";
    } else if (thermal != NSProcessInfoThermalStateNominal) {
        // Dès « fair », avant les niveaux serious/critical. Ce signal n'est pas une mesure en °C.
        return @"Pression thermique détectée par macOS.";
    }
    if (!constant && now >= deadline) return @"Durée terminée.";
    if (now - heartbeat > 20 || now < heartbeat) return @"Status ne répond plus.";
    return nil;
}
NSString *TMLidStopReason(double battery, NSInteger thermal, double now, double deadline, double heartbeat) {
    return TMLidStopReasonForProfile(battery, thermal, now, deadline, heartbeat, NO, NO);
}
NSDictionary *TMLidParsePowerSettings(NSString *text) {
    if (![text isKindOfClass:NSString.class] || ![text containsString:@"System-wide power settings:"]) return nil;
    NSMutableDictionary *result = [@{@"sleepDisabled":@0} mutableCopy];
    NSString *section = nil;
    for (NSString *raw in [text componentsSeparatedByCharactersInSet:NSCharacterSet.newlineCharacterSet]) {
        NSString *line = [raw stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceCharacterSet];
        if ([line isEqual:@"Battery Power:"]) { section = @"batteryMode"; continue; }
        if ([line isEqual:@"AC Power:"]) { section = @"acMode"; continue; }
        if ([line hasSuffix:@":"]) { section = nil; continue; }
        NSArray *parts = [[line componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceCharacterSet]
            filteredArrayUsingPredicate:[NSPredicate predicateWithFormat:@"length > 0"]];
        if (parts.count < 2) continue;
        NSString *key = parts[0], *value = parts[1];
        if ([key isEqual:@"SleepDisabled"]) {
            if (![@[@"0",@"1"] containsObject:value]) return nil;
            result[@"sleepDisabled"] = @([value integerValue]);
        }
        if (section && [@[@"powermode",@"lowpowermode"] containsObject:key]) {
            if (![@[@"0",@"1",@"2"] containsObject:value]) return nil;
            result[section] = @([value integerValue]);
        }
    }
    return result[@"batteryMode"] && result[@"acMode"] ? result : nil;
}

@implementation TMLidMode {
    id<TMLidBackend> _backend;
    NSDictionary *_journal;
    double _lastHeartbeat;
    BOOL _fanless;
}
- (instancetype)initWithBackend:(id<TMLidBackend>)backend {
    if ((self = [super init])) { _backend = backend; _message = @"Désactivé."; }
    return self;
}
- (BOOL)restorationPending { return _journal != nil; }
- (BOOL)fanlessProfile { return _fanless; }
- (BOOL)validJournal:(NSDictionary *)j {
    return [j isKindOfClass:NSDictionary.class] && [j[@"version"] isEqual:@1] &&
        [j[@"sleepDisabled"] isEqual:@0] && [@[@0,@1,@2] containsObject:j[@"batteryMode"] ?: @-1] &&
        [@[@0,@1,@2] containsObject:j[@"acMode"] ?: @-1] &&
        (!j[@"lowPowerForced"] || [@[@0,@1] containsObject:j[@"lowPowerForced"]]);  // clé absente des anciens journaux
}
- (void)recover {
    NSDictionary *j = [_backend loadJournal];
    if (!j) return;
    _journal = j;
    if (![self validJournal:j]) { _message = @"Journal de restauration invalide ; activation bloquée."; return; }
    [self stop:@"Réglages restaurés après interruption du service."];
}
- (void)startMinutes:(NSInteger)minutes battery:(double)battery thermal:(NSInteger)thermal now:(double)now {
    if (_active || _journal) { _message = @"Une session ou une restauration est déjà en cours."; return; }
    // Le profil dépend de la machine, lue ICI (le service décide, jamais l'app qui le lui demande).
    NSString *model = self.machineModel ?: TMMachineModel();
    BOOL fanless = TMMachineIsFanlessMacBook(model);
    BOOL constant = minutes == TMLidConstantMinutes;
    if (constant && !fanless) { _message = @"Le mode constant est réservé aux MacBook Air (sans ventilateur)."; return; }
    if (!constant && !TMLidDurationAllowed(minutes)) { _message = @"Choisissez une durée entre 1 et 240 minutes."; return; }
    NSString *unsafe = TMLidStopReasonForProfile(battery, thermal, now, constant ? now + 60 : now + minutes * 60, now, fanless, constant);
    if (unsafe) { _message = unsafe; return; }
    NSDictionary *power = [_backend powerSettings];
    if (!power || ![power[@"sleepDisabled"] isEqual:@0]) {
        _message = @"Impossible de lire les réglages, ou veille déjà bloquée par un autre outil."; return;
    }
    // MacBook Air : le mode économie d'énergie n'est pas imposé (sans ventilateur, il n'apporte rien et brident
    // inutilement la machine). Le journal le dit, pour que la restauration — y compris après un crash du service —
    // ne « remette » jamais un mode que Status n'a pas changé.
    BOOL forceLowPower = !fanless;
    NSDictionary *journal = @{@"version":@1, @"sleepDisabled":@0, @"lowPowerForced":@(forceLowPower),
        @"batteryMode":power[@"batteryMode"] ?: @-1, @"acMode":power[@"acMode"] ?: @-1};
    if (![self validJournal:journal] || ![_backend saveJournal:journal]) {
        _message = @"Impossible de sauvegarder les réglages initiaux ; aucun changement appliqué."; return;
    }
    _journal = journal;
    if (forceLowPower) {
        BOOL lowPower = [_backend setPowerMode:1 battery:YES] && [_backend setPowerMode:1 battery:NO];
        NSDictionary *check = [_backend powerSettings];
        if (!lowPower || ![check[@"batteryMode"] isEqual:@1] || ![check[@"acMode"] isEqual:@1]) {
            [self stop:@"Mode faible consommation non confirmé ; activation annulée."]; return;
        }
    }
    if (![_backend setSleepDisabled:YES] || ![[_backend powerSettings][@"sleepDisabled"] isEqual:@1]) {
        [self stop:@"Maintien éveillé non confirmé ; activation annulée."]; return;
    }
    _active = YES; _constant = constant; _fanless = fanless;
    _deadline = constant ? 0 : now + minutes * 60; _lastHeartbeat = now;
    if (fanless) _message = constant ? @"Actif · constant · économie d’énergie non imposée (MacBook Air)."
                                     : @"Actif · économie d’énergie non imposée (MacBook Air).";
    else _message = @"Actif · faible consommation imposée.";
}
- (void)heartbeatAt:(double)now { if (_active) _lastHeartbeat = now; }
- (void)tickBattery:(double)battery thermal:(NSInteger)thermal now:(double)now {
    if (!_active) { if (_journal && [self validJournal:_journal]) [self stop:_message]; return; }
    NSString *reason = TMLidStopReasonForProfile(battery, thermal, now, _deadline, _lastHeartbeat, _fanless, _constant);
    NSDictionary *power = [_backend powerSettings];
    // Un Air n'impose pas la faible consommation : l'utilisateur peut la changer sans que la session s'arrête.
    BOOL lowPowerKept = _fanless || ([power[@"batteryMode"] isEqual:@1] && [power[@"acMode"] isEqual:@1]);
    if (!reason && (!power || ![power[@"sleepDisabled"] isEqual:@1] || !lowPowerKept))
        reason = @"Les réglages d’énergie ont changé ou ne sont plus lisibles.";
    if (reason) [self stop:reason];
}
- (void)stop:(NSString *)reason {
    _active = NO; _deadline = 0; _constant = NO; _fanless = NO;
    _message = reason ?: @"Désactivé.";
    if (!_journal || ![self validJournal:_journal]) return;
    NSDictionary *power = [_backend powerSettings];
    if (!power) { _message = @"Restauration en attente : réglages illisibles."; return; }
    BOOL ok = YES;
    // Les journaux d'avant cette clé ont tous imposé la faible consommation : absent, on restaure comme avant.
    BOOL lowPowerForced = _journal[@"lowPowerForced"] ? [_journal[@"lowPowerForced"] boolValue] : YES;
    // Ne pas écraser un changement effectué entre-temps par l'utilisateur ou un autre outil.
    // Restaurer les modes avant la veille : capot fermé, la machine peut dormir dès le dernier appel.
    if (lowPowerForced && [power[@"batteryMode"] isEqual:@1] && ![_journal[@"batteryMode"] isEqual:@1])
        ok = [_backend setPowerMode:[_journal[@"batteryMode"] integerValue] battery:YES] && ok;
    if (lowPowerForced && [power[@"acMode"] isEqual:@1] && ![_journal[@"acMode"] isEqual:@1])
        ok = [_backend setPowerMode:[_journal[@"acMode"] integerValue] battery:NO] && ok;
    if ([power[@"sleepDisabled"] isEqual:@1]) ok = [_backend setSleepDisabled:NO] && ok;
    NSDictionary *after = [_backend powerSettings];
    if (!after || ![after[@"sleepDisabled"] isEqual:@0]) ok = NO;
    if (lowPowerForced && [power[@"batteryMode"] isEqual:@1] && ![after[@"batteryMode"] isEqual:_journal[@"batteryMode"]]) ok = NO;
    if (lowPowerForced && [power[@"acMode"] isEqual:@1] && ![after[@"acMode"] isEqual:_journal[@"acMode"]]) ok = NO;
    if (ok && [_backend clearJournal]) _journal = nil;
    else _message = @"Restauration en attente ; le service réessaie automatiquement.";
}
@end
