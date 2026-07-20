#import "StatusWindowManager.h"
#import <Cocoa/Cocoa.h>
#import <ApplicationServices/ApplicationServices.h>

#pragma mark - Géométrie

// Une disposition se décrit par une fraction de départ et une largeur, en colonnes normalisées.
// Passer par des fractions plutôt que des pixels permet d'arrondir une seule fois, à la fin, et
// donc de garantir que deux dispositions complémentaires se rejoignent exactement.
typedef struct { double start; double width; BOOL inset; } TMLayoutSpec;

static TMLayoutSpec TMSpecFor(TMWindowLayout layout) {
    switch (layout) {
        case TMLayoutLeftHalf:           return (TMLayoutSpec){ 0,        1.0 / 2,  NO };
        case TMLayoutRightHalf:          return (TMLayoutSpec){ 1.0 / 2,  1.0 / 2,  NO };
        case TMLayoutLeftTwoThirds:      return (TMLayoutSpec){ 0,        2.0 / 3,  NO };
        case TMLayoutRightTwoThirds:     return (TMLayoutSpec){ 1.0 / 3,  2.0 / 3,  NO };
        case TMLayoutLeftThird:          return (TMLayoutSpec){ 0,        1.0 / 3,  NO };
        case TMLayoutCenterThird:        return (TMLayoutSpec){ 1.0 / 3,  1.0 / 3,  NO };
        case TMLayoutRightThird:         return (TMLayoutSpec){ 2.0 / 3,  1.0 / 3,  NO };
        case TMLayoutLeftThreeQuarters:  return (TMLayoutSpec){ 0,        3.0 / 4,  NO };
        case TMLayoutRightThreeQuarters: return (TMLayoutSpec){ 1.0 / 4,  3.0 / 4,  NO };
        case TMLayoutMaximize:           return (TMLayoutSpec){ 0,        1.0,      NO };
        case TMLayoutCenter:             return (TMLayoutSpec){ 0,        1.0,      YES };
    }
    return (TMLayoutSpec){ 0, 1.0, NO };
}

// Fraction de la zone occupée par « centrer ». Assez grand pour être confortable, assez petit
// pour que le geste se voie — sinon centrer une fenêtre déjà large ne produirait rien de visible.
static const double TMCenterFraction = 0.62;

CGRect TMWindowFrameForLayout(CGRect zone, TMWindowLayout layout, TMWindowGaps gaps) {
    TMLayoutSpec spec = TMSpecFor(layout);

    if (spec.inset) {
        CGFloat w = round(CGRectGetWidth(zone) * TMCenterFraction);
        CGFloat h = round(CGRectGetHeight(zone) * TMCenterFraction);
        return CGRectMake(round(CGRectGetMidX(zone) - w / 2), round(CGRectGetMidY(zone) - h / 2), w, h);
    }

    // Les bornes sont calculées en fractions puis arrondies une seule fois : deux dispositions
    // qui partagent une frontière tombent donc sur le même pixel, sans bande ni recouvrement.
    CGFloat left  = round(CGRectGetMinX(zone) + spec.start * CGRectGetWidth(zone));
    CGFloat right = round(CGRectGetMinX(zone) + (spec.start + spec.width) * CGRectGetWidth(zone));

    // La marge inter-fenêtres ne vaut qu'aux frontières intérieures ; les bords de l'écran
    // reçoivent la marge de bord, jamais les deux. Une demi-marge de chaque côté d'une frontière
    // partagée donne exactement `between` entre deux fenêtres voisines.
    BOOL touchesLeft  = spec.start <= 0.0001;
    BOOL touchesRight = spec.start + spec.width >= 0.9999;
    left  += touchesLeft  ? gaps.edge : gaps.between / 2;
    right -= touchesRight ? gaps.edge : gaps.between / 2;

    CGFloat top    = CGRectGetMinY(zone) + gaps.edge;
    CGFloat height = CGRectGetHeight(zone) - 2 * gaps.edge;
    return CGRectMake(left, top, MAX(right - left, 1), MAX(height, 1));
}

BOOL TMWindowLayoutFromIdentifier(NSString *identifier, TMWindowLayout *outLayout) {
    if (![identifier isKindOfClass:NSString.class] || !identifier.length) return NO;
    static NSDictionary<NSString *, NSNumber *> *table;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"left-half": @(TMLayoutLeftHalf), @"right-half": @(TMLayoutRightHalf),
            @"left-two-thirds": @(TMLayoutLeftTwoThirds), @"right-two-thirds": @(TMLayoutRightTwoThirds),
            @"left-third": @(TMLayoutLeftThird), @"center-third": @(TMLayoutCenterThird),
            @"right-third": @(TMLayoutRightThird),
            @"left-three-quarters": @(TMLayoutLeftThreeQuarters),
            @"right-three-quarters": @(TMLayoutRightThreeQuarters),
            @"maximize": @(TMLayoutMaximize), @"center": @(TMLayoutCenter),
        };
    });
    NSNumber *found = table[identifier];
    if (!found) return NO;
    if (outLayout) *outLayout = (TMWindowLayout)found.integerValue;
    return YES;
}

CGRect TMWindowFrameMovedToScreen(CGRect frame, CGRect fromScreen, CGRect toScreen) {
    if (CGRectGetWidth(fromScreen) <= 0 || CGRectGetHeight(fromScreen) <= 0) return frame;

    // Position et taille relatives, pour qu'une moitié gauche reste une moitié gauche quel que
    // soit le rapport d'aspect de l'écran d'arrivée.
    double rx = (CGRectGetMinX(frame) - CGRectGetMinX(fromScreen)) / CGRectGetWidth(fromScreen);
    double ry = (CGRectGetMinY(frame) - CGRectGetMinY(fromScreen)) / CGRectGetHeight(fromScreen);
    double rw = CGRectGetWidth(frame) / CGRectGetWidth(fromScreen);
    double rh = CGRectGetHeight(frame) / CGRectGetHeight(fromScreen);

    CGFloat w = round(MIN(rw, 1.0) * CGRectGetWidth(toScreen));
    CGFloat h = round(MIN(rh, 1.0) * CGRectGetHeight(toScreen));
    CGFloat x = round(CGRectGetMinX(toScreen) + rx * CGRectGetWidth(toScreen));
    CGFloat y = round(CGRectGetMinY(toScreen) + ry * CGRectGetHeight(toScreen));

    // Une fenêtre plus grande que l'écran d'arrivée doit y tenir, pas déborder.
    x = MIN(MAX(x, CGRectGetMinX(toScreen)), CGRectGetMaxX(toScreen) - w);
    y = MIN(MAX(y, CGRectGetMinY(toScreen)), CGRectGetMaxY(toScreen) - h);
    return CGRectMake(x, y, w, h);
}

#pragma mark - Application (parle aux autres processus)

// L'API d'Accessibilité travaille en coordonnées « écran » avec l'origine en haut à gauche du
// display principal, là où AppKit place la sienne en bas à gauche. Sans cette conversion, une
// fenêtre placée « en haut » atterrit en bas.
static CGRect TMFlipForAX(CGRect cocoaRect) {
    CGFloat maxY = NSMaxY(NSScreen.screens.firstObject.frame);
    return CGRectMake(CGRectGetMinX(cocoaRect), maxY - CGRectGetMaxY(cocoaRect),
                      CGRectGetWidth(cocoaRect), CGRectGetHeight(cocoaRect));
}

static CGRect TMFlipFromAX(CGRect axRect) {
    CGFloat maxY = NSMaxY(NSScreen.screens.firstObject.frame);
    return CGRectMake(CGRectGetMinX(axRect), maxY - CGRectGetMaxY(axRect),
                      CGRectGetWidth(axRect), CGRectGetHeight(axRect));
}

@implementation TMWindowManager

// Fenêtre au premier plan de l'application au premier plan. nil si l'autorisation manque, si
// aucune app n'est active, ou si l'app n'expose pas de fenêtre principale (Finder sans fenêtre).
- (AXUIElementRef _Nullable)copyFocusedWindow CF_RETURNS_RETAINED {
    if (!AXIsProcessTrusted()) return NULL;
    NSRunningApplication *front = NSWorkspace.sharedWorkspace.frontmostApplication;
    if (!front || front.processIdentifier == NSRunningApplication.currentApplication.processIdentifier) return NULL;

    AXUIElementRef app = AXUIElementCreateApplication(front.processIdentifier);
    if (!app) return NULL;
    CFTypeRef window = NULL;
    AXError error = AXUIElementCopyAttributeValue(app, kAXFocusedWindowAttribute, &window);
    CFRelease(app);
    if (error != kAXErrorSuccess || !window) return NULL;
    return (AXUIElementRef)window;
}

- (BOOL)isFullScreen:(AXUIElementRef)window {
    CFTypeRef value = NULL;
    if (AXUIElementCopyAttributeValue(window, CFSTR("AXFullScreen"), &value) != kAXErrorSuccess || !value) return NO;
    BOOL full = CFBooleanGetValue((CFBooleanRef)value);
    CFRelease(value);
    return full;
}

- (CGRect)frameOf:(AXUIElementRef)window {
    CFTypeRef positionValue = NULL, sizeValue = NULL;
    CGPoint position = CGPointZero; CGSize size = CGSizeZero;
    if (AXUIElementCopyAttributeValue(window, kAXPositionAttribute, &positionValue) == kAXErrorSuccess && positionValue) {
        AXValueGetValue((AXValueRef)positionValue, kAXValueCGPointType, &position);
        CFRelease(positionValue);
    }
    if (AXUIElementCopyAttributeValue(window, kAXSizeAttribute, &sizeValue) == kAXErrorSuccess && sizeValue) {
        AXValueGetValue((AXValueRef)sizeValue, kAXValueCGSizeType, &size);
        CFRelease(sizeValue);
    }
    return TMFlipFromAX(CGRectMake(position.x, position.y, size.width, size.height));
}

// Écrit la taille puis la position, puis les deux à nouveau : une fenêtre dont la taille minimale
// dépasse la place disponible se recale, et l'ordre seul ne suffit pas toujours. Deux passes
// suffisent en pratique — on ne boucle pas au-delà, la spec l'interdit.
- (BOOL)setFrame:(CGRect)cocoaFrame on:(AXUIElementRef)window {
    CGRect target = TMFlipForAX(cocoaFrame);
    for (int pass = 0; pass < 2; pass++) {
        CGSize size = target.size;
        CGPoint origin = target.origin;
        AXValueRef sizeValue = AXValueCreate(kAXValueCGSizeType, &size);
        AXValueRef positionValue = AXValueCreate(kAXValueCGPointType, &origin);
        if (sizeValue) { AXUIElementSetAttributeValue(window, kAXSizeAttribute, sizeValue); CFRelease(sizeValue); }
        if (positionValue) { AXUIElementSetAttributeValue(window, kAXPositionAttribute, positionValue); CFRelease(positionValue); }
    }
    // Relecture : une app à taille fixe accepte l'écriture sans rien changer. On le constate au
    // lieu de rapporter un succès imaginaire.
    CGRect obtained = [self frameOf:window];
    return fabs(CGRectGetMinX(obtained) - CGRectGetMinX(cocoaFrame)) < 8
        && fabs(CGRectGetWidth(obtained) - CGRectGetWidth(cocoaFrame)) < 8;
}

// Écran portant la plus grande part de la fenêtre — et non celui de la souris : on place la
// fenêtre là où elle est déjà, pas là où le curseur traîne.
- (NSScreen *)screenForFrame:(CGRect)frame {
    NSScreen *best = NSScreen.mainScreen;
    CGFloat bestArea = -1;
    for (NSScreen *screen in NSScreen.screens) {
        CGRect intersection = CGRectIntersection(screen.frame, frame);
        CGFloat area = CGRectIsNull(intersection) ? 0 : CGRectGetWidth(intersection) * CGRectGetHeight(intersection);
        if (area > bestArea) { bestArea = area; best = screen; }
    }
    return best;
}

- (TMWindowGaps)currentGaps {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    return (TMWindowGaps){ [defaults integerForKey:@"windowGapBetween"],
                           [defaults integerForKey:@"windowGapEdge"] };
}

// visibleFrame retranche barre des menus et Dock ; frame donne l'écran physique entier.
- (CGRect)zoneForScreen:(NSScreen *)screen {
    BOOL respectReserved = ![NSUserDefaults.standardUserDefaults boolForKey:@"windowIgnoreReservedAreas"];
    return respectReserved ? screen.visibleFrame : screen.frame;
}

- (BOOL)applyLayout:(TMWindowLayout)layout {
    AXUIElementRef window = [self copyFocusedWindow];
    if (!window) return NO;
    BOOL ok = NO;
    if (![self isFullScreen:window]) {  // le plein écran natif vit dans son propre espace
        NSScreen *screen = [self screenForFrame:[self frameOf:window]];
        CGRect frame = TMWindowFrameForLayout([self zoneForScreen:screen], layout, [self currentGaps]);
        ok = [self setFrame:frame on:window];
    }
    CFRelease(window);
    return ok;
}

- (BOOL)moveToAdjacentScreen:(BOOL)next {
    NSArray<NSScreen *> *screens = NSScreen.screens;
    if (screens.count < 2) return NO;
    AXUIElementRef window = [self copyFocusedWindow];
    if (!window) return NO;
    BOOL ok = NO;
    if (![self isFullScreen:window]) {
        CGRect frame = [self frameOf:window];
        NSScreen *from = [self screenForFrame:frame];
        NSUInteger index = [screens indexOfObject:from];
        NSScreen *to = screens[(index + (next ? 1 : screens.count - 1)) % screens.count];
        ok = [self setFrame:TMWindowFrameMovedToScreen(frame, [self zoneForScreen:from], [self zoneForScreen:to])
                         on:window];
    }
    CFRelease(window);
    return ok;
}

@end
