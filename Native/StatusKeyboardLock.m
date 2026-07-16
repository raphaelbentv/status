#import "StatusKeyboardLock.h"
// AXIsProcessTrusted / kAXTrustedCheckOptionPrompt vivent ici. AppKit les inclut peut-être de
// façon transitive : ne pas parier là-dessus.
#import <ApplicationServices/ApplicationServices.h>

const NSTimeInterval TMHoldRequiredSeconds = 1.0;
const NSTimeInterval TMLockBackstopSeconds = 300.0;

double TMHoldFraction(NSTimeInterval elapsed, NSTimeInterval required) {
    if (required <= 0) return 1.0;  // une durée nulle est déjà écoulée — jamais de division par zéro
    double fraction = elapsed / required;
    if (fraction < 0) return 0.0;
    if (fraction > 1) return 1.0;
    return fraction;
}

TMLockState TMLockStateAfterToggle(TMLockState current, BOOL permissionGranted) {
    if (current == TMLockStateLocked) return TMLockStateUnlocked;
    return permissionGranted ? TMLockStateLocked : TMLockStateBlocked;
}
