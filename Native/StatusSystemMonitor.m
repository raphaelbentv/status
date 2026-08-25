#import "StatusSystemMonitor.h"
#import <mach/mach.h>
#import <sys/sysctl.h>
#import <sys/mount.h>
#import <ifaddrs.h>
#import <net/if.h>
#import <net/if_types.h>
#import <IOKit/IOKitLib.h>
#import <libproc.h>
#import <mach/mach_time.h>
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <IOKit/storage/IOBlockStorageDriver.h>

// Horloge monotone pour les débits : l'horloge murale peut reculer (NTP), pas celle-ci.
static NSTimeInterval TMMonotonicNow(void) {
    return (NSTimeInterval)clock_gettime_nsec_np(CLOCK_UPTIME_RAW) / 1e9;
}

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

NSArray<NSDictionary *> *TMTopProcesses(NSDictionary *previous, NSDictionary *current,
                                        NSTimeInterval elapsed, NSUInteger count) {
    if (elapsed <= 0) return @[];
    // On mesure d'abord le delta CPU de chaque processus vivant aux deux relevés ; la mémoire est
    // instantanée (pas de delta). Un processus apparu depuis (pas de « before ») n'a pas de delta
    // CPU exploitable, mais sa mémoire l'est : on le garde avec cpuPercent = 0, pour qu'un gros
    // consommateur RAM fraîchement lancé apparaisse quand même au tri par mémoire.
    __block BOOL anyEnergy = NO;
    NSMutableArray *measured = [NSMutableArray array];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *pid, NSDictionary *proc, BOOL *stop) {
        double percent = 0, energyWatts = 0;
        NSDictionary *before = previous[pid];
        if (before) {
            uint64_t cpuBefore = [before[@"cpuTimeNs"] unsignedLongLongValue];
            uint64_t cpuNow = [proc[@"cpuTimeNs"] unsignedLongLongValue];
            if (cpuNow >= cpuBefore)  // sinon pid réutilisé : on laisse cpuPercent à 0
                percent = (double)(cpuNow - cpuBefore) / 1e9 / elapsed * 100.0;
            // Énergie : delta de nanojoules sur l'intervalle → puissance moyenne en watts. Même
            // garde que le CPU contre un compteur qui recule (pid réutilisé).
            uint64_t energyBefore = [before[@"energyNJ"] unsignedLongLongValue];
            uint64_t energyNow = [proc[@"energyNJ"] unsignedLongLongValue];
            if (energyNow >= energyBefore) {
                energyWatts = (double)(energyNow - energyBefore) / 1e9 / elapsed;
                if (energyWatts > 0) anyEnergy = YES;
            }
        }
        [measured addObject:@{ @"pid": pid, @"name": proc[@"name"] ?: @"?",
                               @"cpuPercent": @(percent), @"rssBytes": proc[@"rssBytes"] ?: @0,
                               @"energyWatts": @(energyWatts) }];
    }];

    // Union des `count` plus gros par CPU et des `count` plus gros par RAM, dédupliquée par pid.
    // L'interface trie ensuite selon la dimension choisie ; garder les deux tops garantit qu'un
    // processus dominant l'une des deux ressources est toujours présent, quel que soit le tri.
    NSComparator byCPU = ^(NSDictionary *a, NSDictionary *b) { return [b[@"cpuPercent"] compare:a[@"cpuPercent"]]; };
    NSComparator byRAM = ^(NSDictionary *a, NSDictionary *b) { return [b[@"rssBytes"] compare:a[@"rssBytes"]]; };
    NSComparator byEnergy = ^(NSDictionary *a, NSDictionary *b) { return [b[@"energyWatts"] compare:a[@"energyWatts"]]; };
    NSArray * (^topSlice)(NSComparator) = ^(NSComparator cmp) {
        NSArray *sorted = [measured sortedArrayUsingComparator:cmp];
        return sorted.count > count ? [sorted subarrayWithRange:NSMakeRange(0, count)] : sorted;
    };

    // Union des tranches (CPU, RAM, puis énergie), dédupliquée par pid. La dimension énergie n'est
    // ajoutée que si des deltas non nuls existent : sans données d'énergie, un tri sur des zéros
    // serait arbitraire et gonflerait l'union pour rien. Taille : de `count` à 3×count.
    NSMutableArray *slices = [NSMutableArray arrayWithObjects:topSlice(byCPU), topSlice(byRAM), nil];
    if (anyEnergy) [slices addObject:topSlice(byEnergy)];
    NSMutableArray *union_ = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    for (NSArray *slice in slices)
        for (NSDictionary *proc in slice) {
            if ([seen containsObject:proc[@"pid"]]) continue;
            [seen addObject:proc[@"pid"]];
            [union_ addObject:proc];
        }
    return union_;
}

BOOL TMThresholdShouldFire(BOOL *wasAbove, double value, double threshold, double rearmBelow) {
    if (*wasAbove) {
        if (value < rearmBelow) *wasAbove = NO;
        return NO;
    }
    if (value >= threshold) { *wasAbove = YES; return YES; }
    return NO;
}

const NSTimeInterval TMLongHistoryMaxAge = 24 * 60 * 60;
const NSTimeInterval TMLongHistoryInterval = 60;

NSArray<NSDictionary *> *TMLongHistoryAppend(NSArray<NSDictionary *> *rows, NSDictionary *row,
                                             NSTimeInterval maxAge, NSUInteger maxRows) {
    NSNumber *stamp = [row[@"t"] isKindOfClass:NSNumber.class] ? row[@"t"] : nil;
    if (!stamp) return rows ?: @[];
    NSMutableArray *result = [(rows ?: @[]) mutableCopy];
    // Rejette un point antérieur au dernier connu : l'historique doit rester monotone.
    NSNumber *lastStamp = [result.lastObject[@"t"] isKindOfClass:NSNumber.class] ? result.lastObject[@"t"] : nil;
    if (lastStamp && stamp.doubleValue < lastStamp.doubleValue) return rows ?: @[];
    [result addObject:row];
    // Élagage par âge, relatif à la ligne la plus récente (et non à « maintenant ») : l'appelant
    // peut ainsi rejouer un historique importé sans qu'il s'auto-efface.
    double newest = stamp.doubleValue;
    NSUInteger firstKept = 0;
    while (firstKept < result.count) {
        NSNumber *t = result[firstKept][@"t"];
        if ([t isKindOfClass:NSNumber.class] && newest - t.doubleValue <= maxAge) break;
        firstKept++;
    }
    if (firstKept) [result removeObjectsInRange:NSMakeRange(0, firstKept)];
    if (maxRows && result.count > maxRows) [result removeObjectsInRange:NSMakeRange(0, result.count - maxRows)];
    return result;
}

// Les clés suivies sur 24 h : une par famille, celle qui résume le mieux l'état. Volontairement
// peu nombreuses — l'historique doit rester léger sur disque et en mémoire.
NSDictionary *TMLongHistoryRow(NSDictionary *snapshot, NSTimeInterval timestamp) {
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (NSDictionary *family in snapshot[@"families"]) {
        if ([family[@"id"] isKindOfClass:NSString.class]) byId[family[@"id"]] = family[@"now"];
    }
    NSDictionary *tracked = @{ @"cpu": @[@"cpu", @"total"], @"ram": @[@"ram", @"usedPercent"],
                               @"gpu": @[@"gpu", @"usage"], @"temp": @[@"sensors", @"tempC"],
                               @"disk": @[@"disk", @"usedPercent"], @"batt": @[@"battery", @"percent"],
                               @"rx": @[@"network", @"rxBytesPerSec"], @"tx": @[@"network", @"txBytesPerSec"] };
    NSMutableDictionary *row = [NSMutableDictionary dictionary];
    for (NSString *key in tracked) {
        NSArray *path = tracked[key];
        NSNumber *value = byId[path[0]][path[1]];
        if ([value isKindOfClass:NSNumber.class]) row[key] = value;
    }
    if (!row.count) return nil;  // rien à journaliser : pas de ligne vide horodatée
    row[@"t"] = @(round(timestamp));
    return row;
}

double TMAlertRearmThreshold(double threshold) {
    if (threshold <= 0) return 0;
    double margin = MAX(2.0, threshold * 0.08);
    return MAX(0.0, threshold - margin);
}

NSString *TMSensorFamilyForName(NSString *name) {
    if (!name.length) return nil;
    NSString *lower = name.lowercaseString;
    // La batterie d'abord : « gas gauge battery » ne doit jamais compter comme un capteur SoC.
    if ([lower containsString:@"battery"] || [lower containsString:@"gas gauge"]) return @"battery";
    // « tcal » est un capteur de calibration, pas une mesure de die : exclu explicitement avant
    // le test « tdie », sinon il gonflerait le point chaud (il lit ~10 °C au-dessus).
    if ([lower containsString:@"tcal"]) return nil;
    if ([lower containsString:@"tdie"] || [lower containsString:@"peci"]
        || [lower containsString:@"soc"] || [lower containsString:@"cpu"]) return @"die";
    if ([lower containsString:@"tdev"]) return @"device";
    return nil;
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
        [values enumerateKeysAndObjectsUsingBlock:^(NSString *key, id value, BOOL *stop) {
            // Certaines valeurs sont des métadonnées non chronologiques (ex. cpu.coreTypes, une
            // chaîne « EEEEPP… ») : elles voyagent dans `now` mais n'alimentent aucun anneau.
            if (![value isKindOfClass:NSNumber.class]) return;
            TMMetricRing *ring = familyRings[key];
            if (!ring) familyRings[key] = ring = [[TMMetricRing alloc] initWithCapacity:TMMetricRingCapacity];
            [ring push:((NSNumber *)value).doubleValue];
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

#pragma mark - Collecteurs (lisent la machine — pas de tests unitaires, contrat couvert par snapshot)

// CPU par cœur et global, via host_processor_info. L'état précédent des ticks vit dans le bloc.
typedef struct { uint64_t active, total, user, system; } TMCPUTicks;

// Répartition Efficience/Performance des cœurs, en chaîne « EEEEPP… » de longueur coreCount, ou
// nil si la machine n'expose pas les deux types (Intel). Sur Apple Silicon, hw.perflevel0 =
// Performance, hw.perflevel1 = Efficiency ; les cœurs E occupent les premiers index de
// host_processor_info (vérifié empiriquement), les P ensuite. Calculée une fois puis mémoïsée.
static NSString *TMCPUCoreTypes(natural_t coreCount) {
    static NSString *cached = nil;
    static natural_t cachedCount = 0;
    if (cached && cachedCount == coreCount) return cached;
    int pCores = 0, eCores = 0;
    size_t size = sizeof(int);
    if (sysctlbyname("hw.perflevel0.logicalcpu", &pCores, &size, NULL, 0) != 0) pCores = 0;
    size = sizeof(int);
    if (sysctlbyname("hw.perflevel1.logicalcpu", &eCores, &size, NULL, 0) != 0) eCores = 0;
    if (pCores <= 0 || eCores <= 0 || (natural_t)(pCores + eCores) != coreCount) return nil;
    NSMutableString *types = [NSMutableString stringWithCapacity:coreCount];
    for (natural_t i = 0; i < coreCount; i++) [types appendString:(i < (natural_t)eCores) ? @"E" : @"P"];
    cached = [types copy];
    cachedCount = coreCount;
    return cached;
}

static NSDictionary<NSString *, NSNumber *> *TMCollectCPU(NSMutableData *previousTicks) {
    natural_t coreCount = 0;
    processor_info_array_t info = NULL;
    mach_msg_type_number_t infoCount = 0;
    kern_return_t result = host_processor_info(mach_host_self(), PROCESSOR_CPU_LOAD_INFO,
                                               &coreCount, &info, &infoCount);
    if (result != KERN_SUCCESS || coreCount == 0) return nil;

    BOOL first = previousTicks.length == 0;
    if (first) previousTicks.length = coreCount * sizeof(TMCPUTicks);
    TMCPUTicks *previous = previousTicks.mutableBytes;
    processor_cpu_load_info_t loads = (processor_cpu_load_info_t)info;

    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    double percentSum = 0;
    NSUInteger measured = 0;
    // Découpe user/système agrégée sur toute la machine (deltas cumulés de tous les cœurs).
    uint64_t userDelta = 0, systemDelta = 0, totalDelta = 0;
    for (natural_t core = 0; core < coreCount; core++) {
        uint64_t user = (uint64_t)loads[core].cpu_ticks[CPU_STATE_USER]
                      + (uint64_t)loads[core].cpu_ticks[CPU_STATE_NICE];
        uint64_t system = (uint64_t)loads[core].cpu_ticks[CPU_STATE_SYSTEM];
        uint64_t active = user + system;
        uint64_t total = active + (uint64_t)loads[core].cpu_ticks[CPU_STATE_IDLE];
        double percent;
        if (!first && TMCPUPercentBetweenTicks(previous[core].active, previous[core].total,
                                               active, total, &percent)) {
            values[[NSString stringWithFormat:@"core%u", core]] = @(round(percent));
            percentSum += percent;
            measured++;
            if (total > previous[core].total) {
                userDelta += user - previous[core].user;
                systemDelta += system - previous[core].system;
                totalDelta += total - previous[core].total;
            }
        }
        previous[core] = (TMCPUTicks){ active, total, user, system };
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(natural_t));

    // Premier appel : pas encore de delta. nil plutôt qu'un zéro inventé — la famille apparaît
    // au tick suivant.
    if (!measured) return nil;
    values[@"total"] = @(round(percentSum / measured));
    if (totalDelta > 0) {
        values[@"userPercent"] = @(round(100.0 * (double)userDelta / (double)totalDelta));
        values[@"systemPercent"] = @(round(100.0 * (double)systemDelta / (double)totalDelta));
    }

    // Type de chaque cœur (Efficience vs Performance), chaîne « EEEE PPPP… » sans espace. Calculé
    // une fois : la topologie ne change pas. Ordre vérifié empiriquement sur Apple Silicon — les
    // cœurs Efficience occupent les premiers index de host_processor_info, les Performance
    // ensuite. Omis si la machine n'a pas les deux types (Intel : pas de perflevel) — l'interface
    // retombe alors sur des barres uniformes.
    NSString *coreTypes = TMCPUCoreTypes(coreCount);
    if (coreTypes) values[@"coreTypes"] = coreTypes;
    return values;
}

// RAM : occupation (active + wired + compressée) et niveau de pression mémoire du noyau.
// Répartition façon Moniteur d'activité : mémoire applicative, résidente (wired), compressée,
// fichiers en cache. « Utilisée » = app + résidente + compressée (le cache est réquisitionnable).
static NSDictionary<NSString *, NSNumber *> *TMCollectRAM(void) {
    vm_statistics64_data_t stats;
    mach_msg_type_number_t statsCount = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64,
                          (host_info64_t)&stats, &statsCount) != KERN_SUCCESS) return nil;
    uint64_t totalBytes = 0;
    size_t totalSize = sizeof(totalBytes);
    if (sysctlbyname("hw.memsize", &totalBytes, &totalSize, NULL, 0) != 0 || !totalBytes) return nil;

    uint64_t pageSize = vm_kernel_page_size;
    uint64_t usedBytes = ((uint64_t)stats.active_count + (uint64_t)stats.wire_count
                        + (uint64_t)stats.compressor_page_count) * pageSize;
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObject:
        @(round(100.0 * MIN((double)usedBytes / (double)totalBytes, 1.0))) forKey:@"usedPercent"];

    // Répartition (mêmes définitions que le Moniteur d'activité) :
    //   applicative = pages internes non purgeables    (heap/pile des apps)
    //   résidente   = wired                            (verrouillée par le noyau)
    //   compressée  = compressor_page_count            (RAM récupérée par compression)
    //   cache       = fichiers mappés + purgeable      (réquisitionnable, ne compte pas comme « utilisée »)
    uint64_t wiredBytes = (uint64_t)stats.wire_count * pageSize;
    uint64_t compressedBytes = (uint64_t)stats.compressor_page_count * pageSize;
    uint64_t purgeableBytes = (uint64_t)stats.purgeable_count * pageSize;
    uint64_t externalBytes = (uint64_t)stats.external_page_count * pageSize;
    uint64_t internalBytes = (uint64_t)stats.internal_page_count * pageSize;
    uint64_t appBytes = internalBytes > purgeableBytes ? internalBytes - purgeableBytes : 0;
    uint64_t cachedBytes = externalBytes + purgeableBytes;
    uint64_t freeBytes = (uint64_t)stats.free_count * pageSize;
    values[@"totalBytes"] = @(totalBytes);
    values[@"usedBytes"] = @(appBytes + wiredBytes + compressedBytes);
    values[@"appBytes"] = @(appBytes);
    values[@"wiredBytes"] = @(wiredBytes);
    values[@"compressedBytes"] = @(compressedBytes);
    values[@"cachedBytes"] = @(cachedBytes);
    values[@"freeBytes"] = @(freeBytes);

    // Échange sur disque (swap) — pression mémoire réelle. Public via sysctl.
    struct xsw_usage swap;
    size_t swapSize = sizeof(swap);
    if (sysctlbyname("vm.swapusage", &swap, &swapSize, NULL, 0) == 0) {
        values[@"swapUsedBytes"] = @(swap.xsu_used);
        values[@"swapTotalBytes"] = @(swap.xsu_total);
    }

    // 1 = normale, 2 = avertissement, 4 = critique. Lisible sans privilège ; absent, tant pis.
    int pressureLevel = 0;
    size_t pressureSize = sizeof(pressureLevel);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, NULL, 0) == 0) {
        values[@"pressureLevel"] = @(pressureLevel);
    }
    return values;
}

// GPU : registre IOAccelerator, dictionnaire « PerformanceStatistics ». Non documenté mais stable
// depuis des années — et si une clé disparaît, elle disparaît du snapshot, le reste survit.
//   usage    = Device Utilization %   (charge globale, déjà exposée)
//   renderer = Renderer Utilization % (étage de rendu)
//   tiler    = Tiler Utilization %    (étage de tuilage TBDR)
//   memInUse = In use system memory   (octets alloués réellement en service)
// Le GPU par cœur n'existe pas : aucune API n'expose les cœurs GPU un par un.
static NSDictionary<NSString *, NSNumber *> *TMCollectGPU(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                     &iterator) != KERN_SUCCESS) return nil;
    NSMutableDictionary *values = nil;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef statistics = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"),
                                                               kCFAllocatorDefault, 0);
        if (statistics && CFGetTypeID(statistics) == CFDictionaryGetTypeID()) {
            NSDictionary *performance = (__bridge NSDictionary *)statistics;
            NSNumber *device = performance[@"Device Utilization %"] ?: performance[@"GPU Activity(%)"];
            if ([device isKindOfClass:NSNumber.class]) {
                values = [NSMutableDictionary dictionaryWithObject:@(round(device.doubleValue)) forKey:@"usage"];
                NSNumber *renderer = performance[@"Renderer Utilization %"];
                NSNumber *tiler = performance[@"Tiler Utilization %"];
                NSNumber *mem = performance[@"In use system memory"];
                if ([renderer isKindOfClass:NSNumber.class]) values[@"renderer"] = @(round(renderer.doubleValue));
                if ([tiler isKindOfClass:NSNumber.class]) values[@"tiler"] = @(round(tiler.doubleValue));
                if ([mem isKindOfClass:NSNumber.class]) values[@"memInUse"] = mem;
            }
        }
        if (statistics) CFRelease(statistics);
        IOObjectRelease(service);
        if (values) break;  // un seul GPU sur les machines visées
    }
    IOObjectRelease(iterator);
    return values;
}

// Réseau : total (clés rxBytesPerSec/txBytesPerSec) + par interface active (rx:en0, tx:en0…),
// débit par delta. `state` porte les compteurs précédents par interface, plus l'horodatage.
static const NSUInteger TMNetworkInterfaceCap = 8;  // les anneaux par clé ont un coût : on borne

static NSDictionary<NSString *, NSNumber *> *TMCollectNetwork(NSMutableDictionary *state) {
    struct ifaddrs *interfaces = NULL;
    if (getifaddrs(&interfaces) != 0) return nil;
    NSMutableDictionary<NSString *, NSArray<NSNumber *> *> *totals = [NSMutableDictionary dictionary];
    for (struct ifaddrs *interface = interfaces; interface; interface = interface->ifa_next) {
        if (!interface->ifa_addr || interface->ifa_addr->sa_family != AF_LINK) continue;
        if (interface->ifa_flags & IFF_LOOPBACK) continue;
        if (!(interface->ifa_flags & IFF_UP)) continue;
        const struct if_data *data = interface->ifa_data;
        if (!data || (!data->ifi_ibytes && !data->ifi_obytes)) continue;  // jamais servi : ignoré
        totals[@(interface->ifa_name)] = @[@(data->ifi_ibytes), @(data->ifi_obytes)];
    }
    freeifaddrs(interfaces);

    NSTimeInterval now = TMMonotonicNow();
    NSTimeInterval elapsed = now - [state[@"__at"] doubleValue];
    BOOL first = ![state[@"__at"] doubleValue];
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    double rxTotal = 0, txTotal = 0;
    BOOL anyValid = NO;
    NSUInteger emitted = 0;
    for (NSString *name in [totals.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
        NSArray<NSNumber *> *previous = state[name];
        double rxRate, txRate;
        if (previous
            && TMRatePerSecond(previous[0].unsignedLongLongValue, [totals[name][0] unsignedLongLongValue], elapsed, &rxRate)
            && TMRatePerSecond(previous[1].unsignedLongLongValue, [totals[name][1] unsignedLongLongValue], elapsed, &txRate)) {
            anyValid = YES;
            rxTotal += rxRate; txTotal += txRate;
            if (emitted < TMNetworkInterfaceCap) {
                values[[@"rx:" stringByAppendingString:name]] = @(round(rxRate));
                values[[@"tx:" stringByAppendingString:name]] = @(round(txRate));
                emitted++;
            }
        }
        state[name] = totals[name];
    }
    state[@"__at"] = @(now);
    // Premier appel ou compteurs tous rebouclés : on saute ce point plutôt qu'inventer un pic.
    if (first || !anyValid) return nil;
    values[@"rxBytesPerSec"] = @(round(rxTotal));
    values[@"txBytesPerSec"] = @(round(txTotal));
    // Total cumulé depuis le lancement : intégrale du débit (rate × temps écoulé). Robuste au
    // va-et-vient des interfaces et aux rebouclages de compteurs, contrairement à un simple delta
    // de compteurs absolus. Utile pour « données de la session » façon iStat.
    if (elapsed > 0 && elapsed < 60) {  // borne : un long sommeil ne fabrique pas un faux pic
        double rxAcc = [state[@"__rxAcc"] doubleValue] + rxTotal * elapsed;
        double txAcc = [state[@"__txAcc"] doubleValue] + txTotal * elapsed;
        state[@"__rxAcc"] = @(rxAcc);
        state[@"__txAcc"] = @(txAcc);
        values[@"rxSessionBytes"] = @(round(rxAcc));
        values[@"txSessionBytes"] = @(round(txAcc));
    }
    return values;
}

// Disque : espace du volume racine (statfs) + débits E/S cumulés de tous les pilotes de stockage.
static NSDictionary<NSString *, NSNumber *> *TMCollectDisk(uint64_t *previousRead, uint64_t *previousWrite,
                                                           NSTimeInterval *previousAt) {
    struct statfs volume;
    if (statfs("/", &volume) != 0) return nil;
    uint64_t totalBytes = (uint64_t)volume.f_blocks * volume.f_bsize;
    uint64_t freeBytes = (uint64_t)volume.f_bfree * volume.f_bsize;
    if (!totalBytes) return nil;
    NSMutableDictionary *values = [NSMutableDictionary dictionaryWithObject:
        @(round(100.0 * (double)(totalBytes - freeBytes) / (double)totalBytes)) forKey:@"usedPercent"];
    values[@"totalBytes"] = @(totalBytes);
    values[@"freeBytes"] = @(freeBytes);

    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching(kIOBlockStorageDriverClass),
                                     &iterator) == KERN_SUCCESS) {
        uint64_t read = 0, write = 0;
        io_object_t driver;
        while ((driver = IOIteratorNext(iterator))) {
            CFTypeRef statistics = IORegistryEntryCreateCFProperty(driver, CFSTR(kIOBlockStorageDriverStatisticsKey),
                                                                   kCFAllocatorDefault, 0);
            if (statistics && CFGetTypeID(statistics) == CFDictionaryGetTypeID()) {
                NSDictionary *stats = (__bridge NSDictionary *)statistics;
                read += [stats[@(kIOBlockStorageDriverStatisticsBytesReadKey)] unsignedLongLongValue];
                write += [stats[@(kIOBlockStorageDriverStatisticsBytesWrittenKey)] unsignedLongLongValue];
            }
            if (statistics) CFRelease(statistics);
            IOObjectRelease(driver);
        }
        IOObjectRelease(iterator);

        NSTimeInterval now = TMMonotonicNow();
        double readRate, writeRate;
        if (*previousAt > 0
            && TMRatePerSecond(*previousRead, read, now - *previousAt, &readRate)
            && TMRatePerSecond(*previousWrite, write, now - *previousAt, &writeRate)) {
            values[@"readBytesPerSec"] = @(round(readRate));
            values[@"writeBytesPerSec"] = @(round(writeRate));
        }
        *previousRead = read; *previousWrite = write; *previousAt = now;
    }

    // Par volume monté visible (vol:/, vol:/Volumes/X…) — pour la vue détaillée.
    struct statfs *mounts = NULL;
    int mountCount = getmntinfo(&mounts, MNT_NOWAIT);
    NSUInteger emitted = 0;
    for (int i = 0; i < mountCount && emitted < 8; i++) {
        if (mounts[i].f_flags & MNT_DONTBROWSE) continue;  // volumes système cachés
        uint64_t total = (uint64_t)mounts[i].f_blocks * mounts[i].f_bsize;
        if (!total) continue;
        uint64_t free = (uint64_t)mounts[i].f_bfree * mounts[i].f_bsize;
        NSString *mount = @(mounts[i].f_mntonname);
        values[[@"vol:" stringByAppendingString:mount]] =
            @(round(100.0 * (double)(total - free) / (double)total));
        values[[@"volTotal:" stringByAppendingString:mount]] = @(total);
        values[[@"volFree:" stringByAppendingString:mount]] = @(free);
        emitted++;
    }
    return values;  // l'espace disque reste utile même si les débits manquent ce tick-ci
}

// Uptime, charge moyenne, nombre de processus — tout est public et trivial.
static NSDictionary<NSString *, NSNumber *> *TMCollectSystem(void) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    struct timeval boot;
    size_t bootSize = sizeof(boot);
    if (sysctlbyname("kern.boottime", &boot, &bootSize, NULL, 0) == 0 && boot.tv_sec) {
        values[@"uptimeSec"] = @((long long)([NSDate date].timeIntervalSince1970 - boot.tv_sec));
    }
    double loads[3];
    if (getloadavg(loads, 3) == 3) {
        values[@"load1"] = @(round(loads[0] * 100) / 100);
        values[@"load5"] = @(round(loads[1] * 100) / 100);
        values[@"load15"] = @(round(loads[2] * 100) / 100);
    }
    int processCount = proc_listallpids(NULL, 0);
    if (processCount > 0) values[@"processCount"] = @(processCount);
    return values.count ? values : nil;
}

#pragma mark - Capteurs (température via HID privé, batterie via IOPS public)

// Les capteurs de température Apple Silicon ne sont accessibles que par l'event system HID, via
// des fonctions IOKit non déclarées dans les en-têtes publics. Même famille de compromis que le
// GPU : utilisées par tout l'écosystème open source, à dégradation silencieuse si Apple ferme.
typedef struct __IOHIDEventSystemClient *TMHIDClientRef;
typedef struct __IOHIDServiceClient *TMHIDServiceRef;
typedef struct __IOHIDEvent *TMHIDEventRef;
extern TMHIDClientRef IOHIDEventSystemClientCreate(CFAllocatorRef allocator);
extern int IOHIDEventSystemClientSetMatching(TMHIDClientRef client, CFDictionaryRef matching);
extern CFArrayRef IOHIDEventSystemClientCopyServices(TMHIDClientRef client);
extern TMHIDEventRef IOHIDServiceClientCopyEvent(TMHIDServiceRef service, int64_t type,
                                                 int32_t options, int64_t timestamp);
extern double IOHIDEventGetFloatValue(TMHIDEventRef event, int32_t field);
// Nom matériel du capteur (clé « Product »), pour le regroupement par famille.
extern CFTypeRef _Nullable IOHIDServiceClientCopyProperty(TMHIDServiceRef service, CFStringRef key);
static const int64_t TMHIDEventTypeTemperature = 15;
static const int32_t TMHIDEventFieldTemperature = 15 << 16;

// Lecteur SMC minimal (lecture seule) pour la vitesse des ventilateurs. L'AppleSMC n'a pas d'API
// publique ; ce protocole (sélecteur 2, clés 4 caractères) est celui qu'utilise tout l'écosystème
// open source depuis des années — même compromis que les capteurs HID. Connexion ouverte une fois.
typedef struct {
    uint32_t key;
    struct { uint8_t major, minor, build, reserved; uint16_t release; } vers;
    struct { uint16_t version, length; uint32_t cpuPLimit, gpuPLimit, memPLimit; } pLimitData;
    struct { uint32_t dataSize; uint32_t dataType; uint8_t dataAttributes; } keyInfo;
    uint8_t result, status, data8; uint32_t data32; uint8_t bytes[32];
} TMSMCParam;

static uint32_t TMSMCKey(const char *s) { return (s[0] << 24) | (s[1] << 16) | (s[2] << 8) | s[3]; }

static io_connect_t TMSMCConnection(void) {
    static io_connect_t conn = MACH_PORT_NULL;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        io_service_t service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"));
        if (service) {
            if (IOServiceOpen(service, mach_task_self(), 0, &conn) != KERN_SUCCESS) conn = MACH_PORT_NULL;
            IOObjectRelease(service);
        }
    });
    return conn;
}

// Valeur d'une clé SMC interprétée comme nombre. NAN si absente/illisible. Gère les types flottants
// (« flt ») d'Apple Silicon et le point fixe fpe2 des anciennes machines.
static double TMSMCReadNumber(const char *key) {
    io_connect_t conn = TMSMCConnection();
    if (conn == MACH_PORT_NULL) return NAN;
    TMSMCParam in = {0}, out = {0};
    in.key = TMSMCKey(key); in.data8 = 9;  // lire les métadonnées de la clé
    size_t outSize = sizeof(out);
    if (IOConnectCallStructMethod(conn, 2, &in, sizeof(in), &out, &outSize) != KERN_SUCCESS) return NAN;
    uint32_t size = out.keyInfo.dataSize, type = out.keyInfo.dataType;
    TMSMCParam in2 = {0}, out2 = {0};
    in2.key = TMSMCKey(key); in2.keyInfo.dataSize = size; in2.data8 = 5;  // lire les octets
    outSize = sizeof(out2);
    if (IOConnectCallStructMethod(conn, 2, &in2, sizeof(in2), &out2, &outSize) != KERN_SUCCESS) return NAN;
    if (type == TMSMCKey("flt ") && size == 4) { float f; memcpy(&f, out2.bytes, 4); return f; }
    if (type == TMSMCKey("fpe2") && size == 2) { return ((out2.bytes[0] << 8) | out2.bytes[1]) / 4.0; }
    if (type == TMSMCKey("ui8 ") && size == 1) { return out2.bytes[0]; }
    return NAN;
}

NSDictionary<NSString *, NSNumber *> *TMSensorTempAggregates(NSArray<NSDictionary *> *readings) {
    double dieSum = 0, dieMax = 0, deviceSum = 0, deviceMax = 0, anySum = 0;
    NSUInteger dieCount = 0, deviceCount = 0, anyCount = 0;
    for (NSDictionary *reading in readings) {
        NSNumber *num = [reading[@"celsius"] isKindOfClass:NSNumber.class] ? reading[@"celsius"] : nil;
        if (!num) continue;
        double celsius = num.doubleValue;
        // Filtre de plausibilité : les capteurs fantômes rendent 0 ou des valeurs folles.
        if (!(celsius > 10 && celsius < 120)) continue;
        anySum += celsius; anyCount++;
        NSString *name = [reading[@"name"] isKindOfClass:NSString.class] ? reading[@"name"] : nil;
        NSString *familyName = TMSensorFamilyForName(name);
        if ([familyName isEqualToString:@"die"]) {
            dieSum += celsius; dieCount++; dieMax = MAX(dieMax, celsius);
        } else if ([familyName isEqualToString:@"device"]) {
            deviceSum += celsius; deviceCount++; deviceMax = MAX(deviceMax, celsius);
        }
    }
    if (!anyCount) return nil;
    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    if (dieCount) {
        values[@"dieMaxC"] = @(round(dieMax));
        values[@"dieAvgC"] = @(round(dieSum / dieCount));
        values[@"dieCount"] = @(dieCount);
    }
    if (deviceCount) {
        values[@"deviceMaxC"] = @(round(deviceMax));
        values[@"deviceAvgC"] = @(round(deviceSum / deviceCount));
        values[@"deviceCount"] = @(deviceCount);
    }
    values[@"tempC"] = dieCount ? @(round(dieMax)) : @(round(anySum / anyCount));
    return values;
}

// Lectures thermiques brutes via HID : [{ name, celsius }]. Le client, la liste des services et
// leurs noms (« Product ») sont créés une fois puis conservés : les capteurs d'une machine ne
// changent pas en cours de route, et tout recréer à chaque tick — client, matching, copie des
// services, relecture du nom de chaque capteur — coûtait une rafale d'aller-retours mach vers le
// démon HID chaque seconde, le premier poste CPU du moniteur. Ne reste par tick que la lecture de
// l'événement température de chaque service. Appelé du seul thread du timer (main).
static NSArray<NSDictionary *> * _Nullable TMSensorReadings(void) {
    static TMHIDClientRef client;
    static CFArrayRef services;
    static NSArray<NSString *> *names;  // nom par service, aligné sur `services`
    if (!services) {
        if (!client) {
            client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
            if (!client) return nil;
            // PrimaryUsagePage 0xff00 (AppleVendor), PrimaryUsage 5 : les capteurs thermiques.
            NSDictionary *matching = @{ @"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @5 };
            IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        }
        services = IOHIDEventSystemClientCopyServices(client);
        if (!services) return nil;  // réessayé au tick suivant
        NSMutableArray *collected = [NSMutableArray array];
        for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
            TMHIDServiceRef service = (TMHIDServiceRef)CFArrayGetValueAtIndex(services, i);
            CFTypeRef nameRef = IOHIDServiceClientCopyProperty(service, CFSTR("Product"));
            NSString *name = (nameRef && CFGetTypeID(nameRef) == CFStringGetTypeID())
                           ? [(__bridge NSString *)nameRef copy] : @"";
            if (nameRef) CFRelease(nameRef);
            [collected addObject:name];
        }
        names = collected;
    }
    NSMutableArray *readings = [NSMutableArray array];
    for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
        TMHIDServiceRef service = (TMHIDServiceRef)CFArrayGetValueAtIndex(services, i);
        TMHIDEventRef event = IOHIDServiceClientCopyEvent(service, TMHIDEventTypeTemperature, 0, 0);
        if (!event) continue;  // capteur muet ce tick (arrive après une sortie de veille)
        double celsius = IOHIDEventGetFloatValue(event, TMHIDEventFieldTemperature);
        CFRelease(event);
        [readings addObject:@{ @"name": (NSUInteger)i < names.count ? names[i] : @"",
                               @"celsius": @(celsius) }];
    }
    return readings;
}

static NSDictionary<NSString *, NSNumber *> *TMCollectSensors(void) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];

    // La batterie a sa propre famille (TMCollectBattery) : ici, température, état thermique, ventilateurs.

    // État thermique du système (0 normal … 3 critique) — signale un bridage en cours. Public.
    values[@"thermalState"] = @((int)NSProcessInfo.processInfo.thermalState);

    // Ventilateurs : FNum en donne le nombre, F<i>Ac la vitesse réelle. Absents (Mac fanless) →
    // clés omises, rien de plus.
    double fanCount = TMSMCReadNumber("FNum");
    if (!isnan(fanCount) && fanCount >= 1) {
        NSUInteger count = MIN((NSUInteger)fanCount, 8);
        for (NSUInteger i = 0; i < count; i++) {
            char key[5]; snprintf(key, sizeof(key), "F%luAc", (unsigned long)i);
            double rpm = TMSMCReadNumber(key);
            if (!isnan(rpm) && rpm >= 0) values[[NSString stringWithFormat:@"fan%lu", (unsigned long)i]] = @(round(rpm));
        }
    }

    // Températures — capteurs HID regroupés par famille. Une moyenne de TOUT serait trompeuse :
    // elle mêle la cellule de batterie (~31 °C) aux dies du SoC (~44 °C) et masque le point chaud,
    // qui est précisément la valeur qui gouverne le bridage — d'où l'agrégation par famille de
    // TMSensorTempAggregates (tempC = maximum des dies).
    NSDictionary *aggregates = TMSensorTempAggregates(TMSensorReadings() ?: @[]);
    if (aggregates) [values addEntriesFromDictionary:aggregates];

    return values.count ? values : nil;
}

#pragma mark - Batterie

// Batterie complète. Deux sources publiques/semi-publiques :
//   — IOPSCopyPowerSourcesInfo : état haut niveau (%, branché, temps restant) ;
//   — AppleSmartBattery (registre IOKit) : cycles, capacités mAh, tension, courant, condition,
//     détails du chargeur, température. Clés stables depuis des années, même compromis que le
//     reste du module ; absente sur un Mac de bureau → famille nil, la carte ne s'affiche pas.
// `powerWatts` est signé : négatif en décharge, positif en charge (tension × courant).
static NSDictionary<NSString *, NSNumber *> *TMCollectBattery(void) {
    io_service_t smart = IOServiceGetMatchingService(kIOMainPortDefault,
                                                     IOServiceMatching("AppleSmartBattery"));
    if (!smart) return nil;
    CFMutableDictionaryRef rawProps = NULL;
    if (IORegistryEntryCreateCFProperties(smart, &rawProps, kCFAllocatorDefault, 0) != KERN_SUCCESS) {
        IOObjectRelease(smart);
        return nil;
    }
    NSDictionary *props = CFBridgingRelease(rawProps);
    IOObjectRelease(smart);

    NSMutableDictionary *values = [NSMutableDictionary dictionary];
    NSNumber *(^num)(id) = ^NSNumber *(id v) { return [v isKindOfClass:NSNumber.class] ? v : nil; };

    // Charge : CurrentCapacity/MaxCapacity sont en pourcentage sur macOS moderne.
    NSNumber *current = num(props[@"CurrentCapacity"]);
    NSNumber *maxPct = num(props[@"MaxCapacity"]);
    if (current) {
        double pct = (maxPct.doubleValue > 0 && maxPct.doubleValue != 100)
                   ? 100.0 * current.doubleValue / maxPct.doubleValue : current.doubleValue;
        values[@"percent"] = @(round(MIN(MAX(pct, 0), 100)));
    }
    values[@"charging"] = @([num(props[@"IsCharging"]) boolValue]);
    values[@"externalConnected"] = @([num(props[@"ExternalConnected"]) boolValue]);
    values[@"fullyCharged"] = @([num(props[@"FullyCharged"]) boolValue]);
    if (num(props[@"CycleCount"])) values[@"cycleCount"] = num(props[@"CycleCount"]);

    // Tension (mV) et courant (mA, signé) → puissance en watts. InstantAmperage préféré, plus vif.
    NSNumber *voltage = num(props[@"Voltage"]);
    NSNumber *amperage = num(props[@"InstantAmperage"]) ?: num(props[@"Amperage"]);
    if (voltage && amperage) {
        // Amperage est un entier signé 64 bits ; au-delà de 2^32 il code un négatif (décharge).
        long long amp = amperage.longLongValue;
        double watts = (voltage.doubleValue / 1000.0) * (amp / 1000.0);
        values[@"powerWatts"] = @(round(watts * 10) / 10.0);
    }
    if (voltage) values[@"voltageV"] = @(round(voltage.doubleValue / 100.0) / 10.0);

    // Santé : capacité de charge pleine actuelle / capacité de conception, en mAh réels. Piège
    // vérifié sur la machine : la clé « MaxCapacity » vaut 100 (un pourcentage, pas des mAh) ; les
    // vraies capacités sont dans BatteryData (DesignCapacity ≈ 6249, NominalChargeCapacity ≈ 5723).
    // Garde-fou : n'accepter que des valeurs « grandes » (> 1000), sinon on tomberait sur le 100
    // trompeur. Omis si indisponible — pas de chiffre inventé.
    NSDictionary *batteryData = [props[@"BatteryData"] isKindOfClass:NSDictionary.class] ? props[@"BatteryData"] : nil;
    NSNumber *designCap = num(props[@"DesignCapacity"]) ?: num(batteryData[@"DesignCapacity"]);
    NSNumber *fullCap = num(props[@"AppleRawMaxCapacity"]) ?: num(props[@"NominalChargeCapacity"]) ?: num(batteryData[@"NominalChargeCapacity"]);
    if (designCap.doubleValue > 1000 && fullCap.doubleValue > 1000) {
        values[@"healthPercent"] = @(round(MIN(100.0, 100.0 * fullCap.doubleValue / designCap.doubleValue)));
        values[@"designCapacity"] = @(designCap.integerValue);   // mAh de conception
        values[@"fullCapacity"] = @(fullCap.integerValue);       // mAh à pleine charge aujourd'hui
    }

    // Condition : « Normal » vs besoin de révision. PermanentFailureStatus non nul = défaut.
    NSNumber *failure = num(props[@"PermanentFailureStatus"]);
    values[@"conditionOK"] = @(failure ? failure.intValue == 0 : YES);

    // Température batterie : centi-Kelvin ou centi-°C selon la source. La clé « Temperature » de
    // l'AppleSmartBattery est en centi-°C (ex. 3012 = 30,12 °C).
    NSNumber *temp = num(props[@"Temperature"]) ?: num(batteryData[@"Temperature"]);
    if (temp.doubleValue > 0) values[@"temperatureC"] = @(round(temp.doubleValue / 100.0));

    // Chargeur : puissance nominale de l'adaptateur branché.
    NSDictionary *adapter = [props[@"AdapterDetails"] isKindOfClass:NSDictionary.class] ? props[@"AdapterDetails"] : nil;
    NSNumber *adapterWatts = num(adapter[@"Watts"]);
    if (adapterWatts.doubleValue > 0) values[@"adapterWatts"] = adapterWatts;

    // Temps restant (minutes) : vers le vide en décharge, vers le plein en charge. 65535 = inconnu
    // (juste après un changement d'état) — écarté plutôt qu'affiché comme une durée absurde.
    NSNumber *toEmpty = num(props[@"AvgTimeToEmpty"]);
    NSNumber *toFull = num(props[@"AvgTimeToFull"]);
    NSNumber *chosen = [values[@"charging"] boolValue] ? toFull : toEmpty;
    if (chosen && chosen.intValue > 0 && chosen.intValue != 65535) values[@"minutesRemaining"] = chosen;

    return values.count ? values : nil;
}

#pragma mark - Processus

NSDictionary *TMMetricsDeltaPayload(NSDictionary *payload) {
    NSMutableDictionary *delta = [payload mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *families = [NSMutableArray array];
    for (NSDictionary *family in payload[@"families"]) {
        if (![family isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *slim = [family mutableCopy];
        [slim removeObjectForKey:@"series"];
        [families addObject:slim];
    }
    delta[@"families"] = families;
    delta[@"delta"] = @YES;
    return delta;
}

NSDictionary *TMProcessSample(void) {
    // ri_user_time/ri_system_time sont en unités mach_absolute_time, pas en nanosecondes —
    // identiques sur Intel (1/1), différentes sur Apple Silicon. Conversion obligatoire.
    static mach_timebase_info_data_t timebase;
    if (!timebase.denom) mach_timebase_info(&timebase);

    int capacity = proc_listallpids(NULL, 0);
    if (capacity <= 0) return nil;
    capacity += 16;  // des processus naissent entre les deux appels
    pid_t *pids = calloc(capacity, sizeof(pid_t));
    int filled = proc_listallpids(pids, capacity * (int)sizeof(pid_t));
    NSMutableDictionary *sample = [NSMutableDictionary dictionaryWithCapacity:filled];
    for (int i = 0; i < filled; i++) {
        if (!pids[i]) continue;
        // V6 (et non V2) pour ri_energy_nj : l'énergie attribuée au processus, cumulée depuis son
        // lancement — la base de l'« impact énergétique » d'Activity Monitor. Même accès que V2 :
        // un processus qu'on n'a pas le droit de lire (root) est sauté, comme avant.
        struct rusage_info_v6 usage;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V6, (rusage_info_t *)&usage) != 0) continue;
        char name[2 * MAXCOMLEN];
        if (proc_name(pids[i], name, sizeof(name)) <= 0) continue;
        uint64_t cpuNs = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom;
        sample[[@(pids[i]) stringValue]] = @{ @"name": @(name), @"cpuTimeNs": @(cpuNs),
                                              @"rssBytes": @(usage.ri_phys_footprint),
                                              @"energyNJ": @(usage.ri_energy_nj) };
    }
    free(pids);
    return sample.count ? sample : nil;
}

#pragma mark - Assemblage

TMSystemMonitor *TMSystemMonitorCreate(void) {
    // L'état inter-échantillons de chaque collecteur vit dans les captures des blocs.
    NSMutableData *cpuTicks = [NSMutableData data];
    NSMutableDictionary *networkState = [NSMutableDictionary dictionary];
    __block uint64_t diskRead = 0, diskWrite = 0;
    __block NSTimeInterval diskAt = 0;

    return [[TMSystemMonitor alloc] initWithCollectors:@{
        @"cpu":     ^{ return TMCollectCPU(cpuTicks); },
        @"gpu":     ^{ return TMCollectGPU(); },
        @"ram":     ^{ return TMCollectRAM(); },
        @"network": ^{ return TMCollectNetwork(networkState); },
        @"disk":    ^{ return TMCollectDisk(&diskRead, &diskWrite, &diskAt); },
        @"battery": ^{ return TMCollectBattery(); },
        @"sensors": ^{ return TMCollectSensors(); },
        @"system":  ^{ return TMCollectSystem(); },
    } familyOrder:@[@"cpu", @"gpu", @"ram", @"network", @"disk", @"battery", @"sensors", @"system"]];
}
