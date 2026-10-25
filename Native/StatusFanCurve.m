#import "StatusFanCurve.h"
#import <math.h>

NSArray<NSString *> *TMFanCurvePresetIds(void) { return @[@"silent", @"balanced", @"performance"]; }

// Le premier point est le « zéro » de la courbe : en dessous, macOS pilote seul. Chaque préréglage
// atteint 100 % avant le seuil critique de 95 °C.
NSArray<NSArray<NSNumber *> *> *TMFanCurvePoints(NSString *preset) {
    static NSDictionary *presets;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        presets = @{
            @"silent":      @[@[@60, @50], @[@70, @60], @[@80, @75], @[@90, @100]],
            @"balanced":    @[@[@55, @50], @[@65, @60], @[@75, @80], @[@85, @100]],
            @"performance": @[@[@50, @60], @[@60, @75], @[@70, @90], @[@80, @100]],
        };
    });
    return [preset isKindOfClass:NSString.class] ? presets[preset] : nil;
}

double TMFanCurveValue(NSArray<NSArray<NSNumber *> *> *points, double tempC) {
    if (!points.count || !isfinite(tempC)) return NAN;
    if (tempC < [points[0][0] doubleValue]) return NAN;
    double value = [points.lastObject[1] doubleValue];
    for (NSUInteger i = 1; i < points.count; i++) {
        double t0 = [points[i - 1][0] doubleValue], t1 = [points[i][0] doubleValue];
        if (tempC > t1) continue;
        double p0 = [points[i - 1][1] doubleValue], p1 = [points[i][1] doubleValue];
        value = t1 > t0 ? p0 + (p1 - p0) * (tempC - t0) / (t1 - t0) : p1;
        break;
    }
    if (points.count == 1) value = [points[0][1] doubleValue];
    return MIN(100.0, MAX((double)TMFanCurveFloor, value));
}

@implementation TMFanCurve {
    NSArray<NSArray<NSNumber *> *> *_points;
    double _firstStep, _lastValid, _lastChange;
}
- (instancetype)initWithPreset:(NSString *)preset {
    NSArray *points = TMFanCurvePoints(preset);
    if (!points || !(self = [super init])) return nil;
    _preset = [preset copy]; _points = points;
    _firstStep = _lastValid = _lastChange = NAN; _raw = NAN;
    _reason = TMFanCurveReasonIdle;
    return self;
}
- (NSInteger)stepAt:(double)now tempC:(double)tempC thermal:(NSInteger)thermal {
    if (isnan(_firstStep)) _firstStep = now;
    if (_reason == TMFanCurveReasonSensorLost) return 0;  // définitif : le contrôleur repasse en auto
    if (!isfinite(tempC) || tempC <= 0) {
        // Capteur muet : on garde le palier un court instant (un relevé manqué n'est pas une panne),
        // puis on abandonne. Jamais de palier tenu « à l'aveugle ».
        if (now - (isnan(_lastValid) ? _firstStep : _lastValid) > TMFanCurveSensorTimeout) {
            _reason = TMFanCurveReasonSensorLost; _target = 0; _raw = NAN;
            return 0;
        }
        // L'état thermique de macOS reste lisible sans capteur : il suffit à forcer 100 %.
        if (thermal >= TMFanCurveCriticalThermal) {
            if (_target != 100) { _target = 100; _lastChange = now; }
            _reason = TMFanCurveReasonCritical;
        }
        return _target;
    }
    _lastValid = now;
    _raw = TMFanCurveValue(_points, tempC);
    // Seuil critique : 100 % tout de suite, sans attendre l'hystérésis.
    if (tempC >= TMFanCurveCriticalC || thermal >= TMFanCurveCriticalThermal) {
        if (_target != 100) { _target = 100; _lastChange = now; }
        _reason = TMFanCurveReasonCritical;
        return _target;
    }
    double first = [_points[0][0] doubleValue];
    NSInteger candidate;
    if (_target == 0) candidate = tempC >= first ? lround(_raw) : 0;           // reprise au premier point
    else if (tempC < first - TMFanCurveIdleBandC) candidate = 0;               // zéro : macOS reprend
    else candidate = isfinite(_raw) ? lround(_raw) : TMFanCurveFloor;          // bande d'hystérésis
    if (candidate != _target) {
        BOOL rested = isnan(_lastChange) || now - _lastChange >= TMFanCurveMinInterval;
        // Entrée/sortie du zéro et extrêmes (plancher, 100 %) toujours atteignables : sinon un palier
        // à 97 % ne rejoindrait jamais 100 % (écart < 5 points).
        BOOL big = candidate == 0 || _target == 0 || candidate == 100 || candidate == TMFanCurveFloor
            || labs(candidate - _target) >= TMFanCurveStepPoints;
        if (rested && big) { _target = candidate; _lastChange = now; }
    }
    _reason = _target == 0 ? TMFanCurveReasonIdle : TMFanCurveReasonCurve;
    return _target;
}
@end

// Phases du mode manuel : à lancer, lancé (réponse attendue), en cours.
typedef NS_ENUM(NSInteger, TMFanManualPhase) { TMFanManualNeedStart, TMFanManualStarted, TMFanManualRunning };

@implementation TMFanController {
    TMFanManualPhase _phase;
    BOOL _startSent, _stopSent, _sawActive;
    // Chaque changement de mode ouvre une génération : l'issue d'un démarrage lancé par l'ancien
    // mode (réussite ou refus) ne doit pas être imputée au nouveau.
    NSUInteger _generation, _startGeneration;
    double _lastCommand, _nextStartAt;
    NSMutableArray<NSNumber *> *_failures;
}
- (instancetype)init {
    if ((self = [super init])) {
        _mode = @"auto"; _preset = @"balanced"; _manualPercent = 100; _manualMinutes = 15;
        _lastCommand = -INFINITY; _nextStartAt = -INFINITY; _failures = [NSMutableArray new];
    }
    return self;
}
- (BOOL)idle { return [_mode isEqualToString:@"auto"] && !_sawActive && !_startSent && !_stopSent; }
- (BOOL)setMode:(NSString *)mode preset:(NSString *)preset percent:(NSInteger)percent minutes:(NSInteger)minutes {
    if (![mode isKindOfClass:NSString.class]) return NO;
    if ([mode isEqualToString:@"auto"]) { [self forceAuto:nil]; return YES; }
    if ([mode isEqualToString:@"curve"]) {
        TMFanCurve *curve = [[TMFanCurve alloc] initWithPreset:preset ?: _preset];
        if (!curve) return NO;
        _preset = curve.preset; _curve = curve;
    } else if ([mode isEqualToString:@"manual"]) {
        if (percent < TMFanCurveFloor || percent > 100 || minutes < 1 || minutes > 60) return NO;
        _manualPercent = percent; _manualMinutes = minutes; _curve = nil;
    } else return NO;
    // Changement de mode (ou de réglage) : l'ancien boost est arrêté proprement avant le nouveau
    // (phase « à lancer » + boost actif ⇒ Stop d'abord, voir nextCommand).
    _mode = [mode copy]; _phase = TMFanManualNeedStart; _notice = nil; _generation++;
    _nextStartAt = -INFINITY; [_failures removeAllObjects];
    return YES;
}
- (void)forceAuto:(NSString *)notice {
    _mode = @"auto"; _curve = nil; _phase = TMFanManualNeedStart; _notice = [notice copy]; _generation++;
}
- (void)sensorAt:(double)now tempC:(double)tempC thermal:(NSInteger)thermal {
    if (!_curve) return;
    [_curve stepAt:now tempC:tempC thermal:thermal];
    if (_curve.reason == TMFanCurveReasonSensorLost) [self forceAuto:@"sensor"];
}
- (NSInteger)desiredPercent {
    if ([_mode isEqualToString:@"manual"]) return _manualPercent;
    if ([_mode isEqualToString:@"curve"]) return _curve.target;
    return 0;
}
// Démarrages refusés et fins inattendues : trois en cinq minutes, et la courbe abandonne. Sans ce
// plafond, un Mac dont macOS reprend la main toutes les 20 s ferait boucler arrêt/relance.
- (void)failureAt:(double)now {
    [_failures addObject:@(now)];
    [_failures filterUsingPredicate:[NSPredicate predicateWithBlock:^BOOL(NSNumber *t, NSDictionary *b) { return now - t.doubleValue < 300; }]];
    if (_failures.count >= 3) [self forceAuto:@"failed"];
    else _nextStartAt = now + 10;
}
- (TMFanCommand)stopAt:(double)now {
    _stopSent = YES; _lastCommand = now;
    return (TMFanCommand){TMFanCommandStop, 0, 0};
}
- (TMFanCommand)nextCommand:(TMFanServiceView)s now:(double)now {
    const TMFanCommand none = {TMFanCommandNone, 0, 0};
    BOOL manual = [_mode isEqualToString:@"manual"], curve = [_mode isEqualToString:@"curve"];
    // Service perdu (non autorisé, ancien protocole, état non confirmé) : on ne force plus rien.
    // Le service rend lui-même la main sur rupture XPC ou sans battement de cœur (20 s).
    if ((manual || curve) && !s.ok) { [self forceAuto:@"service"]; manual = curve = NO; }
    if (s.busy) return none;  // réponse en attente : le client refuserait toute autre requête
    // Issue de la dernière commande, ou fin d'un boost que nous n'avons pas demandée.
    if (_startSent) {
        _startSent = NO;
        if (_startGeneration != _generation) {}  // lancé par l'ancien mode : simple observation
        else if (s.active) { if (manual) _phase = TMFanManualRunning; }
        else if (manual) { [self forceAuto:@"refused"]; manual = NO; }
        else if (curve) { [self failureAt:now]; curve = [_mode isEqualToString:@"curve"]; }
    } else if (_sawActive && !s.active && !_stopSent) {
        // Échéance, garde-fou du service (Mac chaud, vitesse non confirmée, reprise par macOS)…
        if (manual) { if (_phase == TMFanManualRunning) { [self forceAuto:@"ended"]; manual = NO; } }
        else if (curve) { [self failureAt:now]; curve = [_mode isEqualToString:@"curve"]; }
    }
    _sawActive = s.active;
    if (!s.active) _stopSent = NO;
    if (s.restorationPending) return none;      // le service vérifie son retour à Auto Apple
    if (now - _lastCommand < 2) return none;    // jamais plus d'une commande toutes les 2 s
    NSInteger want = [self desiredPercent];
    if (want <= 0) return s.active ? [self stopAt:now] : none;
    if (!s.active) {
        if (manual && _phase != TMFanManualNeedStart) return none;
        if (now < _nextStartAt) return none;
        _startSent = YES; _startGeneration = _generation; _lastCommand = now;
        if (manual) _phase = TMFanManualStarted;
        // GARDE-FOU PRINCIPAL de la courbe : bail court (2 min) renouvelé. Si Status plante, se
        // fige ou se ferme, plus personne ne renouvelle et le service rend la main à macOS à
        // l'échéance (≤ 2 min), en plus de ses propres garde-fous (rupture XPC, 20 s sans battement).
        return (TMFanCommand){TMFanCommandStart, manual ? _manualMinutes : TMFanLeaseMinutes, want};
    }
    if (manual) return _phase == TMFanManualNeedStart ? [self stopAt:now] : none;
    // Courbe : le service refuse de relancer un boost actif. Nouveau palier ou bail bientôt échu
    // ⇒ arrêt, puis relance au tick suivant.
    if (s.percent != want || s.remainingSeconds <= TMFanLeaseRenewSeconds) return [self stopAt:now];
    return none;
}
@end
