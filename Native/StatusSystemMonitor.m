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
    NSMutableArray *measured = [NSMutableArray array];
    [current enumerateKeysAndObjectsUsingBlock:^(NSString *pid, NSDictionary *proc, BOOL *stop) {
        NSDictionary *before = previous[pid];
        if (!before) return;  // apparu depuis le dernier relevé : pas de delta possible
        uint64_t cpuBefore = [before[@"cpuTimeNs"] unsignedLongLongValue];
        uint64_t cpuNow = [proc[@"cpuTimeNs"] unsignedLongLongValue];
        if (cpuNow < cpuBefore) return;  // pid réutilisé par un autre processus
        double percent = (double)(cpuNow - cpuBefore) / 1e9 / elapsed * 100.0;
        [measured addObject:@{ @"pid": pid, @"name": proc[@"name"] ?: @"?",
                               @"cpuPercent": @(percent), @"rssBytes": proc[@"rssBytes"] ?: @0 }];
    }];
    [measured sortUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [b[@"cpuPercent"] compare:a[@"cpuPercent"]];
    }];
    return measured.count > count ? [measured subarrayWithRange:NSMakeRange(0, count)] : measured;
}

BOOL TMThresholdShouldFire(BOOL *wasAbove, double value, double threshold, double rearmBelow) {
    if (*wasAbove) {
        if (value < rearmBelow) *wasAbove = NO;
        return NO;
    }
    if (value >= threshold) { *wasAbove = YES; return YES; }
    return NO;
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

#pragma mark - Collecteurs (lisent la machine — pas de tests unitaires, contrat couvert par snapshot)

// CPU par cœur et global, via host_processor_info. L'état précédent des ticks vit dans le bloc.
typedef struct { uint64_t active, total; } TMCPUTicks;

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
    for (natural_t core = 0; core < coreCount; core++) {
        uint64_t active = (uint64_t)loads[core].cpu_ticks[CPU_STATE_USER]
                        + (uint64_t)loads[core].cpu_ticks[CPU_STATE_SYSTEM]
                        + (uint64_t)loads[core].cpu_ticks[CPU_STATE_NICE];
        uint64_t total = active + (uint64_t)loads[core].cpu_ticks[CPU_STATE_IDLE];
        double percent;
        if (!first && TMCPUPercentBetweenTicks(previous[core].active, previous[core].total,
                                               active, total, &percent)) {
            values[[NSString stringWithFormat:@"core%u", core]] = @(round(percent));
            percentSum += percent;
            measured++;
        }
        previous[core] = (TMCPUTicks){ active, total };
    }
    vm_deallocate(mach_task_self(), (vm_address_t)info, infoCount * sizeof(natural_t));

    // Premier appel : pas encore de delta. nil plutôt qu'un zéro inventé — la famille apparaît
    // au tick suivant.
    if (!measured) return nil;
    values[@"total"] = @(round(percentSum / measured));
    return values;
}

// RAM : occupation (active + wired + compressée) et niveau de pression mémoire du noyau.
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

    // 1 = normale, 2 = avertissement, 4 = critique. Lisible sans privilège ; absent, tant pis.
    int pressureLevel = 0;
    size_t pressureSize = sizeof(pressureLevel);
    if (sysctlbyname("kern.memorystatus_vm_pressure_level", &pressureLevel, &pressureSize, NULL, 0) == 0) {
        values[@"pressureLevel"] = @(pressureLevel);
    }
    return values;
}

// GPU : « Device Utilization % » du registre IOAccelerator. Non documenté mais stable depuis des
// années — et si la clé disparaît, la famille disparaît avec, par construction.
static NSDictionary<NSString *, NSNumber *> *TMCollectGPU(void) {
    io_iterator_t iterator = IO_OBJECT_NULL;
    if (IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOAccelerator"),
                                     &iterator) != KERN_SUCCESS) return nil;
    NSNumber *usage = nil;
    io_object_t service;
    while ((service = IOIteratorNext(iterator))) {
        CFTypeRef statistics = IORegistryEntryCreateCFProperty(service, CFSTR("PerformanceStatistics"),
                                                               kCFAllocatorDefault, 0);
        if (statistics && CFGetTypeID(statistics) == CFDictionaryGetTypeID()) {
            NSDictionary *performance = (__bridge NSDictionary *)statistics;
            NSNumber *device = performance[@"Device Utilization %"] ?: performance[@"GPU Activity(%)"];
            if ([device isKindOfClass:NSNumber.class]) usage = device;
        }
        if (statistics) CFRelease(statistics);
        IOObjectRelease(service);
        if (usage) break;  // un seul GPU sur les machines visées
    }
    IOObjectRelease(iterator);
    return usage ? @{ @"usage": @(round(usage.doubleValue)) } : nil;
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
        values[[@"vol:" stringByAppendingString:@(mounts[i].f_mntonname)]] =
            @(round(100.0 * (double)(total - free) / (double)total));
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
static const int64_t TMHIDEventTypeTemperature = 15;
static const int32_t TMHIDEventFieldTemperature = 15 << 16;

static NSDictionary<NSString *, NSNumber *> *TMCollectSensors(void) {
    NSMutableDictionary *values = [NSMutableDictionary dictionary];

    // Batterie — public, fiable. Absente sur un Mac de bureau : la clé manque, rien de plus.
    CFTypeRef powerInfo = IOPSCopyPowerSourcesInfo();
    if (powerInfo) {
        CFArrayRef sources = IOPSCopyPowerSourcesList(powerInfo);
        if (sources) {
            for (CFIndex i = 0; i < CFArrayGetCount(sources); i++) {
                NSDictionary *description = (__bridge NSDictionary *)
                    IOPSGetPowerSourceDescription(powerInfo, CFArrayGetValueAtIndex(sources, i));
                NSNumber *current = description[@kIOPSCurrentCapacityKey];
                NSNumber *max = description[@kIOPSMaxCapacityKey];
                if (current && max.doubleValue > 0) {
                    values[@"batteryPercent"] = @(round(100.0 * current.doubleValue / max.doubleValue));
                    values[@"batteryCharging"] = @([description[@kIOPSIsChargingKey] boolValue]);
                    break;
                }
            }
            CFRelease(sources);
        }
        CFRelease(powerInfo);
    }

    // Température — moyenne des capteurs HID plausibles. PrimaryUsagePage 0xff00 (AppleVendor),
    // PrimaryUsage 5 : les capteurs thermiques.
    TMHIDClientRef client = IOHIDEventSystemClientCreate(kCFAllocatorDefault);
    if (client) {
        NSDictionary *matching = @{ @"PrimaryUsagePage": @(0xff00), @"PrimaryUsage": @5 };
        IOHIDEventSystemClientSetMatching(client, (__bridge CFDictionaryRef)matching);
        CFArrayRef services = IOHIDEventSystemClientCopyServices(client);
        if (services) {
            double sum = 0;
            NSUInteger sensorCount = 0;
            for (CFIndex i = 0; i < CFArrayGetCount(services); i++) {
                TMHIDServiceRef service = (TMHIDServiceRef)CFArrayGetValueAtIndex(services, i);
                TMHIDEventRef event = IOHIDServiceClientCopyEvent(service, TMHIDEventTypeTemperature, 0, 0);
                if (!event) continue;
                double celsius = IOHIDEventGetFloatValue(event, TMHIDEventFieldTemperature);
                CFRelease(event);
                // Filtre de plausibilité : les capteurs fantômes rendent 0 ou des valeurs folles.
                if (celsius > 10 && celsius < 120) { sum += celsius; sensorCount++; }
            }
            CFRelease(services);
            if (sensorCount) values[@"tempC"] = @(round(sum / sensorCount));
        }
        CFRelease(client);
    }

    return values.count ? values : nil;
}

#pragma mark - Processus

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
        struct rusage_info_v2 usage;
        if (proc_pid_rusage(pids[i], RUSAGE_INFO_V2, (rusage_info_t *)&usage) != 0) continue;  // disparu ou interdit
        char name[2 * MAXCOMLEN];
        if (proc_name(pids[i], name, sizeof(name)) <= 0) continue;
        uint64_t cpuNs = (usage.ri_user_time + usage.ri_system_time) * timebase.numer / timebase.denom;
        sample[[@(pids[i]) stringValue]] = @{ @"name": @(name), @"cpuTimeNs": @(cpuNs),
                                              @"rssBytes": @(usage.ri_phys_footprint) };
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
        @"sensors": ^{ return TMCollectSensors(); },
        @"system":  ^{ return TMCollectSystem(); },
    } familyOrder:@[@"cpu", @"gpu", @"ram", @"network", @"disk", @"sensors", @"system"]];
}
