#import "StatusMachine.h"
#import <sys/sysctl.h>

NSString *TMMachineModel(void) {
    size_t size = 0;
    if (sysctlbyname("hw.model", NULL, &size, NULL, 0) != 0 || size < 2 || size > 128) return nil;
    char buffer[128] = {0};
    if (sysctlbyname("hw.model", buffer, &size, NULL, 0) != 0) return nil;
    NSString *model = [NSString stringWithUTF8String:buffer];
    return model.length ? model : nil;
}

NSArray<NSString *> *TMFanlessMacBookModels(void) {
    return @[
        @"MacBookAir10,1",                     // M1, 2020
        @"Mac14,2", @"Mac14,15",               // M2 : 13 et 15 pouces
        @"Mac15,12", @"Mac15,13",              // M3 : 13 et 15 pouces
        @"Mac16,12", @"Mac16,13",              // M4 : 13 et 15 pouces
    ];
}

BOOL TMMachineIsFanlessMacBook(NSString *model) {
    if (![model isKindOfClass:NSString.class]) return NO;
    return [TMFanlessMacBookModels() containsObject:model];
}
