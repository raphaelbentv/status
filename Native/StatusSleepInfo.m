#import "StatusSleepInfo.h"
#import <IOKit/IOKitLib.h>
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <IOKit/ps/IOPowerSources.h>
#import <libproc.h>

const NSTimeInterval TMSleepNoiseSeconds = 60;

// Types qui retiennent réellement la veille ; les alias historiques pointent vers le type canonique.
static NSString *TMSleepCanonicalType(NSString *type) {
    if ([type isEqual:@"NoIdleSleepAssertion"]) return @"PreventUserIdleSystemSleep";
    if ([type isEqual:@"NoDisplaySleepAssertion"]) return @"PreventUserIdleDisplaySleep";
    return type;
}
static BOOL TMSleepTypeBlocksSystem(NSString *type) {
    return [type isEqual:@"PreventUserIdleSystemSleep"] || [type isEqual:@"PreventSystemSleep"];
}
static BOOL TMSleepTypeBlocksDisplay(NSString *type) { return [type isEqual:@"PreventUserIdleDisplaySleep"]; }

// Démons macOS dont l'assertion revient en permanence (powerd tient l'éveil tant que l'écran est allumé).
static BOOL TMSleepIsSystemNoise(NSString *name) {
    return [@[@"powerd", @"nsurlsessiond"] containsObject:name];
}

NSArray<NSDictionary *> *TMSleepFlattenAssertions(NSDictionary *byPid, NSDate *now) {
    NSMutableArray *flat = [NSMutableArray array];
    if (![byPid isKindOfClass:NSDictionary.class]) return flat;
    for (id pid in byPid) {
        NSArray *list = byPid[pid];
        if (![list isKindOfClass:NSArray.class]) continue;
        for (NSDictionary *a in list) {
            if (![a isKindOfClass:NSDictionary.class]) continue;
            NSString *rawType = [a[@"AssertType"] isKindOfClass:NSString.class] ? a[@"AssertType"] : nil;
            NSString *type = rawType ? TMSleepCanonicalType(rawType) : nil;
            if (!type || !(TMSleepTypeBlocksSystem(type) || TMSleepTypeBlocksDisplay(type))) continue;
            NSString *name = [a[@"Process Name"] isKindOfClass:NSString.class] ? a[@"Process Name"] : nil;
            if (!name.length) {
                char buffer[PROC_PIDPATHINFO_MAXSIZE] = {0};
                if ([pid respondsToSelector:@selector(intValue)] && proc_name([pid intValue], buffer, sizeof(buffer)) > 0)
                    name = @(buffer);
            }
            NSString *label = [a[@"AssertName"] isKindOfClass:NSString.class] ? a[@"AssertName"]
                            : [a[@"HumanReadableReason"] isKindOfClass:NSString.class] ? a[@"HumanReadableReason"] : @"";
            NSDate *since = [a[@"AssertStartWhen"] isKindOfClass:NSDate.class] ? a[@"AssertStartWhen"] : nil;
            [flat addObject:@{ @"pid": @([pid respondsToSelector:@selector(intValue)] ? [pid intValue] : 0),
                               @"name": name.length ? name : @"?", @"type": type, @"label": label,
                               @"seconds": since ? @(MAX(0, floor([now timeIntervalSinceDate:since]))) : @(-1) }];
        }
    }
    return flat;
}

// Un groupe par nom d'app (Claude et ses processus auxiliaires comptent pour une seule ligne).
static NSArray<NSDictionary *> *TMSleepGroups(NSArray<NSDictionary *> *flat) {
    NSMutableDictionary<NSString *, NSMutableDictionary *> *byName = [NSMutableDictionary dictionary];
    for (NSDictionary *a in flat) {
        NSMutableDictionary *group = byName[a[@"name"]];
        if (!group) {
            group = [@{ @"name": a[@"name"], @"pids": [NSMutableArray array], @"seconds": @(-1),
                        @"blocksSystem": @NO, @"blocksDisplay": @NO, @"items": [NSMutableArray array] } mutableCopy];
            byName[a[@"name"]] = group;
        }
        if (![group[@"pids"] containsObject:a[@"pid"]]) [group[@"pids"] addObject:a[@"pid"]];
        if ([a[@"seconds"] doubleValue] > [group[@"seconds"] doubleValue]) group[@"seconds"] = a[@"seconds"];
        if (TMSleepTypeBlocksSystem(a[@"type"])) group[@"blocksSystem"] = @YES;
        if (TMSleepTypeBlocksDisplay(a[@"type"])) group[@"blocksDisplay"] = @YES;
        // Deux processus de la même app qui posent la même assertion ne font qu'une ligne.
        BOOL duplicate = NO;
        for (NSMutableDictionary *item in group[@"items"])
            if ([item[@"type"] isEqual:a[@"type"]] && [item[@"label"] isEqual:a[@"label"]]) {
                if ([a[@"seconds"] doubleValue] > [item[@"seconds"] doubleValue]) item[@"seconds"] = a[@"seconds"];
                duplicate = YES;
            }
        if (!duplicate) [group[@"items"] addObject:[@{ @"type": a[@"type"], @"label": a[@"label"], @"seconds": a[@"seconds"] } mutableCopy]];
    }
    return [byName.allValues sortedArrayUsingComparator:^NSComparisonResult(NSDictionary *x, NSDictionary *y) {
        NSComparisonResult byAge = [y[@"seconds"] compare:x[@"seconds"]];
        return byAge != NSOrderedSame ? byAge : [x[@"name"] compare:y[@"name"]];
    }];
}

NSArray<NSDictionary *> *TMSleepGroupAssertions(NSArray<NSDictionary *> *flat, NSArray<NSDictionary *> **hidden) {
    NSMutableArray *kept = [NSMutableArray array], *noise = [NSMutableArray array];
    for (NSDictionary *a in flat) {
        double seconds = [a[@"seconds"] doubleValue];
        BOOL isNoise = TMSleepIsSystemNoise(a[@"name"]) || (seconds >= 0 && seconds < TMSleepNoiseSeconds);
        [isNoise ? noise : kept addObject:a];
    }
    if (hidden) *hidden = TMSleepGroups(noise);
    return TMSleepGroups(kept);
}

BOOL TMSleepDisabledBlocksLidMode(BOOL sleepDisabled, BOOL statusLidSession) {
    return sleepDisabled && !statusLidSession;
}

// SleepDisabled vit sur IOPMrootDomain, lisible sans root (c'est ce que `pmset -g` affiche).
static BOOL TMSleepDisabledNow(void) {
    io_service_t root = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("IOPMrootDomain"));
    if (!root) return NO;
    CFTypeRef value = IORegistryEntryCreateCFProperty(root, CFSTR("SleepDisabled"), kCFAllocatorDefault, 0);
    IOObjectRelease(root);
    BOOL disabled = NO;
    if (value) {
        disabled = CFGetTypeID(value) == CFBooleanGetTypeID() ? CFBooleanGetValue(value)
                 : CFGetTypeID(value) == CFNumberGetTypeID() ? [(__bridge NSNumber *)value boolValue] : NO;
        CFRelease(value);
    }
    return disabled;
}

NSDictionary *TMSleepInfoRead(void) {
    NSMutableDictionary *info = [NSMutableDictionary dictionary];
    info[@"disabled"] = @(TMSleepDisabledNow());
    // Réglage « sleep » du profil actif : minutes avant la veille, 0 = jamais. Illisible = absent.
    CFTypeRef source = IOPSCopyPowerSourcesInfo();
    NSString *providing = source ? (__bridge NSString *)IOPSGetProvidingPowerSourceType(source) : nil;
    BOOL onBattery = [providing isEqual:@"Battery Power"];
    if (source) CFRelease(source);
    info[@"onBattery"] = @(onBattery);
    NSDictionary *plist = [NSDictionary dictionaryWithContentsOfFile:@"/Library/Preferences/com.apple.PowerManagement.plist"];
    NSDictionary *profile = [plist[onBattery ? @"Battery Power" : @"AC Power"] isKindOfClass:NSDictionary.class]
        ? plist[onBattery ? @"Battery Power" : @"AC Power"] : nil;
    if ([profile[@"System Sleep Timer"] isKindOfClass:NSNumber.class]) info[@"sleepMinutes"] = profile[@"System Sleep Timer"];

    CFDictionaryRef raw = NULL;
    NSArray *hidden = @[], *groups = @[];
    if (IOPMCopyAssertionsByProcess(&raw) == kIOReturnSuccess && raw) {
        groups = TMSleepGroupAssertions(TMSleepFlattenAssertions((__bridge_transfer NSDictionary *)raw, NSDate.date), &hidden);
    }
    info[@"groups"] = groups;
    info[@"hidden"] = hidden;
    return info;
}
