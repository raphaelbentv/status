#import "StatusRamCleaner.h"
#import <mach/mach.h>
#import <sys/mman.h>
#import <sys/sysctl.h>

static const uint64_t TMRamReserveBytes = 1ull << 30;   // marge laissée au système
static const uint64_t TMRamChunkBytes = 128ull << 20;
static const NSTimeInterval TMRamMaxSeconds = 25;

uint64_t TMRamCleanTarget(uint64_t freeBytes, uint64_t cachedBytes, uint64_t totalBytes) {
    // Plus de borne « libre + cache » : on demande 60 % de la RAM, quitte à ce que le noyau compresse
    // des pages d'apps inactives pour y répondre (c'est voulu : le but est de les compresser).
    uint64_t cap = totalBytes / 10 * 6;
    return cap > TMRamReserveBytes ? cap - TMRamReserveBytes : 0;
}

// Libre = pages libres hors spéculatives ; cache = pages de fichiers (externes) + purgeables.
static BOOL TMRamSample(uint64_t *freeBytes, uint64_t *cachedBytes, uint64_t *totalBytes) {
    vm_statistics64_data_t s;
    mach_msg_type_number_t n = HOST_VM_INFO64_COUNT;
    if (host_statistics64(mach_host_self(), HOST_VM_INFO64, (host_info64_t)&s, &n) != KERN_SUCCESS) return NO;
    uint64_t total = 0; size_t size = sizeof(total);
    if (sysctlbyname("hw.memsize", &total, &size, NULL, 0) != 0 || !total) return NO;
    uint64_t page = vm_kernel_page_size;
    *freeBytes = (uint64_t)(s.free_count > s.speculative_count ? s.free_count - s.speculative_count : 0) * page;
    *cachedBytes = ((uint64_t)s.external_page_count + (uint64_t)s.purgeable_count) * page;
    *totalBytes = total;
    return YES;
}

static int TMRamPressure(void) {
    int level = 0; size_t size = sizeof(level);
    return sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, NULL, 0) == 0 ? level : 0;
}

@implementation TMRamCleaner {
    BOOL _running;
}

- (BOOL)isRunning { return _running; }

- (void)runWithCompletion:(void (^)(NSDictionary *))completion {
    if (_running) return;
    _running = YES;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *result = [self clean];
        dispatch_async(dispatch_get_main_queue(), ^{
            self->_running = NO;
            if (completion) completion(result);
        });
    });
}

- (NSDictionary *)clean {
    uint64_t freeBefore, cached, total;
    if (!TMRamSample(&freeBefore, &cached, &total)) return @{ @"status": @"aborted", @"freedBytes": @0, @"claimedBytes": @0 };
    uint64_t target = TMRamCleanTarget(freeBefore, cached, total);
    if (target == 0 || TMRamPressure() >= 4) return @{ @"status": @"nothing", @"freedBytes": @0, @"claimedBytes": @0 };

    NSMutableArray<NSValue *> *chunks = [NSMutableArray array];
    uint64_t claimed = 0;
    BOOL aborted = NO;
    NSDate *start = NSDate.date;
    long page = vm_kernel_page_size;
    while (claimed < target) {
        if (-start.timeIntervalSinceNow > TMRamMaxSeconds || TMRamPressure() >= 4) { aborted = YES; break; }
        uint64_t size = MIN(TMRamChunkBytes, target - claimed);
        void *p = mmap(NULL, size, PROT_READ | PROT_WRITE, MAP_ANON | MAP_PRIVATE, -1, 0);
        if (p == MAP_FAILED) { aborted = YES; break; }
        for (uint64_t off = 0; off < size; off += page) ((volatile char *)p)[off] = 1;  // force la résidence
        [chunks addObject:[NSValue valueWithPointer:p]];
        claimed += size;
    }
    // Chaque bloc a la taille TMRamChunkBytes, sauf le dernier : on relit la taille depuis `claimed`.
    uint64_t remaining = claimed;
    for (NSValue *v in chunks) {
        uint64_t size = MIN(TMRamChunkBytes, remaining);
        munmap(v.pointerValue, size);
        remaining -= size;
    }

    uint64_t freeAfter = freeBefore, cachedAfter, totalAfter;
    TMRamSample(&freeAfter, &cachedAfter, &totalAfter);
    uint64_t freed = freeAfter > freeBefore ? freeAfter - freeBefore : 0;
    return @{ @"status": aborted ? @"aborted" : @"done", @"freedBytes": @(freed), @"claimedBytes": @(claimed) };
}

@end
