#import "StatusLidMode.h"
#import <math.h>

BOOL TMLidDurationAllowed(NSInteger minutes) { return minutes >= 1 && minutes <= 240; }
NSString *TMLidStopReason(double battery, NSInteger thermal, double now, double deadline, double heartbeat) {
    if (!isfinite(battery) || battery < 0 || battery > 100) return @"Niveau de batterie indisponible.";
    if (battery <= 30) return @"Batterie à 30 % ou moins.";
    // Dès « fair », avant les niveaux serious/critical. Ce signal n'est pas une mesure en °C.
    if (thermal != NSProcessInfoThermalStateNominal) return @"Pression thermique détectée par macOS.";
    if (now >= deadline) return @"Durée terminée.";
    if (now - heartbeat > 20 || now < heartbeat) return @"Status ne répond plus.";
    return nil;
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
}
- (instancetype)initWithBackend:(id<TMLidBackend>)backend {
    if ((self = [super init])) { _backend = backend; _message = @"Désactivé."; }
    return self;
}
- (BOOL)restorationPending { return _journal != nil; }
- (BOOL)validJournal:(NSDictionary *)j {
    return [j isKindOfClass:NSDictionary.class] && [j[@"version"] isEqual:@1] &&
        [j[@"sleepDisabled"] isEqual:@0] && [@[@0,@1,@2] containsObject:j[@"batteryMode"] ?: @-1] &&
        [@[@0,@1,@2] containsObject:j[@"acMode"] ?: @-1];
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
    if (!TMLidDurationAllowed(minutes)) { _message = @"Choisissez une durée entre 1 et 240 minutes."; return; }
    NSString *unsafe = TMLidStopReason(battery, thermal, now, now + minutes * 60, now);
    if (unsafe) { _message = unsafe; return; }
    NSDictionary *power = [_backend powerSettings];
    if (!power || ![power[@"sleepDisabled"] isEqual:@0]) {
        _message = @"Impossible de lire les réglages, ou veille déjà bloquée par un autre outil."; return;
    }
    NSDictionary *journal = @{@"version":@1, @"sleepDisabled":@0,
        @"batteryMode":power[@"batteryMode"] ?: @-1, @"acMode":power[@"acMode"] ?: @-1};
    if (![self validJournal:journal] || ![_backend saveJournal:journal]) {
        _message = @"Impossible de sauvegarder les réglages initiaux ; aucun changement appliqué."; return;
    }
    _journal = journal;
    BOOL lowPower = [_backend setPowerMode:1 battery:YES] && [_backend setPowerMode:1 battery:NO];
    NSDictionary *check = [_backend powerSettings];
    if (!lowPower || ![check[@"batteryMode"] isEqual:@1] || ![check[@"acMode"] isEqual:@1]) {
        [self stop:@"Mode faible consommation non confirmé ; activation annulée."]; return;
    }
    if (![_backend setSleepDisabled:YES] || ![[_backend powerSettings][@"sleepDisabled"] isEqual:@1]) {
        [self stop:@"Maintien éveillé non confirmé ; activation annulée."]; return;
    }
    _active = YES; _deadline = now + minutes * 60; _lastHeartbeat = now;
    _message = @"Actif · faible consommation imposée.";
}
- (void)heartbeatAt:(double)now { if (_active) _lastHeartbeat = now; }
- (void)tickBattery:(double)battery thermal:(NSInteger)thermal now:(double)now {
    if (!_active) { if (_journal && [self validJournal:_journal]) [self stop:_message]; return; }
    NSString *reason = TMLidStopReason(battery, thermal, now, _deadline, _lastHeartbeat);
    NSDictionary *power = [_backend powerSettings];
    if (!reason && (!power || ![power[@"sleepDisabled"] isEqual:@1] ||
        ![power[@"batteryMode"] isEqual:@1] || ![power[@"acMode"] isEqual:@1]))
        reason = @"Les réglages d’énergie ont changé ou ne sont plus lisibles.";
    if (reason) [self stop:reason];
}
- (void)stop:(NSString *)reason {
    _active = NO; _deadline = 0;
    _message = reason ?: @"Désactivé.";
    if (!_journal || ![self validJournal:_journal]) return;
    NSDictionary *power = [_backend powerSettings];
    if (!power) { _message = @"Restauration en attente : réglages illisibles."; return; }
    BOOL ok = YES;
    // Ne pas écraser un changement effectué entre-temps par l'utilisateur ou un autre outil.
    // Restaurer les modes avant la veille : capot fermé, la machine peut dormir dès le dernier appel.
    if ([power[@"batteryMode"] isEqual:@1] && ![_journal[@"batteryMode"] isEqual:@1])
        ok = [_backend setPowerMode:[_journal[@"batteryMode"] integerValue] battery:YES] && ok;
    if ([power[@"acMode"] isEqual:@1] && ![_journal[@"acMode"] isEqual:@1])
        ok = [_backend setPowerMode:[_journal[@"acMode"] integerValue] battery:NO] && ok;
    if ([power[@"sleepDisabled"] isEqual:@1]) ok = [_backend setSleepDisabled:NO] && ok;
    NSDictionary *after = [_backend powerSettings];
    if (!after || ![after[@"sleepDisabled"] isEqual:@0]) ok = NO;
    if ([power[@"batteryMode"] isEqual:@1] && ![after[@"batteryMode"] isEqual:_journal[@"batteryMode"]]) ok = NO;
    if ([power[@"acMode"] isEqual:@1] && ![after[@"acMode"] isEqual:_journal[@"acMode"]]) ok = NO;
    if (ok && [_backend clearJournal]) _journal = nil;
    else _message = @"Restauration en attente ; le service réessaie automatiquement.";
}
@end
