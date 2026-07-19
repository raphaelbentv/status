#import "StatusKeyboardLock.h"
// AXIsProcessTrusted / kAXTrustedCheckOptionPrompt vivent ici. AppKit les inclut peut-être de
// façon transitive : ne pas parier là-dessus.
#import <ApplicationServices/ApplicationServices.h>
#import <Cocoa/Cocoa.h>

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

#pragma mark - Overlay

@class TMKeyboardLock;

// Plein écran, au-dessus de tout — y compris la barre des menus, c'est documenté dans le header.
// L'anneau de progression se remplit pendant le maintien du clic ; le relâcher avant la fin
// annule, exactement comme TMHoldFraction le modélise.
@interface TMLockOverlayView : NSView
@property double holdFraction;
@property (copy) NSString *countdown;
@property (weak) TMKeyboardLock *lock;
@end

@interface TMKeyboardLock ()
@property TMLockState state;
- (void)holdDidBegin;
- (void)holdDidEnd;
@end

@implementation TMLockOverlayView

- (BOOL)acceptsFirstMouse:(NSEvent *)event { return YES; }
- (void)mouseDown:(NSEvent *)event { [self.lock holdDidBegin]; }
- (void)mouseUp:(NSEvent *)event { [self.lock holdDidEnd]; }

- (void)drawRect:(NSRect)dirtyRect {
    [[NSColor colorWithSRGBRed:0.055 green:0.071 blue:0.090 alpha:0.96] setFill];  // ardoise Blueprint
    NSRectFill(self.bounds);

    NSPoint center = NSMakePoint(NSMidX(self.bounds), NSMidY(self.bounds) + 30);
    const CGFloat radius = 44;
    NSColor *cyan = [NSColor colorWithSRGBRed:0.404 green:0.910 blue:0.976 alpha:1];

    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:0 endAngle:360];
    track.lineWidth = 3;
    [[cyan colorWithAlphaComponent:0.18] setStroke];
    [track stroke];

    if (self.holdFraction > 0) {
        NSBezierPath *progress = [NSBezierPath bezierPath];
        // Départ à midi, sens horaire : AppKit compte en trigonométrique, d'où les angles inversés.
        [progress appendBezierPathWithArcWithCenter:center radius:radius
                                         startAngle:90 endAngle:90 - self.holdFraction * 360 clockwise:YES];
        progress.lineWidth = 3;
        [cyan setStroke];
        [progress stroke];
    }

    NSDictionary *title = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:17 weight:NSFontWeightBold],
                             NSForegroundColorAttributeName: cyan };
    NSDictionary *body = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:12 weight:NSFontWeightRegular],
                            NSForegroundColorAttributeName: [NSColor colorWithWhite:0.80 alpha:1] };
    NSDictionary *faint = @{ NSFontAttributeName: [NSFont monospacedSystemFontOfSize:10.5 weight:NSFontWeightRegular],
                             NSForegroundColorAttributeName: [NSColor colorWithWhite:0.45 alpha:1] };
    void (^drawCentered)(NSString *, NSDictionary *, CGFloat) = ^(NSString *text, NSDictionary *attrs, CGFloat y) {
        NSSize size = [text sizeWithAttributes:attrs];
        [text drawAtPoint:NSMakePoint(center.x - size.width / 2, y) withAttributes:attrs];
    };
    drawCentered(@"CLAVIER VERROUILLÉ", title, center.y + radius + 36);
    drawCentered(@"Maintenez le clic 1 seconde pour déverrouiller", body, center.y - radius - 40);
    drawCentered(self.countdown ?: @"", body, center.y - radius - 66);
    drawCentered(@"Bouton d'alimentation et Touch ID restent actifs · levée automatique garantie",
                 faint, NSMinY(self.bounds) + 28);
}

@end

#pragma mark - Contrôleur

@implementation TMKeyboardLock {
    CFMachPortRef _tap;
    CFRunLoopSourceRef _tapSource;
    NSArray<NSWindow *> *_overlays;
    NSTimer *_holdTimer;      // 30 Hz pendant le maintien, anime l'anneau
    NSTimer *_countdownTimer; // 1 Hz, met à jour « levée automatique dans … »
    NSTimer *_backstopTimer;  // levée inconditionnelle
    NSTimeInterval _holdStart;
    NSDate *_lockedAt;
}

// Le tap avale tout ce qui vient du clavier — touches, modificateurs, touches média. Les deux
// événements de désactivation doivent traverser : les avaler laisserait le tap mort sans le savoir.
static CGEventRef TMLockTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    TMKeyboardLock *lock = (__bridge TMKeyboardLock *)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        // Réarmer : un timeout ponctuel (machine chargée) ne doit pas lever silencieusement le
        // verrou. Si l'app est réellement figée, ce code ne s'exécute pas — c'est le filet de la spec.
        [lock reenableTap];
        return event;
    }
    return NULL;
}

- (void)reenableTap { if (_tap) CGEventTapEnable(_tap, true); }

- (void)toggle {
    // Le panneau de demande ne s'affiche qu'à la première tentative ; ensuite macOS rend la
    // décision silencieusement. Blocked reste re-tentable : re-toggle après avoir accordé.
    BOOL trusted = AXIsProcessTrustedWithOptions(
        (__bridge CFDictionaryRef)@{ (__bridge NSString *)kAXTrustedCheckOptionPrompt: @YES });
    TMLockState next = TMLockStateAfterToggle(self.state, trusted);
    if (next == TMLockStateLocked && ![self installLock]) next = TMLockStateBlocked;
    if (self.state == TMLockStateLocked && next != TMLockStateLocked) [self teardownLock];
    [self transitionTo:next];
}

- (void)forceUnlock {
    if (self.state != TMLockStateLocked) return;
    [self teardownLock];
    [self transitionTo:TMLockStateUnlocked];
}

- (void)transitionTo:(TMLockState)next {
    if (next == self.state && next != TMLockStateBlocked) return;  // Blocked → Blocked renotifie (l'UI reclignote)
    self.state = next;
    if (self.stateChanged) self.stateChanged(next);
}

- (BOOL)installLock {
    CGEventMask mask = CGEventMaskBit(kCGEventKeyDown) | CGEventMaskBit(kCGEventKeyUp)
                     | CGEventMaskBit(kCGEventFlagsChanged) | CGEventMaskBit(NSEventTypeSystemDefined);
    _tap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                            mask, TMLockTapCallback, (__bridge void *)self);
    if (!_tap) return NO;  // permission listée mais pas effective : arrive après un re-cochage
    _tapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, _tap, 0);
    CFRunLoopAddSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes);

    _lockedAt = [NSDate date];
    NSMutableArray *overlays = [NSMutableArray array];
    for (NSScreen *screen in NSScreen.screens) {
        NSWindow *window = [[NSWindow alloc] initWithContentRect:screen.frame
                                                       styleMask:NSWindowStyleMaskBorderless
                                                         backing:NSBackingStoreBuffered defer:NO];
        window.level = CGShieldingWindowLevel();  // au-dessus de la barre des menus, comme documenté
        window.opaque = NO;
        window.backgroundColor = NSColor.clearColor;
        window.collectionBehavior = NSWindowCollectionBehaviorCanJoinAllSpaces
                                  | NSWindowCollectionBehaviorFullScreenAuxiliary;
        TMLockOverlayView *view = [[TMLockOverlayView alloc] initWithFrame:screen.frame];
        view.lock = self;
        window.contentView = view;
        [window makeKeyAndOrderFront:nil];
        [overlays addObject:window];
    }
    _overlays = overlays;
    [self updateCountdown];

    __weak typeof(self) weakSelf = self;
    _countdownTimer = [NSTimer scheduledTimerWithTimeInterval:1 repeats:YES block:^(NSTimer *timer) {
        [weakSelf updateCountdown];
    }];
    _backstopTimer = [NSTimer scheduledTimerWithTimeInterval:TMLockBackstopSeconds repeats:NO block:^(NSTimer *timer) {
        [weakSelf forceUnlock];
    }];
    return YES;
}

- (void)teardownLock {
    [_holdTimer invalidate]; _holdTimer = nil;
    [_countdownTimer invalidate]; _countdownTimer = nil;
    [_backstopTimer invalidate]; _backstopTimer = nil;
    for (NSWindow *window in _overlays) [window orderOut:nil];
    _overlays = nil;
    if (_tapSource) { CFRunLoopRemoveSource(CFRunLoopGetMain(), _tapSource, kCFRunLoopCommonModes); CFRelease(_tapSource); _tapSource = NULL; }
    if (_tap) { CGEventTapEnable(_tap, false); CFRelease(_tap); _tap = NULL; }
}

- (void)updateCountdown {
    NSTimeInterval remaining = MAX(0, TMLockBackstopSeconds - [[NSDate date] timeIntervalSinceDate:_lockedAt]);
    NSString *countdown = [NSString stringWithFormat:@"levée automatique dans %d:%02d",
                           (int)remaining / 60, (int)remaining % 60];
    for (NSWindow *window in _overlays) {
        ((TMLockOverlayView *)window.contentView).countdown = countdown;
        window.contentView.needsDisplay = YES;
    }
}

- (void)holdDidBegin {
    _holdStart = NSDate.timeIntervalSinceReferenceDate;
    __weak typeof(self) weakSelf = self;
    _holdTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 / 30 repeats:YES block:^(NSTimer *timer) {
        [weakSelf holdTick];
    }];
}

- (void)holdTick {
    double fraction = TMHoldFraction(NSDate.timeIntervalSinceReferenceDate - _holdStart, TMHoldRequiredSeconds);
    for (NSWindow *window in _overlays) {
        ((TMLockOverlayView *)window.contentView).holdFraction = fraction;
        window.contentView.needsDisplay = YES;
    }
    if (fraction >= 1.0) [self forceUnlock];
}

- (void)holdDidEnd {
    [_holdTimer invalidate]; _holdTimer = nil;
    for (NSWindow *window in _overlays) {
        ((TMLockOverlayView *)window.contentView).holdFraction = 0;
        window.contentView.needsDisplay = YES;
    }
}

@end
