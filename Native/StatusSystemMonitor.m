#import "StatusSystemMonitor.h"

const NSUInteger TMMetricRingCapacity = 300;

#pragma mark - Anneau

@implementation TMMetricRing {
    double *_values;
    NSUInteger _capacity;
    NSUInteger _next;   // prochaine case d'écriture
    NSUInteger _count;  // plafonne à _capacity
}

- (instancetype)initWithCapacity:(NSUInteger)capacity {
    if ((self = [super init])) {
        _capacity = MAX(capacity, 1);
        _values = calloc(_capacity, sizeof(double));
    }
    return self;
}

- (void)dealloc { free(_values); }

- (void)push:(double)value {
    _values[_next] = value;
    _next = (_next + 1) % _capacity;
    if (_count < _capacity) _count++;
}

- (NSUInteger)count { return _count; }

- (NSArray<NSNumber *> *)series {
    NSMutableArray *series = [NSMutableArray arrayWithCapacity:_count];
    // Départ : la case la plus ancienne. Tant que l'anneau n'est pas plein, c'est la case 0 ;
    // ensuite, c'est celle que la prochaine écriture écraserait.
    NSUInteger start = (_count < _capacity) ? 0 : _next;
    for (NSUInteger i = 0; i < _count; i++) {
        [series addObject:@(_values[(start + i) % _capacity])];
    }
    return series;
}

@end

#pragma mark - Deltas

BOOL TMRatePerSecond(uint64_t previous, uint64_t current, NSTimeInterval elapsed, double *outRate) {
    if (elapsed <= 0) return NO;
    if (current < previous) return NO;  // interface réinitialisée ou compteur rebouclé
    if (outRate) *outRate = (double)(current - previous) / elapsed;
    return YES;
}

BOOL TMCPUPercentBetweenTicks(uint64_t activePrevious, uint64_t totalPrevious,
                              uint64_t activeCurrent, uint64_t totalCurrent, double *outPercent) {
    if (totalCurrent <= totalPrevious) return NO;  // pas de temps écoulé, ou compteur qui recule
    if (activeCurrent < activePrevious) return NO;
    double percent = 100.0 * (double)(activeCurrent - activePrevious)
                           / (double)(totalCurrent - totalPrevious);
    // L'arrondi des compteurs noyau peut faire déborder d'un poil ; on borne plutôt qu'afficher 101 %.
    if (outPercent) *outPercent = MIN(MAX(percent, 0.0), 100.0);
    return YES;
}

#pragma mark - Moniteur

@implementation TMSystemMonitor {
    NSDictionary<NSString *, TMMetricCollector> *_collectors;
    NSArray<NSString *> *_familyOrder;
    // famille → (clé → anneau). Les anneaux naissent à la première valeur d'une clé : on ne
    // présume pas des clés qu'un collecteur produira (elles varient selon le matériel).
    NSMutableDictionary<NSString *, NSMutableDictionary<NSString *, TMMetricRing *> *> *_rings;
    // Dernier échantillon par famille — nil si le collecteur vient d'échouer. C'est lui qui
    // décide de la présence de la famille dans le snapshot.
    NSMutableDictionary<NSString *, NSDictionary<NSString *, NSNumber *> *> *_latest;
}

- (instancetype)initWithCollectors:(NSDictionary<NSString *, TMMetricCollector> *)collectors
                       familyOrder:(NSArray<NSString *> *)familyOrder {
    if ((self = [super init])) {
        _collectors = [collectors copy];
        _familyOrder = [familyOrder copy];
        _rings = [NSMutableDictionary dictionary];
        _latest = [NSMutableDictionary dictionary];
    }
    return self;
}

- (void)sample {
    for (NSString *family in _familyOrder) {
        TMMetricCollector collector = _collectors[family];
        NSDictionary<NSString *, NSNumber *> *values = collector ? collector() : nil;
        _latest[family] = values;  // nil efface : la famille disparaît du snapshot
        if (!values) continue;     // pas de zéros inventés pendant une panne
        NSMutableDictionary *familyRings = _rings[family];
        if (!familyRings) _rings[family] = familyRings = [NSMutableDictionary dictionary];
        [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSNumber *value, BOOL *stop) {
            TMMetricRing *ring = familyRings[key];
            if (!ring) familyRings[key] = ring = [[TMMetricRing alloc] initWithCapacity:TMMetricRingCapacity];
            [ring push:value.doubleValue];
        }];
    }
}

- (NSDictionary *)snapshot {
    NSMutableArray *families = [NSMutableArray array];
    for (NSString *family in _familyOrder) {
        NSDictionary<NSString *, NSNumber *> *latest = _latest[family];
        if (!latest) continue;
        NSMutableDictionary *series = [NSMutableDictionary dictionary];
        [_rings[family] enumerateKeysAndObjectsUsingBlock:^(NSString *key, TMMetricRing *ring, BOOL *stop) {
            series[key] = ring.series;
        }];
        [families addObject:@{ @"id": family, @"now": latest, @"series": series }];
    }
    return @{ @"families": families };
}

@end

TMSystemMonitor *TMSystemMonitorCreate(void) {
    // Les collecteurs réels arrivent avec la tâche suivante ; brancher un moniteur vide serait
    // pire que ne rien brancher.
    return nil;
}
