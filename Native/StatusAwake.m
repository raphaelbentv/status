#import "StatusAwake.h"
#import <IOKit/pwr_mgt/IOPMLib.h>

@implementation TMAwake {
    IOPMAssertionID _assertion;
    BOOL _enabled;
}

- (BOOL)isEnabled { return _enabled; }

- (void)setEnabled:(BOOL)enabled {
    if (enabled == _enabled) return;  // sans ce garde, rallumer fuit l'assertion précédente
    if (enabled) {
        IOReturn result = IOPMAssertionCreateWithName(
            kIOPMAssertionTypePreventUserIdleDisplaySleep, kIOPMAssertionLevelOn,
            CFSTR("Status — veille désactivée"), &_assertion);
        // Si IOKit refuse, on reste éteint : mieux vaut un interrupteur qui ne s'allume pas qu'un
        // interrupteur allumé qui ne fait rien.
        _enabled = (result == kIOReturnSuccess);
    } else {
        IOPMAssertionRelease(_assertion);
        _assertion = 0;
        _enabled = NO;
    }
}

- (void)dealloc {
    if (_enabled) IOPMAssertionRelease(_assertion);
}

@end
