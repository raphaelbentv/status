#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#include <string.h>

#import "StatusQuota.h"
#import "StatusAwake.h"
#import "StatusSystemMonitor.h"
#import "StatusKeyboardLock.h"
#import "StatusCodexServer.h"
#import "StatusWindowManager.h"
#import <ApplicationServices/ApplicationServices.h>  // AXIsProcessTrusted

// Unofficial, session-cookie-based source for the live Claude quota windows, which Claude Code's
// official statusLine cannot provide on demand. The endpoint is undocumented and can change or
// break without notice; the cookie is stored locally in the Keychain and never leaves this Mac.
static NSString *const TMService = @"com.raphael.tokenmeter.credentials";
static NSString *const TMClaudeSessionCookieAccount = @"claude-session-cookie";

static NSString *TMKeychainRead(NSString *account) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TMService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    if (SecItemCopyMatching((__bridge CFDictionaryRef)query, &result) != errSecSuccess) return @"";
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static BOOL TMKeychainSave(NSString *account, NSString *value) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TMService,
        (__bridge id)kSecAttrAccount: account
    };
    if (value.length == 0) {
        SecItemDelete((__bridge CFDictionaryRef)query);
        return YES;
    }
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)kSecAttrAccessibleAfterFirstUnlock
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        [item addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}




// Seuils partagés par l'icône, la couleur du texte et les notifications : un seul vocabulaire
// d'urgence dans toute l'app.
typedef NS_ENUM(NSInteger, TMSeverity) { TMSeverityNormal = 0, TMSeverityWarn, TMSeverityCritical };

static TMSeverity TMSeverityForPercent(double used) {
    if (used >= 95) return TMSeverityCritical;
    if (used >= 80) return TMSeverityWarn;
    return TMSeverityNormal;
}

// Palette de la barre des menus — distincte de celle de l'interface, et pour une raison mesurée :
// le cyan #67E8F9 et l'ambre #FBBF24 de l'app tombent à 1,3:1 et 1,5:1 de contraste sur une barre
// des menus claire, donc invisibles. Ces quatre teintes-ci passent le seuil de 3:1 sur fond clair
// ET sombre. La couleur porte l'identité du fournisseur ; l'urgence la remplace quand elle parle.
static NSColor *TMMenuBarInk(uint32_t rgb) {
    return [NSColor colorWithSRGBRed:((rgb >> 16) & 0xFF) / 255.0
                               green:((rgb >> 8) & 0xFF) / 255.0
                                blue:(rgb & 0xFF) / 255.0 alpha:1];
}
#define TM_INK_OPENAI   TMMenuBarInk(0x0891B2)  // cyan foncé
#define TM_INK_CLAUDE   TMMenuBarInk(0x8B5CF6)  // violet
#define TM_INK_WARN     TMMenuBarInk(0xB45309)  // ambre foncé
#define TM_INK_CRITICAL TMMenuBarInk(0xDC2626)  // rouge

static NSColor *TMSeverityColor(TMSeverity severity) {
    switch (severity) {
        case TMSeverityCritical: return TM_INK_CRITICAL;
        case TMSeverityWarn:     return TM_INK_WARN;
        default:                 return NSColor.blackColor;  // ignoré : rendu en template
    }
}

// L'icône EST la jauge : l'anneau se remplit avec la consommation, au lieu d'un pictogramme
// décoratif qui n'apprend rien. Lecture périphérique par la forme, lecture précise par le texte.
//
// `providerInk` colore l'anneau à l'identité du fournisseur affiché — on sait d'un coup d'œil si
// le chiffre parle d'OpenAI ou de Claude, ce que la forme seule ne disait pas. L'urgence prend le
// dessus quand elle survient : à ce moment-là, savoir *qui* importe moins que savoir *que*.
//
// nil ⇒ rendu en template, et macOS inverse l'icône selon le thème et la surbrillance. C'est le
// cas quand il n'y a rien à identifier : métrique système, ou pas encore de valeur. La couleur ne
// sert jamais de décor ici — sa présence signifie qu'elle porte une information.
static NSImage *TMGaugeIcon(double fraction, BOOL hasValue, TMSeverity severity, NSColor *providerInk) {
    const CGFloat side = 18, radius = 6.3, lineWidth = 2.0;
    NSPoint center = NSMakePoint(side / 2, side / 2);
    BOOL colored = providerInk != nil || severity != TMSeverityNormal;
    NSColor *ink = (severity != TMSeverityNormal) ? TMSeverityColor(severity)
                 : providerInk ?: NSColor.blackColor;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
    [image lockFocus];

    // Piste toujours visible : le vide doit se lire autant que le plein.
    //
    // Elle reste neutre même en alerte. Teintée d'ambre ou de rouge comme l'arc, elle ne s'en
    // distinguait plus que par l'alpha, et l'anneau se lisait uniformément plein — le niveau
    // devenait illisible juste au moment où il compte. Le gris moyen tient sur les deux fonds.
    NSColor *trackInk = !colored
        ? [ink colorWithAlphaComponent:0.3]                 // template : seul l'alpha compte
        : (severity == TMSeverityNormal
           ? [ink colorWithAlphaComponent:0.22]             // teintée : la piste reste de la famille
           : [NSColor colorWithWhite:0.55 alpha:0.6]);
    NSBezierPath *track = [NSBezierPath bezierPath];
    [track appendBezierPathWithArcWithCenter:center radius:radius startAngle:0 endAngle:360];
    track.lineWidth = lineWidth;
    [trackInk setStroke];
    [track stroke];

    if (hasValue && fraction > 0) {
        // Part de midi, sens horaire : la convention d'une jauge qui se remplit.
        CGFloat sweep = MIN(MAX(fraction, 0), 1) * 360;
        NSBezierPath *arc = [NSBezierPath bezierPath];
        [arc appendBezierPathWithArcWithCenter:center radius:radius
                                    startAngle:90 endAngle:90 - sweep clockwise:YES];
        arc.lineWidth = lineWidth;
        arc.lineCapStyle = NSLineCapStyleRound;
        [ink setStroke];
        [arc stroke];
    } else if (!hasValue) {
        // Sans donnée : un tiret, jamais un anneau vide — qui se lirait « 0 % ».
        NSBezierPath *dash = [NSBezierPath bezierPath];
        dash.lineWidth = 1.6;
        dash.lineCapStyle = NSLineCapStyleRound;
        [dash moveToPoint:NSMakePoint(center.x - 2.4, center.y)];
        [dash lineToPoint:NSMakePoint(center.x + 2.4, center.y)];
        [[ink colorWithAlphaComponent:0.55] setStroke];
        [dash stroke];
    }

    [image unlockFocus];
    image.template = !colored;
    return image;
}

// Sparkline pour la barre des menus (feature 9) : la tendance récente de la fenêtre épinglée,
// dessinée là où l'anneau montrerait le niveau. Même sémantique de couleur que l'anneau — teinte
// du fournisseur en régime normal, sévérité en alerte, template quand il n'y a rien à identifier.
// `series` va du plus ancien au plus récent, en pourcents.
static NSImage *TMSparklineIcon(NSArray<NSNumber *> *series, BOOL hasValue, TMSeverity severity, NSColor *providerInk) {
    const CGFloat w = 26, h = 18, pad = 2;
    BOOL colored = providerInk != nil || severity != TMSeverityNormal;
    NSColor *ink = (severity != TMSeverityNormal) ? TMSeverityColor(severity)
                 : providerInk ?: NSColor.blackColor;

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(w, h)];
    [image lockFocus];

    if (!hasValue || series.count < 2) {
        // Pas encore de tendance : un tiret, comme l'anneau sans donnée.
        NSBezierPath *dash = [NSBezierPath bezierPath];
        dash.lineWidth = 1.6;
        dash.lineCapStyle = NSLineCapStyleRound;
        [dash moveToPoint:NSMakePoint(w / 2 - 3, h / 2)];
        [dash lineToPoint:NSMakePoint(w / 2 + 3, h / 2)];
        [[ink colorWithAlphaComponent:0.55] setStroke];
        [dash stroke];
    } else {
        // Échelle fixe 0–100 : la hauteur d'un point dit son pourcentage absolu, pas relatif à la
        // fenêtre visible — sinon une variation de 2 % remplirait toute la hauteur et alarmerait.
        NSUInteger n = series.count;
        CGFloat plotW = w - 2 * pad, plotH = h - 2 * pad;
        NSBezierPath *line = [NSBezierPath bezierPath];
        line.lineWidth = 1.3;
        line.lineJoinStyle = NSLineJoinStyleRound;
        for (NSUInteger i = 0; i < n; i++) {
            CGFloat x = pad + (CGFloat)i / (n - 1) * plotW;
            CGFloat y = pad + MIN(MAX(series[i].doubleValue, 0), 100) / 100.0 * plotH;
            if (i == 0) [line moveToPoint:NSMakePoint(x, y)];
            else [line lineToPoint:NSMakePoint(x, y)];
        }
        [ink setStroke];
        [line stroke];
        // Point terminal accentué : « où j'en suis maintenant ».
        CGFloat lastX = pad + plotW, lastY = pad + MIN(MAX(series.lastObject.doubleValue, 0), 100) / 100.0 * plotH;
        NSRect dot = NSMakeRect(lastX - 1.5, lastY - 1.5, 3, 3);
        [ink setFill];
        [[NSBezierPath bezierPathWithOvalInRect:dot] fill];
    }

    [image unlockFocus];
    image.template = !colored;
    return image;
}

// Chiffres tabulaires : l'élément ne doit pas frétiller latéralement quand la valeur change.
static NSAttributedString *TMMenuBarTitle(NSString *text, TMSeverity severity) {
    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium]
    } mutableCopy];
    // En régime normal, laisser macOS choisir la couleur du texte (thème, survol, contraste réduit).
    // On ne l'impose qu'en alerte, pour l'accorder à l'anneau.
    if (severity != TMSeverityNormal) attributes[NSForegroundColorAttributeName] = TMSeverityColor(severity);
    return [[NSAttributedString alloc] initWithString:text attributes:attributes];
}

typedef void (^TMProcessJSONCompletion)(NSDictionary *json, int terminationStatus, NSError *error);

// Erreurs de l'app. Ce helper vivait avec le serveur Codex et portait son domaine, alors que ses
// seuls appelants restants concernent la session claude.ai — l'extraction du module l'a mis en
// évidence. Chaque source a désormais le sien.
static NSError *TMError(NSString *message) {
    return [NSError errorWithDomain:@"Status" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message ?: @"Erreur inconnue"}];
}


static NSString *TMResolveViaLoginShell(NSString *command) {
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:@"/bin/zsh"];
    task.arguments = @[@"-lc", [NSString stringWithFormat:@"command -v %@", command]];
    NSPipe *output = [NSPipe pipe];
    task.standardOutput = output;
    task.standardError = [NSPipe pipe];
    @try {
        if (![task launchAndReturnError:nil]) return @"";
    } @catch (__unused NSException *exception) {
        return @"";
    }
    [task waitUntilExit];
    NSData *data = [output.fileHandleForReading readDataToEndOfFile];
    NSString *result = [[[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @""
        stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    NSString *firstLine = [result componentsSeparatedByString:@"\n"].firstObject ?: @"";
    return [NSFileManager.defaultManager isExecutableFileAtPath:firstLine] ? firstLine : @"";
}

static NSString *TMClaudeExecutablePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"STATUS_CLAUDE_PATH"];
    if (override.length && [NSFileManager.defaultManager isExecutableFileAtPath:override]) return override;
    NSArray<NSString *> *candidates = @[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/claude"],
        [NSHomeDirectory() stringByAppendingPathComponent:@".claude/local/claude"],
        @"/opt/homebrew/bin/claude",
        @"/usr/local/bin/claude"
    ];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    // Falls back to a login shell so version managers (nvm, volta, asdf, etc.)
    // that only modify PATH via shell rc files are still found.
    return TMResolveViaLoginShell(@"claude");
}

static NSString *TMPythonExecutablePath(void) {
    for (NSString *candidate in @[@"/usr/bin/python3", @"/opt/homebrew/bin/python3", @"/usr/local/bin/python3"]) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return @"";
}

static void TMRunJSONProcess(NSString *executable, NSArray<NSString *> *arguments, TMProcessJSONCompletion completion) {
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INITIATED, 0), ^{
        NSTask *task = [NSTask new];
        task.executableURL = [NSURL fileURLWithPath:executable];
        task.arguments = arguments;
        NSPipe *output = [NSPipe pipe];
        NSPipe *errors = [NSPipe pipe];
        task.standardOutput = output;
        task.standardError = errors;
        NSError *launchError;
        if (![task launchAndReturnError:&launchError]) {
            dispatch_async(dispatch_get_main_queue(), ^{ completion(nil, -1, launchError); });
            return;
        }
        [task waitUntilExit];
        NSData *data = [output.fileHandleForReading readDataToEndOfFile];
        // Drain stderr without exposing it: authentication tools may include sensitive diagnostics.
        (void)[errors.fileHandleForReading readDataToEndOfFile];
        NSDictionary *json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        dispatch_async(dispatch_get_main_queue(), ^{ completion([json isKindOfClass:NSDictionary.class] ? json : nil, task.terminationStatus, nil); });
    });
}

static NSString *TMShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\"'\"'"]];
}

static NSString *TMAppleScriptString(NSString *value) {
    NSString *escaped = [value stringByReplacingOccurrencesOfString:@"\\" withString:@"\\\\"];
    escaped = [escaped stringByReplacingOccurrencesOfString:@"\"" withString:@"\\\""];
    return [NSString stringWithFormat:@"\"%@\"", escaped];
}










#pragma mark - Historique local des quotas









static NSString *TMAccountQuotaLine(NSString *name, NSArray *windows) {
    double sessionUsed = 0, weeklyUsed = 0;
    BOOL hasSession = TMMaxUsedPercent(@[windows ?: @[]], ^BOOL(NSDictionary *w) { return TMWindowIsSession(w); }, &sessionUsed);
    BOOL hasWeekly = TMMaxUsedPercent(@[windows ?: @[]], ^BOOL(NSDictionary *w) { return TMWindowIsWeekly(w); }, &weeklyUsed);
    NSString *lower = name.lowercaseString;
    if (!hasSession && !hasWeekly) return [NSString stringWithFormat:@"%@   -- not connected", lower];
    NSMutableArray<NSString *> *parts = [NSMutableArray array];
    if (hasSession) [parts addObject:[NSString stringWithFormat:@"5h:%ld%%", (long)(sessionUsed + 0.5)]];
    if (hasWeekly) [parts addObject:[NSString stringWithFormat:@"wk:%ld%%", (long)(weeklyUsed + 0.5)]];
    return [NSString stringWithFormat:@"%@   %@", lower, [parts componentsJoinedByString:@" "]];
}

// Hauteur de la bande de titre. Doit rester alignée sur le `padding-top` de `.shell` dans
// dashboard.html, qui réserve la même zone côté contenu.
static const CGFloat TMTitleBarHeight = 28;

// La fenêtre est en FullSizeContentView avec une barre de titre transparente : la WKWebView couvre
// donc toute la surface, y compris la zone du titre, et consomme les événements souris — plus rien
// n'offre de prise pour déplacer la fenêtre. `-webkit-app-region: drag` ne comble pas ce manque :
// malgré son préfixe, c'est une extension Chromium que WebKit n'implémente pas. Cette bande
// transparente, posée par-dessus la webview, rend la prise à AppKit.
@interface TMTitleBarDragView : NSView
@end

@implementation TMTitleBarDragView
- (BOOL)mouseDownCanMoveWindow { return YES; }
// INSTRUMENTATION TEMPORAIRE — à retirer
// Le déplacement implicite (mouseDownCanMoveWindow) ne déclenche rien sur macOS 27 bêta alors que
// toute la chaîne est valide — vérifié : hitTest correct, movable=YES, styleMask complet, et le
// mouseDown arrive bien jusqu'ici. Le chemin explicite, lui, fonctionne : même mécanique que la
// barre de titre native, mais déclenchée par nous.
- (void)mouseDown:(NSEvent *)event {
    [self.window performWindowDragWithEvent:event];
}
@end

@interface TMAppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property NSWindow *window;
@property WKWebView *webView;
@property WKWebView *menuWebView;
@property WKWebView *usageWebView;
@property BOOL usageWebLoaded;
@property (copy) void (^usageWebLoadCompletion)(BOOL ok);
@property NSStatusItem *statusItem;
@property NSPopover *statusPopover;
@property BOOL webReady;
@property BOOL menuWebReady;
@property TMSystemMonitor *systemMonitor;
@property NSTimer *metricsTimer;
@property NSDictionary *previousProcessSample;
@property NSTimeInterval previousProcessAt;
@property NSArray *topProcesses;
@property BOOL processTickParity;
// États d'hystérésis des alertes système — un booléen par seuil surveillé.
@property BOOL alertRAMAbove, alertTempAbove, alertDiskAbove;
@property TMKeyboardLock *keyboardLock;
// Le cookie claude.ai, lu une seule fois au lancement. Le relire à chaque rafraîchissement
// déclenchait une demande d'accès au Trousseau à chaque fois — et comme le survol de l'icône
// ouvre le popover, donc rafraîchit, cela produisait plusieurs demandes par minute.
// Le secret ne change que quand l'utilisateur le change : on invalide le cache à ce moment-là.
@property (copy) NSString *usageCookieCache;
@property BOOL usageCookieLoaded;
@property BOOL directWasStale;      // front pour l'alerte de péremption (feature 1)
@property NSInteger directFailures; // compteur du chien de garde (feature 3)
@property id globalShortcutMonitor, localShortcutMonitor;
@property TMWindowManager *windowManager;
@property NSPanel *pickerPanel;
@property WKWebView *pickerWebView;
@property NSArray<TMWindowCandidate *> *pickerCandidates;
@property TMDuoSplit pickerSplit;
@property id pickerDismissObserver;
@property pid_t duoOriginPid;
@property id windowGlobalMonitor, windowLocalMonitor;
@property BOOL refreshing;
@property NSTimer *refreshTimer;
@property TMCodexAppServer *codexServer;
@property NSDictionary *openAIAccount;
@property NSString *openAILoginID;
@property NSDictionary *claudeAccount;
@property BOOL claudeActionRunning;
@property NSTrackingArea *hoverArea;
@property NSTimer *hoverOpenTimer;          // délai avant ouverture : évite le surgissement en traversant la barre
@property NSTimer *hoverCloseTimer;         // grâce à la sortie : laisse le temps d'entrer dans le popover
@property BOOL popoverOpenedByHover;        // un popover ouvert au clic ne doit pas se fermer tout seul
@property NSInteger consecutiveErrors;      // backoff: grows on failed polls, resets on success
@property NSDate *nextAllowedRefresh;       // backoff: automatic polls are skipped until this time
@property NSMutableDictionary *notifiedThresholds;  // "windowId@resetsAt" -> highest % already alerted
@property BOOL notificationsAuthorized;
@property TMAwake *awake;
@end

// Sans bordure, une fenêtre refuse d'être clé — canBecomeKeyWindow vaut NO par défaut. Le
// sélecteur vit du clavier : il doit donc le redéclarer explicitement.
@interface TMPickerPanel : NSPanel
@end
@implementation TMPickerPanel
- (BOOL)canBecomeKeyWindow { return YES; }
- (BOOL)canBecomeMainWindow { return NO; }  // il ne remplace pas la fenêtre principale de l'app
@end

@implementation TMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.awake = [TMAwake new];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        @"refreshIntervalMinutes": @5,
        // lowest | claude:session | claude:weekly | openai:weekly — quel % accompagne l'icône.
        // Claude semaine par défaut : c'est la limite qui contraint réellement le travail.
        @"menuBarMetric": @"claude:weekly",
        @"hoverPopover": @YES,
        // blueprint reste l'apparence historique : les utilisateurs existants ne voient aucun
        // changement tant qu'ils ne choisissent pas un autre thème dans Réglages.
        @"theme": @"blueprint"
    }];
    // Migration : les valeurs d'avant l'ajout du fournisseur ne correspondent plus à rien, et
    // laisseraient l'élément bloqué sur « -- » sans jamais dire pourquoi.
    NSDictionary *migrations = @{@"session": @"claude:session", @"weekly": @"claude:weekly"};
    NSString *stored = [defaults stringForKey:@"menuBarMetric"];
    if (migrations[stored]) [defaults setObject:migrations[stored] forKey:@"menuBarMetric"];
    self.openAIAccount = TMDisconnectedOpenAIAccount(@"");
    self.claudeAccount = TMEmptyClaudeAccount();
    self.notifiedThresholds = [NSMutableDictionary dictionary];
    self.codexServer = [TMCodexAppServer new];
    __weak typeof(self) weakSelf = self;
    self.codexServer.notificationHandler = ^(NSString *method, NSDictionary *params) {
        [weakSelf handleCodexNotification:method params:params];
    };
    [self buildWindow];
    [self buildStatusItem];
    [self scheduleRefresh];
    [self startSystemMonitor];
    self.keyboardLock = [TMKeyboardLock new];
    __weak typeof(self) weakLockSelf = self;
    self.keyboardLock.stateChanged = ^(TMLockState state) { [weakLockSelf pushData]; };
    [self installGlobalShortcut];
    [self installWindowShortcuts];
    [self requestNotificationAuthorization];
    [self observeWakeNotifications];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Re-seed sessionKey into the WebView store before the first poll. The store is persistent, so
    // this is usually a no-op; it matters on the first launch after the cookie is set, and after
    // anything clears the store.
    NSString *cookie = [self usageCookie];
    if (cookie.length) [self seedUsageCookies:cookie completion:^{ [self refresh:nil]; }];
    else [self refresh:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    self.awake.enabled = NO;  // l'assertion mourrait avec le processus, mais la relâcher est explicite
    [self.keyboardLock forceUnlock];
    [self removeGlobalShortcut];
    [self removeWindowShortcuts];  // même logique : le tap mourrait aussi, mais soyons explicites
    [self.metricsTimer invalidate];
    [self.codexServer stop];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
}

- (void)requestNotificationAuthorization {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{ self.notificationsAuthorized = granted; });
    }];
}

// A machine waking from sleep has almost certainly gone stale; refresh at once rather than waiting
// out the remainder of the 5-minute timer.
- (void)observeWakeNotifications {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(systemDidWake:)
                                                          name:NSWorkspaceDidWakeNotification object:nil];
}

- (void)systemDidWake:(NSNotification *)notification {
    [self refresh:nil];  // automatic: if the endpoint was failing before sleep, keep honouring the backoff
}

- (void)buildWindow {
    NSRect frame = NSMakeRect(0, 0, 1180, 760);
    NSWindowStyleMask style = NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskMiniaturizable | NSWindowStyleMaskResizable | NSWindowStyleMaskFullSizeContentView;
    self.window = [[NSWindow alloc] initWithContentRect:frame styleMask:style backing:NSBackingStoreBuffered defer:NO];
    // Par défaut, une NSWindow créée par programme se libère à sa fermeture — alors que cette
    // propriété forte continue de la pointer. Le bouton rouge laissait donc un pointeur mort, que
    // metricsTick déréférençait à la seconde suivante en lisant window.isVisible. Ici l'app
    // survit à la fermeture de sa fenêtre (applicationShouldTerminateAfterLastWindowClosed = NO)
    // et la rouvre depuis le popover : c'est nous qui gérons son cycle de vie, pas AppKit.
    self.window.releasedWhenClosed = NO;
    self.window.title = @"Status";
    self.window.titleVisibility = NSWindowTitleHidden;
    self.window.titlebarAppearsTransparent = YES;
    self.window.minSize = NSMakeSize(940, 640);
    [self.window center];

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration.userContentController addScriptMessageHandler:self name:@"native"];
    self.webView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.underPageBackgroundColor = NSColor.clearColor;
    self.webView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;

    // La bande doit rester au-dessus de la webview dans l'ordre des sous-vues, sinon la webview
    // récupère le clic et la fenêtre redevient fixe.
    NSView *content = [[NSView alloc] initWithFrame:frame];
    [content addSubview:self.webView];
    TMTitleBarDragView *titleBar = [[TMTitleBarDragView alloc]
        initWithFrame:NSMakeRect(0, NSHeight(frame) - TMTitleBarHeight, NSWidth(frame), TMTitleBarHeight)];
    titleBar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;  // collée en haut au redimensionnement
    [content addSubview:titleBar];
    self.window.contentView = content;

    NSURL *url = [NSBundle.mainBundle URLForResource:@"dashboard" withExtension:@"html"];
    [self.webView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
}

- (void)buildStatusItem {
    // Variable, not square: the item carries a percentage next to the icon, so it must be free to
    // grow and shrink with the text.
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    // L'icône n'est pas posée ici : updateStatusMenu la redessine à chaque cycle, puisqu'elle
    // représente la valeur courante. Un tiret le temps de la première lecture.
    self.statusItem.button.image = TMGaugeIcon(0, NO, TMSeverityNormal, nil);
    self.statusItem.button.imagePosition = NSImageLeading;
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(toggleStatusPopover:);
    [self installHoverTracking];

    NSRect frame = NSMakeRect(0, 0, 400, 500);
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration.userContentController addScriptMessageHandler:self name:@"native"];
    self.menuWebView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    self.menuWebView.navigationDelegate = self;
    self.menuWebView.underPageBackgroundColor = NSColor.clearColor;
    self.menuWebView.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"menubar" withExtension:@"html"];
    [self.menuWebView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];

    NSViewController *controller = [NSViewController new];
    controller.view = self.menuWebView;
    controller.preferredContentSize = frame.size;
    self.statusPopover = [NSPopover new];
    self.statusPopover.behavior = NSPopoverBehaviorTransient;
    self.statusPopover.animates = YES;
    self.statusPopover.contentSize = frame.size;
    self.statusPopover.contentViewController = controller;
    [self updateStatusMenu];
}

#pragma mark - Session claude.ai (WebView)

// claude.ai sits behind Cloudflare, whose challenge is a JavaScript proof of work: a plain
// NSURLSession request gets a 403 "Just a moment…" page no matter which headers it sends, and the
// cf_clearance cookie is bound to both IP and User-Agent and expires within hours. Only a real
// WebKit context can pass and keep passing — it runs the challenge and re-earns cf_clearance on its
// own. The pasted cookie is therefore only a seed for sessionKey; WebKit owns the rest.
- (WKWebView *)ensureUsageWebView {
    if (self.usageWebView) return self.usageWebView;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    // Persistent store: the session (and cf_clearance) survives app relaunches and reboots.
    configuration.websiteDataStore = [WKWebsiteDataStore defaultDataStore];
    self.usageWebView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768) configuration:configuration];
    self.usageWebView.navigationDelegate = self;
    return self.usageWebView;
}

// Rechargement dur de la WebView usage : on repart de la session stockée dans le Trousseau et on
// force un rechargement complet. Utile quand un défi Cloudflare persistant a laissé la WebView
// coincée hors de la vraie page — plutôt qu'attendre un rétablissement qui peut ne pas venir.
- (void)hardReloadUsageWebView {
    NSString *cookie = [self usageCookie];
    if (!cookie.length) return;
    self.usageWebLoaded = NO;
    self.usageWebLoadCompletion = nil;  // abandonne un chargement en cours éventuellement bloqué
    [self seedUsageCookies:cookie completion:^{ [self refresh:nil]; }];
}

- (void)seedUsageCookies:(NSString *)cookieHeader completion:(void (^)(void))completion {
    WKHTTPCookieStore *store = [self ensureUsageWebView].configuration.websiteDataStore.httpCookieStore;
    NSArray<NSHTTPCookie *> *cookies = TMCookiesFromHeader(cookieHeader);
    if (!cookies.count) { if (completion) completion(); return; }
    __block NSUInteger remaining = cookies.count;
    for (NSHTTPCookie *cookie in cookies) {
        [store setCookie:cookie completionHandler:^{
            if (--remaining == 0) {
                self.usageWebLoaded = NO;  // force a reload so the new session takes effect
                if (completion) completion();
            }
        }];
    }
}

- (void)ensureUsageWebViewLoaded:(void (^)(BOOL ok))completion {
    if (self.usageWebLoaded) { completion(YES); return; }
    if (self.usageWebLoadCompletion) { completion(NO); return; }  // a load is already in flight
    self.usageWebLoadCompletion = completion;
    WKWebView *webView = [self ensureUsageWebView];
    [webView loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]]];
    // Cloudflare interpose parfois un défi qui se résout par une redirection JavaScript que WebKit
    // ne signale pas toujours comme une nouvelle navigation : se fier au seul didFinishNavigation
    // laissait l'app bloquée après un redémarrage, quand la réputation IP force un défi persistant.
    // On sonde donc le titre activement, jusqu'à sortir de l'interstitiel ou expirer.
    [self pollUsageWebViewReadyWithDeadline:[NSDate dateWithTimeIntervalSinceNow:25]];
}

- (void)pollUsageWebViewReadyWithDeadline:(NSDate *)deadline {
    void (^pending)(BOOL) = self.usageWebLoadCompletion;
    if (!pending) return;  // déjà résolu par didFinishNavigation ou une sonde antérieure
    if ([deadline timeIntervalSinceNow] <= 0) {
        self.usageWebLoadCompletion = nil;
        pending(NO);
        return;
    }
    [self.usageWebView evaluateJavaScript:@"document.title" completionHandler:^(id title, NSError *error) {
        if (!self.usageWebLoadCompletion) return;  // résolu entre-temps
        BOOL challenging = [title isKindOfClass:NSString.class] && [(NSString *)title containsString:@"Just a moment"];
        BOOL loaded = [title isKindOfClass:NSString.class] && [(NSString *)title length] && !challenging;
        if (loaded) {
            self.usageWebLoaded = YES;
            void (^done)(BOOL) = self.usageWebLoadCompletion;
            self.usageWebLoadCompletion = nil;
            done(YES);
            return;
        }
        // Toujours sur le défi (ou page vide) : réessayer dans une seconde jusqu'à l'échéance.
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pollUsageWebViewReadyWithDeadline:deadline];
        });
    }];
}

- (void)fetchClaudeUsageViaWeb:(NSString *)orgId completion:(void (^)(NSDictionary *json, NSError *error))completion {
    [self ensureUsageWebViewLoaded:^(BOOL ok) {
        if (!ok) {
            completion(nil, TMError(@"Impossible de charger la session claude.ai. Recollez le cookie depuis « direct »."));
            return;
        }
        NSString *script = @"const r = await fetch(`/api/organizations/${orgId}/usage`, "
                            "{credentials:'include', headers:{'Accept':'application/json'}}); "
                            "if (!r.ok) throw new Error('HTTP ' + r.status); return await r.text();";
        [self.usageWebView callAsyncJavaScript:script
                                     arguments:@{@"orgId": orgId}
                                       inFrame:nil
                                inContentWorld:WKContentWorld.pageWorld
                             completionHandler:^(id result, NSError *error) {
            if (error || ![result isKindOfClass:NSString.class]) {
                // A stale session drops us back to the login page, where the fetch 401s/403s.
                self.usageWebLoaded = NO;
                completion(nil, TMError(@"Session claude.ai expirée. Recollez le cookie depuis « direct »."));
                return;
            }
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            NSDictionary *json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (![json isKindOfClass:NSDictionary.class]) {
                self.usageWebLoaded = NO;
                completion(nil, TMError(@"Réponse claude.ai illisible (challenge Cloudflare ?)."));
                return;
            }
            completion(json, nil);
        }];
    }];
}

// Cherche une fenêtre précise chez un fournisseur précis. Les métriques épinglées doivent viser
// « Claude semaine » et non « la semaine la plus chargée des deux » : agréger les fournisseurs
// rendrait l'épinglage inopérant dès qu'OpenAI dépasse Claude.
- (BOOL)usedPercentIn:(NSArray *)windows matching:(BOOL (^)(NSDictionary *))predicate out:(double *)out {
    return TMMaxUsedPercent(@[windows ?: @[]], predicate, out);
}

// Série récente de la fenêtre épinglée, pour la sparkline de la barre des menus (feature 9).
// Métriques système : depuis les anneaux du moniteur. Quotas : depuis l'historique horodaté, en
// prenant par point le max des clés concernées — ce qui reflète exactement la valeur affichée
// (openai:weekly et « lowest » retiennent déjà le maximum). Les ~24 derniers points suffisent à
// une tendance lisible dans 26 px.
- (NSArray<NSNumber *> *)menuBarSeriesForMetric:(NSString *)metric {
    if ([metric hasPrefix:@"system:"]) {
        NSString *fam = [metric isEqualToString:@"system:temp"] ? @"sensors" : @"cpu";
        NSString *key = [metric isEqualToString:@"system:temp"] ? @"tempC" : @"total";
        for (NSDictionary *family in [self.systemMonitor snapshot][@"families"]) {
            if ([family[@"id"] isEqualToString:fam]) {
                NSArray *series = family[@"series"][key];
                return [series isKindOfClass:NSArray.class] ? series : @[];
            }
        }
        return @[];
    }

    BOOL (^matches)(NSString *) = ^BOOL(NSString *key) {
        if ([metric isEqualToString:@"claude:session"]) return [key isEqualToString:@"claude:five_hour"];
        if ([metric isEqualToString:@"claude:weekly"])  return [key isEqualToString:@"claude:seven_day"];
        if ([metric isEqualToString:@"openai:weekly"])  return [key hasPrefix:@"openai:"];
        return YES;  // « lowest » : toutes les fenêtres, on garde le max par point
    };

    NSArray *history = TMLoadHistory();
    NSMutableArray<NSNumber *> *series = [NSMutableArray array];
    for (NSDictionary *row in history) {
        NSDictionary *points = [row[@"p"] isKindOfClass:NSDictionary.class] ? row[@"p"] : nil;
        if (!points) continue;
        double best = -1;
        for (NSString *key in points) if (matches(key)) best = MAX(best, TMNumber(points[key]));
        if (best >= 0) [series addObject:@(best)];
    }
    NSUInteger keep = 24;
    if (series.count > keep) [series removeObjectsInRange:NSMakeRange(0, series.count - keep)];
    return series;
}

- (void)updateStatusMenu {
    NSArray *claudeWindows = self.claudeAccount[@"windows"] ?: @[];
    NSArray *openAIWindows = self.openAIAccount[@"windows"] ?: @[];

    double claudeSession = 0, claudeWeekly = 0, openAIWeekly = 0;
    BOOL hasClaudeSession = [self usedPercentIn:claudeWindows matching:^BOOL(NSDictionary *w) { return TMWindowIsSession(w); } out:&claudeSession];
    BOOL hasClaudeWeekly = [self usedPercentIn:claudeWindows matching:^BOOL(NSDictionary *w) { return TMWindowIsWeekly(w); } out:&claudeWeekly];
    BOOL hasOpenAIWeekly = [self usedPercentIn:openAIWindows matching:^BOOL(NSDictionary *w) { return TMWindowIsWeekly(w); } out:&openAIWeekly];

    // Infobulle : le détail complet, quel que soit le chiffre épinglé.
    NSMutableArray<NSString *> *lines = [NSMutableArray array];
    if (hasClaudeSession) [lines addObject:[NSString stringWithFormat:@"Claude · 5 h : %ld %% consommé", (long)(claudeSession + 0.5)]];
    if (hasClaudeWeekly) [lines addObject:[NSString stringWithFormat:@"Claude · semaine : %ld %% consommé", (long)(claudeWeekly + 0.5)]];
    if (hasOpenAIWeekly) [lines addObject:[NSString stringWithFormat:@"OpenAI · semaine : %ld %% consommé", (long)(openAIWeekly + 0.5)]];
    self.statusItem.button.toolTip = lines.count
        ? [lines componentsJoinedByString:@"\n"]
        : @"Status · Connectez un compte pour voir vos quotas";

    // Une seule fenêtre pilote l'élément : celle que l'utilisateur a épinglée, ou la plus contrainte
    // par défaut. Le libellé n'apparaît qu'en mode « lowest », où la fenêtre montrée change toute
    // seule et doit donc se nommer ; épinglée, elle est déjà connue — autant rendre l'espace à la
    // barre des menus.
    NSString *metric = [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly";
    double shown = 0;
    BOOL hasValue = NO;
    NSString *label = nil;
    NSColor *providerInk = nil;  // nil ⇒ template : rien à identifier

    if ([metric isEqualToString:@"claude:session"]) {
        hasValue = hasClaudeSession; shown = claudeSession; providerInk = TM_INK_CLAUDE;
    } else if ([metric isEqualToString:@"claude:weekly"]) {
        hasValue = hasClaudeWeekly; shown = claudeWeekly; providerInk = TM_INK_CLAUDE;
    } else if ([metric isEqualToString:@"openai:weekly"]) {
        hasValue = hasOpenAIWeekly; shown = openAIWeekly; providerInk = TM_INK_OPENAI;
    } else if ([metric hasPrefix:@"system:"]) {
        // Métriques système : mêmes valeurs que l'onglet Moniteur, rafraîchies par metricsTick.
        NSMutableDictionary *nowById = [NSMutableDictionary dictionary];
        for (NSDictionary *family in [self.systemMonitor snapshot][@"families"]) nowById[family[@"id"]] = family[@"now"];
        NSNumber *value = [metric isEqualToString:@"system:temp"] ? nowById[@"sensors"][@"tempC"] : nowById[@"cpu"][@"total"];
        hasValue = value != nil; shown = value.doubleValue;
        label = [metric isEqualToString:@"system:temp"] ? @"temp" : @"cpu";
    } else {
        // « lowest » = la marge la plus faible, donc le pourcentage consommé le plus élevé.
        // La couleur suit la fenêtre gagnante : elle change avec elle, ce qui est précisément
        // l'information que ce mode doit transmettre.
        NSArray *candidates = @[
            @[@(hasClaudeSession), @(claudeSession), @"C 5h", TM_INK_CLAUDE],
            @[@(hasClaudeWeekly), @(claudeWeekly), @"C sem", TM_INK_CLAUDE],
            @[@(hasOpenAIWeekly), @(openAIWeekly), @"AI sem", TM_INK_OPENAI],
        ];
        for (NSArray *candidate in candidates) {
            if (![candidate[0] boolValue]) continue;
            double value = [candidate[1] doubleValue];
            if (!hasValue || value > shown) {
                hasValue = YES; shown = value; label = candidate[2]; providerInk = candidate[3];
            }
        }
    }

    // Les seuils d'alerte sont ceux d'un quota, pas d'une machine : un CPU à 85 % est un CPU qui
    // travaille, pas une urgence. Les vraies alertes système passent par les notifications, avec
    // leurs propres seuils. Colorer l'icône en ambre ici crierait au loup en permanence.
    BOOL isQuotaMetric = ![metric hasPrefix:@"system:"];
    TMSeverity severity = (hasValue && isQuotaMetric) ? TMSeverityForPercent(shown) : TMSeverityNormal;
    if (!hasValue) providerInk = nil;  // le tiret « pas de donnée » n'identifie personne
    NSString *suffix = [metric isEqualToString:@"system:temp"] ? @"°" : @"%";
    NSString *title = hasValue
        ? [NSString stringWithFormat:@" %@%ld%@", label ? [label stringByAppendingString:@" "] : @"", (long)(shown + 0.5), suffix]
        : @" --";

    BOOL sparkStyle = [[NSUserDefaults.standardUserDefaults stringForKey:@"menuBarIconStyle"] isEqualToString:@"spark"];
    self.statusItem.button.image = sparkStyle
        ? TMSparklineIcon([self menuBarSeriesForMetric:metric], hasValue, severity, providerInk)
        : TMGaugeIcon(shown / 100.0, hasValue, severity, providerInk);
    self.statusItem.button.image.accessibilityDescription = hasValue
        ? [NSString stringWithFormat:@"Quota %ld %% consommé", (long)(shown + 0.5)]
        : @"Quota indisponible";
    self.statusItem.button.attributedTitle = TMMenuBarTitle(title, severity);
}

#pragma mark - Aperçu au survol

// Les chiffres apparaissent au survol, sans clic. Deux délais rendent la chose vivable :
//   — ouverture différée, sinon le popover surgit à chaque traversée de la barre des menus ;
//   — fermeture différée, sinon il se referme dans le trajet entre l'icône et le popover.
- (void)installHoverTracking {
    NSButton *button = self.statusItem.button;
    if (self.hoverArea) [button removeTrackingArea:self.hoverArea];
    self.hoverArea = [[NSTrackingArea alloc] initWithRect:button.bounds
                                                  options:(NSTrackingMouseEnteredAndExited | NSTrackingActiveAlways | NSTrackingInVisibleRect)
                                                    owner:self userInfo:nil];
    [button addTrackingArea:self.hoverArea];
}

- (BOOL)hoverPopoverEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"hoverPopover"];
}

- (void)mouseEntered:(NSEvent *)event {
    if (![self hoverPopoverEnabled]) return;
    [self.hoverCloseTimer invalidate];
    self.hoverCloseTimer = nil;
    if (self.statusPopover.shown) return;
    [self.hoverOpenTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.hoverOpenTimer = [NSTimer scheduledTimerWithTimeInterval:0.45 repeats:NO block:^(NSTimer *timer) {
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.statusPopover.shown) return;
        strongSelf.popoverOpenedByHover = YES;
        [strongSelf showStatusPopover];
    }];
}

- (void)mouseExited:(NSEvent *)event {
    [self.hoverOpenTimer invalidate];
    self.hoverOpenTimer = nil;
    if (!self.statusPopover.shown || !self.popoverOpenedByHover) return;
    [self.hoverCloseTimer invalidate];
    __weak typeof(self) weakSelf = self;
    self.hoverCloseTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
        [weakSelf closePopoverIfMouseAway];
    }];
}

// Ne ferme que si la souris a vraiment quitté l'ensemble icône + popover : sans cela, survoler le
// popover pour lire les chiffres le ferait disparaître sous le curseur.
- (void)closePopoverIfMouseAway {
    if (!self.statusPopover.shown || !self.popoverOpenedByHover) return;
    NSPoint mouse = NSEvent.mouseLocation;
    NSWindow *popoverWindow = self.statusPopover.contentViewController.view.window;
    if (popoverWindow && NSPointInRect(mouse, popoverWindow.frame)) {
        // Toujours dedans : on repasse plus tard plutôt que de fermer sous le curseur.
        __weak typeof(self) weakSelf = self;
        self.hoverCloseTimer = [NSTimer scheduledTimerWithTimeInterval:0.35 repeats:NO block:^(NSTimer *timer) {
            [weakSelf closePopoverIfMouseAway];
        }];
        return;
    }
    NSWindow *buttonWindow = self.statusItem.button.window;
    if (buttonWindow && NSPointInRect(mouse, buttonWindow.frame)) return;  // mouseEntered reprendra la main
    self.popoverOpenedByHover = NO;
    [self.statusPopover close];
}

- (void)showStatusPopover {
    [self.statusPopover showRelativeToRect:self.statusItem.button.bounds
                                    ofView:self.statusItem.button preferredEdge:NSRectEdgeMinY];
    [self refresh:nil];
}

// Raccourci global ⌘⇧S — atteindre les quotas sans viser l'icône à la souris.
//
// Deux moniteurs sont nécessaires et non un seul : le global ne reçoit rien quand Status est
// déjà l'application active (macOS ne livre pas à une app ses propres événements par ce canal),
// le local ne reçoit que ceux-là. Ensemble ils couvrent les deux cas.
//
// Le moniteur global exige l'autorisation d'Accessibilité — la même que le verrou clavier. Sans
// elle, l'enregistrement échoue silencieusement : c'est pourquoi le réglage indique l'état
// plutôt que de promettre un raccourci qui ne viendrait jamais.
- (void)installGlobalShortcut {
    [self removeGlobalShortcut];
    if (![NSUserDefaults.standardUserDefaults boolForKey:@"globalShortcutEnabled"]) return;

    __weak typeof(self) weakSelf = self;
    BOOL (^matches)(NSEvent *) = ^BOOL(NSEvent *event) {
        NSEventModifierFlags flags = event.modifierFlags & NSEventModifierFlagDeviceIndependentFlagsMask;
        return (flags == (NSEventModifierFlagCommand | NSEventModifierFlagShift))
            && [event.charactersIgnoringModifiers.lowercaseString isEqualToString:@"s"];
    };
    self.globalShortcutMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                       handler:^(NSEvent *event) {
        if (matches(event)) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf toggleStatusPopover:nil]; });
    }];
    self.localShortcutMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                      handler:^NSEvent *(NSEvent *event) {
        if (!matches(event)) return event;
        [weakSelf toggleStatusPopover:nil];
        return nil;  // consommé : ne pas le laisser filer vers la webview
    }];
}

- (void)removeGlobalShortcut {
    if (self.globalShortcutMonitor) { [NSEvent removeMonitor:self.globalShortcutMonitor]; self.globalShortcutMonitor = nil; }
    if (self.localShortcutMonitor) { [NSEvent removeMonitor:self.localShortcutMonitor]; self.localShortcutMonitor = nil; }
}

#pragma mark - Gestionnaire de fenêtres

// Table des raccourcis : modificateurs exacts + touche, vers une action. Les modificateurs sont
// comparés à l'identique et non par masquage — ⌃⌥← et ⌃⌥⇧← doivent rester distincts.
static const NSEventModifierFlags TMModCtrlAltShift = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagShift;
static const NSEventModifierFlags TMModCtrlAltCmd = NSEventModifierFlagControl | NSEventModifierFlagOption | NSEventModifierFlagCommand;

// Codes de touches virtuels : les flèches et Entrée n'ont pas de caractère exploitable dans
// charactersIgnoringModifiers une fois les modificateurs appliqués.
enum { TMKeyReturn = 36, TMKeyLeft = 123, TMKeyRight = 124, TMKeyDown = 125, TMKeyUp = 126,
       TMKeyY = 16, TMKeyO = 31, TMKeyU = 32, TMKeyI = 34, TMKeyL = 37, TMKeyJ = 38, TMKeyK = 40 };

- (BOOL)windowManagerEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"windowManagerEnabled"];
}

// Retourne l'identifiant de disposition pour un événement, ou nil si aucun raccourci ne
// correspond. Séparé de l'exécution pour rester lisible et pour que les deux moniteurs
// (global et local) partagent exactement la même table.
- (NSString *)windowActionForEvent:(NSEvent *)event {
    // Masquer sur les seuls modificateurs d'intention. Les touches fléchées activent aussi
    // Function et NumericPad — vérifié : flags=0xae0000 sur ⌃⌥⇧→ — et une comparaison stricte
    // avec DeviceIndependentFlagsMask ne correspondait donc jamais. CapsLock est écarté pour la
    // même raison.
    const NSEventModifierFlags intent = NSEventModifierFlagControl | NSEventModifierFlagOption
                                      | NSEventModifierFlagShift | NSEventModifierFlagCommand;
    NSEventModifierFlags flags = event.modifierFlags & intent;
    unsigned short key = event.keyCode;

    // Base ⌃⌥⇧ et non ⌃⌥ : macOS 15+ s'est approprié ⌃⌥ + flèches pour son propre pavage.
    // Vérifié empiriquement, Status éteint — ⌃⌥← déplaçait la fenêtre sans nous. Toute la série
    // ⌃⌥⇧ a été testée libre, de même que ⌃⌥⌘ réservé aux changements d'écran.
    if (flags == TMModCtrlAltShift) {
        if (key == TMKeyLeft)   return @"left-half";
        if (key == TMKeyRight)  return @"right-half";
        if (key == TMKeyUp)     return @"maximize";
        if (key == TMKeyDown)   return @"center";
        if (key == TMKeyU)      return @"left-two-thirds";
        if (key == TMKeyI)      return @"right-two-thirds";
        if (key == TMKeyJ)      return @"left-third";
        if (key == TMKeyK)      return @"center-third";
        if (key == TMKeyL)      return @"right-third";
        if (key == TMKeyY)      return @"left-three-quarters";
        if (key == TMKeyO)      return @"right-three-quarters";
    } else if (flags == TMModCtrlAltCmd) {
        if (key == TMKeyRight) return @"screen-next";
        if (key == TMKeyLeft)  return @"screen-prev";
        if (key == TMKeyU)     return @"duo-half";
        if (key == TMKeyI)     return @"duo-two-thirds";
        if (key == TMKeyO)     return @"duo-third";
    }
    return nil;
}

- (void)performWindowAction:(NSString *)action {
    TMDuoSplit split;
    if (TMDuoSplitFromIdentifier(action, &split)) {
        // Mémoriser d'où l'on vient : ouvrir le panneau donne le focus à Status, et « la fenêtre
        // active » ne doit pas devenir la nôtre.
        // Même garde-fou que pour le placement simple : si c'est Status qui a le focus, il n'y a
        // pas de « fenêtre active » à apparier — mieux vaut ne rien faire que de se paver soi-même.
        pid_t origin = NSWorkspace.sharedWorkspace.frontmostApplication.processIdentifier;
        if (origin == NSRunningApplication.currentApplication.processIdentifier) return;
        self.duoOriginPid = origin;
        [self openPickerForSplit:split];
        return;
    }
    if ([action isEqualToString:@"screen-next"]) { [self.windowManager moveToAdjacentScreen:YES]; return; }
    if ([action isEqualToString:@"screen-prev"]) { [self.windowManager moveToAdjacentScreen:NO]; return; }
    TMWindowLayout layout;
    if (TMWindowLayoutFromIdentifier(action, &layout)) [self.windowManager applyLayout:layout];
}

// Même mécanique que le raccourci du popover, et pour les mêmes raisons : le moniteur global ne
// reçoit rien quand Status est l'app active, le local ne reçoit que ces cas-là.
- (void)installWindowShortcuts {
    [self removeWindowShortcuts];
    if (!self.windowManager) self.windowManager = [TMWindowManager new];
    if (![self windowManagerEnabled]) return;

    __weak typeof(self) weakSelf = self;
    self.windowGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                      handler:^(NSEvent *event) {
        NSString *action = [weakSelf windowActionForEvent:event];
        if (action) dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf performWindowAction:action]; });
    }];
    self.windowLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskKeyDown
                                                                    handler:^NSEvent *(NSEvent *event) {
        NSString *action = [weakSelf windowActionForEvent:event];
        if (!action) return event;
        [weakSelf performWindowAction:action];
        return nil;  // consommé : ne pas le laisser filer vers la webview
    }];
}

- (void)removeWindowShortcuts {
    if (self.windowGlobalMonitor) { [NSEvent removeMonitor:self.windowGlobalMonitor]; self.windowGlobalMonitor = nil; }
    if (self.windowLocalMonitor) { [NSEvent removeMonitor:self.windowLocalMonitor]; self.windowLocalMonitor = nil; }
}

#pragma mark - Sélecteur de duo

// Panneau flottant portant une WKWebView : le sélecteur hérite ainsi de themes.css et suit le
// thème choisi sans une ligne de CSS dupliquée.
- (void)buildPickerIfNeeded {
    if (self.pickerPanel) return;
    NSRect frame = NSMakeRect(0, 0, 520, 400);
    // Pas de NonactivatingPanel : ce style empêche justement la prise de focus clavier, et le
    // sélecteur ne vit que du clavier. Vérifié — avec lui, isKeyWindow restait à 0.
    self.pickerPanel = [[TMPickerPanel alloc] initWithContentRect:frame
                                                        styleMask:NSWindowStyleMaskBorderless
                                                          backing:NSBackingStoreBuffered defer:NO];
    self.pickerPanel.releasedWhenClosed = NO;  // même piège que la fenêtre principale
    self.pickerPanel.level = NSFloatingWindowLevel;
    self.pickerPanel.opaque = NO;
    self.pickerPanel.backgroundColor = NSColor.clearColor;
    self.pickerPanel.hidesOnDeactivate = NO;

    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration.userContentController addScriptMessageHandler:self name:@"native"];
    self.pickerWebView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    self.pickerWebView.navigationDelegate = self;
    self.pickerWebView.underPageBackgroundColor = NSColor.clearColor;
    self.pickerPanel.contentView = self.pickerWebView;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"picker" withExtension:@"html"];
    [self.pickerWebView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
}

- (void)openPickerForSplit:(TMDuoSplit)split {
    NSArray<TMWindowCandidate *> *candidates = [self.windowManager candidatesForDuo];
    if (!candidates.count) return;  // rien à choisir : ne pas ouvrir un panneau vide

    [self buildPickerIfNeeded];
    self.pickerCandidates = candidates;
    self.pickerSplit = split;

    NSMutableArray *payload = [NSMutableArray array];
    for (TMWindowCandidate *candidate in candidates) {
        [payload addObject:@{ @"appName": candidate.appName ?: @"", @"title": candidate.title ?: @"" }];
    }
    NSString *splitId = split == TMDuoActiveTwoThirds ? @"duo-two-thirds"
                      : split == TMDuoActiveThird ? @"duo-third" : @"duo-half";
    NSDictionary *data = @{ @"windows": payload, @"split": splitId,
                            @"activeApp": NSWorkspace.sharedWorkspace.frontmostApplication.localizedName ?: @"" };
    NSData *json = [NSJSONSerialization dataWithJSONObject:data options:0 error:nil];
    NSString *script = [NSString stringWithFormat:@"window.StatusPicker && window.StatusPicker.open(%@);",
                        [[NSString alloc] initWithData:json encoding:NSUTF8StringEncoding]];

    // Le thème suit celui du tableau de bord.
    NSString *theme = [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"blueprint";
    [self.pickerWebView evaluateJavaScript:
        [NSString stringWithFormat:@"document.documentElement.setAttribute('data-theme','%@');", theme]
                         completionHandler:nil];
    [self.pickerWebView evaluateJavaScript:script completionHandler:nil];

    NSScreen *screen = NSScreen.mainScreen;
    NSRect visible = screen.visibleFrame;
    [self.pickerPanel setFrameOrigin:NSMakePoint(NSMidX(visible) - 260, NSMidY(visible) - 200)];
    // Activer l'app AVANT de demander la fenêtre clé : tant que l'application n'est pas active,
    // makeKeyAndOrderFront: ordonne devant sans jamais donner le focus clavier.
    [NSApp activateIgnoringOtherApps:YES];
    [self.pickerPanel makeKeyAndOrderFront:nil];
    [self.pickerPanel makeFirstResponder:self.pickerWebView];

    // Le panneau ne survit pas à un changement d'application — mais on écoute la désactivation
    // de l'app, pas la perte de fenêtre clé : cette dernière se produit pendant la séquence
    // d'activation elle-même et refermait le panneau 0,4 s après l'avoir ouvert.
    __weak typeof(self) weakSelf = self;
    if (!self.pickerDismissObserver) {
        self.pickerDismissObserver = [NSNotificationCenter.defaultCenter
            addObserverForName:NSApplicationDidResignActiveNotification object:nil queue:nil
                    usingBlock:^(NSNotification *note) { [weakSelf closePicker]; }];
    }
}

- (void)closePicker {
    [self.pickerPanel orderOut:nil];
    self.pickerCandidates = nil;
}

// La fenêtre active est celle d'avant l'ouverture du panneau : il faut donc rendre le focus à
// l'application précédente avant de placer quoi que ce soit, sinon « l'active » serait Status.
- (void)completeDuoWithIndex:(NSInteger)index {
    if (index < 0 || index >= (NSInteger)self.pickerCandidates.count) { [self closePicker]; return; }
    TMWindowCandidate *partner = self.pickerCandidates[index];
    TMDuoSplit split = self.pickerSplit;
    [self closePicker];

    for (NSRunningApplication *app in NSWorkspace.sharedWorkspace.runningApplications) {
        if (app.processIdentifier == self.duoOriginPid) { [app activateWithOptions:0]; break; }
    }
    // Laisser l'activation aboutir avant de lire la fenêtre focalisée.
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.windowManager applyDuo:split withPartner:partner];
    });
}

- (void)toggleStatusPopover:(id)sender {
    (void)sender;
    [self.hoverOpenTimer invalidate];
    self.hoverOpenTimer = nil;
    // Un clic transforme un aperçu survolé en popover épinglé : il ne doit plus se fermer tout seul.
    if (self.statusPopover.shown && self.popoverOpenedByHover) {
        self.popoverOpenedByHover = NO;
        return;
    }
    if (self.statusPopover.shown) {
        [self.statusPopover close];
        return;
    }
    [self showStatusPopover];
}

- (void)openDashboard:(id)sender {
    [self.statusPopover close];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    if (webView == self.usageWebView) {
        // Cloudflare's challenge page finishes loading too, then redirects to the real page. Only
        // treat the load as usable once we are off the interstitial.
        [webView evaluateJavaScript:@"document.title" completionHandler:^(id title, NSError *error) {
            BOOL challenging = [title isKindOfClass:NSString.class] && [(NSString *)title containsString:@"Just a moment"];
            if (challenging) return;  // a further didFinishNavigation will arrive once solved
            self.usageWebLoaded = YES;
            void (^pending)(BOOL) = self.usageWebLoadCompletion;
            if (!pending) return;
            self.usageWebLoadCompletion = nil;
            pending(YES);
        }];
        return;
    }
    if (webView == self.menuWebView) self.menuWebReady = YES;
    else self.webReady = YES;
    [self pushData];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *action = body ? body[@"action"] : message.body;
    if ([action isEqualToString:@"refresh"]) [self refresh:self];  // explicit click: bypass backoff
    if ([action isEqualToString:@"toggleLaunchAtLogin"]) [self toggleLaunchAtLogin];
    if ([action isEqualToString:@"toggleHoverPopover"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![self hoverPopoverEnabled] forKey:@"hoverPopover"];
        [self pushData];
    }
    if ([action isEqualToString:@"setMenuBarMetric"]) {
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"lowest";
        [NSUserDefaults.standardUserDefaults setObject:value forKey:@"menuBarMetric"];
        [self pushData];
    }
    if ([action isEqualToString:@"setTheme"]) {
        // Entrée non fiable (vient de la webview) : seuls les six identifiants de themes.css
        // sont acceptés, sinon un thème mal orthographié figerait l'app sur les jetons par
        // défaut de :root sans jamais le dire.
        static NSSet<NSString *> *validThemes;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            validThemes = [NSSet setWithArray:@[@"blueprint", @"phosphore", @"synthwave", @"circuit", @"holograme", @"ion"]];
        });
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"";
        if ([validThemes containsObject:value]) {
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"theme"];
            [self pushData];
        }
    }
    if ([action isEqualToString:@"toggleKeyboardLock"]) {
        [self.statusPopover close];  // l'overlay va tout recouvrir ; un popover transient resterait orphelin
        [self.keyboardLock toggle];
    }
    if ([action isEqualToString:@"toggleGlobalShortcut"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"globalShortcutEnabled"] forKey:@"globalShortcutEnabled"];
        [self installGlobalShortcut];
        [self pushData];
    }
    if ([action isEqualToString:@"duoPick"]) [self completeDuoWithIndex:[body[@"index"] integerValue]];
    if ([action isEqualToString:@"duoCancel"]) [self closePicker];
    if ([action isEqualToString:@"exportHistoryCSV"]) [self exportHistoryCSV];
    if ([action isEqualToString:@"setMenuBarIconStyle"]) {
        [NSUserDefaults.standardUserDefaults setObject:body[@"value"] forKey:@"menuBarIconStyle"];
        [self updateStatusMenu];
    }
    if ([action isEqualToString:@"toggleWindowManager"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"windowManagerEnabled"] forKey:@"windowManagerEnabled"];
        [self installWindowShortcuts];
        [self pushData];
    }
    if ([action isEqualToString:@"setWindowGap"]) {
        NSString *which = [body[@"which"] isKindOfClass:NSString.class] ? body[@"which"] : @"between";
        NSString *key = [which isEqualToString:@"edge"] ? @"windowGapEdge" : @"windowGapBetween";
        [NSUserDefaults.standardUserDefaults setInteger:[body[@"value"] integerValue] forKey:key];
        [self pushData];
    }
    if ([action isEqualToString:@"toggleWindowReservedAreas"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"windowIgnoreReservedAreas"] forKey:@"windowIgnoreReservedAreas"];
        [self pushData];
    }
    if ([action isEqualToString:@"setMetricsInterval"]) {
        [NSUserDefaults.standardUserDefaults setInteger:[body[@"value"] integerValue] forKey:@"metricsIntervalSeconds"];
        [self startSystemMonitor];  // recrée le timer à la nouvelle cadence
        [self pushData];
    }
    if ([action isEqualToString:@"openDashboard"]) [self openDashboard:nil];
    if ([action isEqualToString:@"quit"]) [NSApp terminate:nil];
    if ([action isEqualToString:@"toggleAwake"]) {
        self.awake.enabled = !self.awake.isEnabled;
        [self pushData];
    }
    if ([action isEqualToString:@"loginOpenAI"]) [self loginOpenAI:nil];
    if ([action isEqualToString:@"logoutOpenAI"]) [self confirmLogoutOpenAI:nil];
    if ([action isEqualToString:@"installClaudeCLI"]) [self openClaudeInstallPage:nil];
    if ([action isEqualToString:@"loginClaude"]) [self loginClaude:nil];
    if ([action isEqualToString:@"installClaudeTracking"]) [self installClaudeTracking:nil];
    if ([action isEqualToString:@"uninstallClaudeTracking"]) [self uninstallClaudeTracking:nil];
    if ([action isEqualToString:@"openClaudeTerminal"]) [self openClaudeTerminal:nil];
    if ([action isEqualToString:@"configureClaudeFableCookie"]) [self configureClaudeFableCookie:nil];
}

- (BOOL)launchAtLoginEnabled {
    if (@available(macOS 13.0, *)) {
        return SMAppService.mainAppService.status == SMAppServiceStatusEnabled;
    }
    return NO;
}

- (void)toggleLaunchAtLogin {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL enabled = [self launchAtLoginEnabled];
        if (enabled) [SMAppService.mainAppService unregisterAndReturnError:&error];
        else [SMAppService.mainAppService registerAndReturnError:&error];
        if (error) {
            NSAlert *alert = [NSAlert new];
            alert.messageText = enabled ? @"Impossible de désactiver le lancement au démarrage"
                                        : @"Impossible d’activer le lancement au démarrage";
            // Unsigned/ad-hoc builds moved around the disk are frequently refused by SMAppService.
            alert.informativeText = [NSString stringWithFormat:@"%@\n\nAstuce : placez Status dans /Applications, "
                                     @"puis réessayez.", error.localizedDescription];
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        }
        [self pushData];
    }
}

- (NSDictionary *)payload {
    NSArray *history = TMLoadHistory();
    return @{
        @"accounts": @{
            @"openai": self.openAIAccount ?: TMDisconnectedOpenAIAccount(@""),
            @"claude": self.claudeAccount ?: TMEmptyClaudeAccount()
        },
        @"history": history,
        @"forecasts": [self forecastsFromHistory:history],
        @"prefs": @{
            @"launchAtLogin": @([self launchAtLoginEnabled]),
            @"menuBarMetric": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly",
            @"hoverPopover": @([self hoverPopoverEnabled]),
            @"metricsInterval": @([self metricsInterval]),
            @"menuBarIconStyle": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarIconStyle"] ?: @"ring",
            @"globalShortcut": @([NSUserDefaults.standardUserDefaults boolForKey:@"globalShortcutEnabled"]),
            @"accessibilityTrusted": @(AXIsProcessTrusted()),
            @"windowManager": @([self windowManagerEnabled]),
            @"windowGapBetween": @([NSUserDefaults.standardUserDefaults integerForKey:@"windowGapBetween"]),
            @"windowGapEdge": @([NSUserDefaults.standardUserDefaults integerForKey:@"windowGapEdge"]),
            @"windowReservedAreas": @(![NSUserDefaults.standardUserDefaults boolForKey:@"windowIgnoreReservedAreas"]),
            @"notificationsAuthorized": @(self.notificationsAuthorized),
            @"theme": [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"blueprint"
        },
        @"tools": @{
        @"awake": @{ @"active": @(self.awake.isEnabled) },
        @"keyboardLock": @{ @"state": self.keyboardLock.state == TMLockStateLocked ? @"locked"
                                    : self.keyboardLock.state == TMLockStateBlocked ? @"blocked" : @"unlocked" }
    },
        @"backoffUntil": self.nextAllowedRefresh ? @(self.nextAllowedRefresh.timeIntervalSince1970 * 1000) : [NSNull null],
        @"refreshing": @(self.refreshing), @"updatedAt": @([[NSDate date] timeIntervalSince1970] * 1000)
    };
}

// Une prévision par fenêtre exploitable. Le calcul vit ici et non dans le JavaScript : la logique
// est testée dans native-tests, et les deux surfaces (tableau de bord, popover) la partagent.
- (NSDictionary *)forecastsFromHistory:(NSArray *)history {
    NSMutableDictionary *forecasts = [NSMutableDictionary dictionary];
    NSArray *pairs = @[@[@"claude", self.claudeAccount[@"windows"] ?: @[]],
                       @[@"openai", self.openAIAccount[@"windows"] ?: @[]]];
    for (NSArray *pair in pairs) {
        for (NSDictionary *window in pair[1]) {
            NSString *key = [NSString stringWithFormat:@"%@:%@", pair[0],
                             window[@"windowId"] ?: window[@"label"] ?: @""];
            NSTimeInterval at = 0;
            if (TMForecastExhaustion(history, key, TMNumber(window[@"resetsAt"]), &at)) {
                forecasts[key] = @(at * 1000);  // millisecondes : ce que Date attend côté web
            }
        }
    }
    return forecasts;
}

// Une fenêtre qui se recharge est une bonne nouvelle actionnable — on peut se remettre au travail.
// Détection par le couple (identifiant, resetsAt) : quand l'heure de reset avance, la fenêtre a
// tourné. Le dictionnaire est celui des seuils, déjà purgé des fenêtres périmées.
- (void)notifyWindowResets:(NSArray *)windows provider:(NSString *)provider {
    for (NSDictionary *window in windows) {
        NSString *identifier = window[@"windowId"] ?: window[@"label"];
        if (!identifier) continue;
        NSString *key = [NSString stringWithFormat:@"reset:%@:%@", provider, identifier];
        double resetsAt = TMNumber(window[@"resetsAt"]);
        double known = [self.notifiedThresholds[key] doubleValue];
        if (known > 0 && resetsAt > known && TMNumber(window[@"usedPercent"]) < 50) {
            [self postNotificationTitle:[NSString stringWithFormat:@"%@ · %@ réinitialisée",
                                         provider, window[@"label"] ?: identifier]
                                   body:@"La fenêtre est repartie à zéro."];
        }
        if (resetsAt > known) self.notifiedThresholds[key] = @(resetsAt);
    }
}

// Cookie de session claude.ai, mémorisé. Un seul accès au Trousseau par lancement, au lieu d'un
// par rafraîchissement.
- (NSString *)usageCookie {
    if (!self.usageCookieLoaded) {
        self.usageCookieCache = TMKeychainRead(TMClaudeSessionCookieAccount);
        self.usageCookieLoaded = YES;
    }
    return self.usageCookieCache ?: @"";
}

// À appeler après toute écriture du cookie : la prochaine lecture repassera par le Trousseau.
- (void)invalidateUsageCookieCache {
    self.usageCookieLoaded = NO;
    self.usageCookieCache = nil;
}

// Export de l'historique en CSV (feature 15). Panneau de sauvegarde système ; l'utilisateur
// choisit où écrire — l'app n'envoie rien nulle part.
- (void)exportHistoryCSV {
    NSString *csv = TMHistoryToCSV(TMLoadHistory());
    NSSavePanel *panel = [NSSavePanel savePanel];
    panel.nameFieldStringValue = @"status-historique.csv";
    [panel beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSModalResponseOK || !panel.URL) return;
        NSError *error = nil;
        [csv writeToURL:panel.URL atomically:YES encoding:NSUTF8StringEncoding error:&error];
        if (error) NSLog(@"Export CSV échoué : %@", error);
    }];
}

- (void)pushData {
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self payload] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (self.webReady) {
        NSString *script = [NSString stringWithFormat:@"window.StatusApp && window.StatusApp.update(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"Status dashboard JavaScript error: %@", error);
        }];
    }
    if (self.menuWebReady) {
        NSString *script = [NSString stringWithFormat:@"window.StatusMenu && window.StatusMenu.update(%@);", json];
        [self.menuWebView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"Status menu JavaScript error: %@", error);
        }];
    }
    [self updateStatusMenu];
}

#pragma mark - Moniteur système

// Échantillonnage permanent à 1 Hz (choix de la spec : anneaux pleins dès qu'on ouvre l'onglet).
// La poussée vers les webviews, elle, est conditionnelle — sérialiser 6 × 300 points chaque
// seconde pour des surfaces invisibles serait du gaspillage pur.
- (NSTimeInterval)metricsInterval {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:@"metricsIntervalSeconds"];
    return (seconds == 2 || seconds == 5) ? seconds : 1;
}

- (void)startSystemMonitor {
    if (!self.systemMonitor) self.systemMonitor = TMSystemMonitorCreate();
    [self.metricsTimer invalidate];  // recréé au changement d'intervalle ; les anneaux survivent
    __weak typeof(self) weakSelf = self;
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:[self metricsInterval] repeats:YES block:^(NSTimer *timer) {
        [weakSelf metricsTick];
    }];
    self.metricsTimer.tolerance = [self metricsInterval] * 0.2;  // macOS groupe les réveils, l'œil ne verra rien
}

// Seuils volontairement hauts : ces alertes signalent un état anormal, pas une machine qui
// travaille. L'écart seuil/réarmement évite la rafale quand la valeur oscille.
- (void)checkSystemAlerts:(NSDictionary *)snapshot {
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (NSDictionary *family in snapshot[@"families"]) byId[family[@"id"]] = family[@"now"];

    BOOL above = self.alertRAMAbove;
    NSNumber *pressure = byId[@"ram"][@"pressureLevel"];
    if (pressure && TMThresholdShouldFire(&above, pressure.doubleValue, 4, 2))
        [self postNotificationTitle:@"Mémoire · pression critique"
                               body:@"macOS compresse et purge agressivement. Fermez quelques applications."];
    self.alertRAMAbove = above;

    above = self.alertTempAbove;
    NSNumber *temp = byId[@"sensors"][@"tempC"];
    if (temp && TMThresholdShouldFire(&above, temp.doubleValue, 90, 82))
        [self postNotificationTitle:@"Température élevée"
                               body:[NSString stringWithFormat:@"Capteurs à %.0f °C en moyenne.", temp.doubleValue]];
    self.alertTempAbove = above;

    above = self.alertDiskAbove;
    NSNumber *diskUsed = byId[@"disk"][@"usedPercent"];
    if (diskUsed && TMThresholdShouldFire(&above, diskUsed.doubleValue, 90, 85))
        [self postNotificationTitle:@"Disque presque plein"
                               body:[NSString stringWithFormat:@"Volume de démarrage à %.0f %%.", diskUsed.doubleValue]];
    self.alertDiskAbove = above;
}

- (void)metricsTick {
    [self.systemMonitor sample];
    NSDictionary *snapshot = [self.systemMonitor snapshot];
    [self checkSystemAlerts:snapshot];  // les alertes veillent même toutes surfaces fermées

    BOOL dashboardVisible = self.webReady && self.window.isVisible;
    BOOL popoverVisible = self.menuWebReady && self.statusPopover.isShown;
    BOOL menuBarWantsSystem = [[NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] hasPrefix:@"system:"];
    if (menuBarWantsSystem) [self updateStatusMenu];
    if (!dashboardVisible && !popoverVisible) { self.previousProcessSample = nil; return; }

    // Le relevé des processus (~500 appels noyau) n'a lieu que surface visible ; le premier tick
    // après ouverture n'a donc pas de delta, comme le réseau au lancement.
    // Un tick sur deux : ~500 appels noyau, le poste le plus coûteux du moniteur. Invisible à
    // l'œil — la liste bouge peu d'une seconde à l'autre — et le coût est divisé par deux.
    self.processTickParity = !self.processTickParity;
    NSDictionary *processSample = self.processTickParity ? TMProcessSample() : nil;
    NSTimeInterval now = [NSDate timeIntervalSinceReferenceDate];
    if (!processSample) {
        NSMutableDictionary *skipped = [snapshot mutableCopy];
        skipped[@"processes"] = self.topProcesses ?: @[];
        skipped[@"intervalSeconds"] = @([self metricsInterval]);
        [self pushMetrics:skipped dashboard:dashboardVisible popover:popoverVisible];
        return;
    }
    if (processSample && self.previousProcessSample) {
        self.topProcesses = TMTopProcesses(self.previousProcessSample, processSample,
                                           now - self.previousProcessAt, 5);
    }
    self.previousProcessSample = processSample;
    self.previousProcessAt = now;

    NSMutableDictionary *payload = [snapshot mutableCopy];
    payload[@"processes"] = self.topProcesses ?: @[];
    payload[@"intervalSeconds"] = @([self metricsInterval]);
    [self pushMetrics:payload dashboard:dashboardVisible popover:popoverVisible];
}

- (void)pushMetrics:(NSDictionary *)payload dashboard:(BOOL)dashboard popover:(BOOL)popover {
    NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (dashboard) {
        NSString *script = [NSString stringWithFormat:@"window.StatusApp && window.StatusApp.updateMetrics && window.StatusApp.updateMetrics(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:nil];
    }
    if (popover) {
        NSString *script = [NSString stringWithFormat:@"window.StatusMenu && window.StatusMenu.updateMetrics && window.StatusMenu.updateMetrics(%@);", json];
        [self.menuWebView evaluateJavaScript:script completionHandler:nil];
    }
}

- (void)scheduleRefresh {
    [self.refreshTimer invalidate];
    NSInteger minutes = MAX(5, [NSUserDefaults.standardUserDefaults integerForKey:@"refreshIntervalMinutes"]);
    // Via a block, not @selector(refresh:): NSTimer passes *itself* as the argument, which refresh:
    // would read as a non-nil sender — i.e. a manual click — and every automatic tick would clear
    // the backoff it is supposed to obey.
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:minutes * 60 repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh:nil];
    }];
}

- (void)refreshOpenAIAccountWithCompletion:(void (^)(void))completion {
    [self.codexServer request:@"account/read" params:@{ @"refreshToken": @NO } completion:^(id result, NSError *error) {
        if (error) {
            NSMutableDictionary *payload = [self.openAIAccount mutableCopy] ?: [TMDisconnectedOpenAIAccount(@"") mutableCopy];
            payload[@"connecting"] = @NO;
            payload[@"error"] = error.localizedDescription ?: @"Connexion à Codex impossible.";
            self.openAIAccount = payload;
            [self pushData];
            if (completion) completion();
            return;
        }
        NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSDictionary *account = [response[@"account"] isKindOfClass:NSDictionary.class] ? response[@"account"] : nil;
        if (![account[@"type"] isEqualToString:@"chatgpt"]) {
            NSString *notice = [account[@"type"] isEqualToString:@"apiKey"] ? @"Codex utilise actuellement une clé API. Connectez un compte ChatGPT pour lire les quotas 5 h et semaine." : @"";
            self.openAIAccount = TMOpenAIAccountPayload(account, nil, NO, notice);
            [self pushData];
            if (completion) completion();
            return;
        }
        [self.codexServer request:@"account/rateLimits/read" params:nil completion:^(id rateResult, NSError *rateError) {
            NSDictionary *rateResponse = [rateResult isKindOfClass:NSDictionary.class] ? rateResult : @{};
            self.openAIAccount = TMOpenAIAccountPayload(account, rateResponse, NO, rateError.localizedDescription);
            [self pushData];
            if (completion) completion();
        }];
    }];
}

- (void)loginOpenAI:(id)sender {
    (void)sender;
    if ([self.openAIAccount[@"connecting"] boolValue]) return;
    NSMutableDictionary *payload = [self.openAIAccount mutableCopy] ?: [TMDisconnectedOpenAIAccount(@"") mutableCopy];
    payload[@"connecting"] = @YES;
    payload[@"error"] = @"";
    self.openAIAccount = payload;
    [self pushData];
    NSDictionary *params = @{ @"type": @"chatgpt", @"appBrand": @"codex", @"useHostedLoginSuccessPage": @YES };
    [self.codexServer request:@"account/login/start" params:params completion:^(id result, NSError *error) {
        NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSString *loginID = [response[@"loginId"] isKindOfClass:NSString.class] ? response[@"loginId"] : @"";
        NSString *authURL = [response[@"authUrl"] isKindOfClass:NSString.class] ? response[@"authUrl"] : @"";
        if (error || !loginID.length || !authURL.length) {
            NSMutableDictionary *failed = [self.openAIAccount mutableCopy];
            failed[@"connecting"] = @NO;
            failed[@"error"] = error.localizedDescription ?: @"Le serveur Codex n’a pas fourni de lien de connexion.";
            self.openAIAccount = failed;
            [self pushData];
            return;
        }
        NSURL *url = [NSURL URLWithString:authURL];
        if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
            NSMutableDictionary *failed = [self.openAIAccount mutableCopy];
            failed[@"connecting"] = @NO;
            failed[@"error"] = @"Le lien de connexion reçu n’est pas sécurisé.";
            self.openAIAccount = failed;
            [self pushData];
            return;
        }
        self.openAILoginID = loginID;
        [NSWorkspace.sharedWorkspace openURL:url];
    }];
}

- (void)confirmLogoutOpenAI:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Déconnecter le compte OpenAI ?";
    alert.informativeText = @"Status partage la session locale de Codex. Cette action déconnectera aussi Codex sur ce Mac.";
    [alert addButtonWithTitle:@"Déconnecter"];
    [alert addButtonWithTitle:@"Annuler"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [self.codexServer request:@"account/logout" params:nil completion:^(id result, NSError *error) {
            (void)result;
            self.openAILoginID = nil;
            self.openAIAccount = TMDisconnectedOpenAIAccount(error.localizedDescription);
            [self pushData];
        }];
    }];
}

- (void)handleCodexNotification:(NSString *)method params:(NSDictionary *)params {
    if ([method isEqualToString:@"account/login/completed"]) {
        NSString *loginID = [params[@"loginId"] isKindOfClass:NSString.class] ? params[@"loginId"] : @"";
        if (self.openAILoginID.length && loginID.length && ![loginID isEqualToString:self.openAILoginID]) return;
        self.openAILoginID = nil;
        if (![params[@"success"] boolValue]) {
            NSMutableDictionary *payload = [self.openAIAccount mutableCopy];
            payload[@"connecting"] = @NO;
            payload[@"error"] = [params[@"error"] isKindOfClass:NSString.class] ? params[@"error"] : @"Connexion OpenAI annulée.";
            self.openAIAccount = payload;
            [self pushData];
            return;
        }
        [self refreshOpenAIAccountWithCompletion:nil];
        return;
    }
    if ([method isEqualToString:@"account/updated"] || [method isEqualToString:@"account/rateLimits/updated"]) {
        [self refreshOpenAIAccountWithCompletion:nil];
    }
}

- (NSString *)claudeBridgePath {
    return [NSBundle.mainBundle pathForResource:@"status-claude-bridge" ofType:@"py" inDirectory:@"scripts"] ?: @"";
}

- (void)refreshClaudeAccountWithCompletion:(void (^)(void))completion {
    NSString *claudePath = TMClaudeExecutablePath();
    NSString *pythonPath = TMPythonExecutablePath();
    NSString *bridgePath = [self claudeBridgePath];
    NSString *usageCookie = [self usageCookie];
    __block NSDictionary *authJSON;
    __block NSDictionary *bridgeJSON;
    __block NSDictionary *usageJSONResult;
    __block NSString *authError = @"";
    __block NSString *bridgeError = @"";
    __block NSString *usageError = @"";
    dispatch_group_t group = dispatch_group_create();

    if (claudePath.length) {
        dispatch_group_enter(group);
        TMRunJSONProcess(claudePath, @[@"auth", @"status"], ^(NSDictionary *json, int status, NSError *error) {
            authJSON = json;
            if (error) authError = @"Impossible de vérifier la connexion Claude Code.";
            else if (!json && status != 0) authError = @"Claude Code n’a pas renvoyé un état de connexion lisible.";
            NSString *orgId = [json[@"orgId"] isKindOfClass:NSString.class] ? json[@"orgId"] : nil;
            if (usageCookie.length && orgId.length) {
                dispatch_group_enter(group);
                [self fetchClaudeUsageViaWeb:orgId completion:^(NSDictionary *usageJSON, NSError *fetchError) {
                    usageJSONResult = usageJSON;
                    if (fetchError) usageError = fetchError.localizedDescription;
                    dispatch_group_leave(group);
                }];
            }
            dispatch_group_leave(group);
        });
    }

    if (bridgePath.length && pythonPath.length) {
        dispatch_group_enter(group);
        TMRunJSONProcess(pythonPath, @[bridgePath, @"status"], ^(NSDictionary *json, int status, NSError *error) {
            bridgeJSON = json;
            if (error) bridgeError = @"Impossible de lire l’état du suivi Claude.";
            else if (![json[@"ok"] boolValue]) bridgeError = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : @"État du suivi Claude indisponible.";
            else if (status != 0) bridgeError = @"Le bridge Claude a quitté de façon inattendue.";
            dispatch_group_leave(group);
        });
    } else if (!bridgePath.length) {
        bridgeError = @"Le bridge Claude n’est pas présent dans l’application.";
    } else {
        bridgeError = @"Python 3 est requis pour activer le suivi Claude Code.";
    }

    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        BOOL authenticated = [authJSON[@"loggedIn"] boolValue] || [authJSON[@"logged_in"] boolValue] || [authJSON[@"authenticated"] boolValue];
        NSString *subscription = [authJSON[@"subscriptionType"] isKindOfClass:NSString.class] ? authJSON[@"subscriptionType"] : authJSON[@"subscription_type"];
        BOOL installed = [bridgeJSON[@"installed"] boolValue];
        BOOL configured = [bridgeJSON[@"configured"] boolValue];
        BOOL snapshotPresent = [bridgeJSON[@"snapshot_present"] boolValue];
        NSDictionary *snapshot = [bridgeJSON[@"snapshot"] isKindOfClass:NSDictionary.class] ? bridgeJSON[@"snapshot"] : nil;
        NSString *error = authError.length ? authError : (usageError.length ? usageError : bridgeError);

        // The /usage endpoint returns every window live on each poll, so when it answers it fully
        // replaces the statusLine snapshot — which only refreshes when a terminal `claude` session
        // responds and otherwise goes stale for hours.
        NSArray *usageWindows = usageJSONResult ? TMClaudeWindowsFromUsagePayload(usageJSONResult) : @[];
        BOOL live = usageWindows.count > 0;
        NSArray *windows = live ? usageWindows : TMDropExpiredWindows(TMClaudeWindowsFromSnapshot(snapshot));
        long long capturedAt = live ? (long long)NSDate.date.timeIntervalSince1970 : TMInteger(snapshot[@"captured_at_epoch"]);
        NSTimeInterval age = capturedAt > 0 ? NSDate.date.timeIntervalSince1970 - capturedAt : 0;

        self.claudeAccount = @{
            @"cliAvailable": @(claudePath.length > 0), @"authenticated": @(authenticated), @"authChecking": @NO,
            @"trackingInstalled": @(installed), @"trackingConfigured": @(configured), @"snapshotPresent": @(snapshotPresent),
            @"windows": windows, @"capturedAt": @(capturedAt), @"stale": @(!live && capturedAt > 0 && age > 1800),
            @"liveSource": @(live),
            @"subscriptionType": [subscription isKindOfClass:NSString.class] ? subscription : @"",
            @"fableConfigured": @(usageCookie.length > 0),
            @"actionRunning": @(self.claudeActionRunning), @"error": error ?: @""
        };
        [self pushData];
        [self monitorDirectSourceHealth:usageCookie.length > 0 live:live usageError:usageError];
        if (completion) completion();
    });
}

// Fraîcheur de la source directe (features 1 et 3). N'agit que si le cookie « direct » est
// configuré : sans lui, l'app est censée être sur la status line, et « figé » n'aurait pas de sens.
- (void)monitorDirectSourceHealth:(BOOL)directConfigured live:(BOOL)live usageError:(NSString *)usageError {
    if (!directConfigured) { self.directWasStale = NO; self.directFailures = 0; return; }

    // Feature 1 — alerte de péremption : la source directe est configurée mais ne renvoie plus de
    // données vivantes. On alerte une fois par épisode, pas à chaque tick.
    if (TMStaleAlertShouldFire(&_directWasStale, !live)) {
        [self postNotificationTitle:@"Jauges Claude figées"
                               body:@"La source directe claude.ai ne répond plus. Rouvrez l’app si cela persiste."];
    }

    // Feature 3 — chien de garde : après plusieurs échecs consécutifs du fetch direct, recharger la
    // WebView de zéro plutôt que d'attendre indéfiniment un rétablissement.
    if (TMWatchdogShouldReload(&_directFailures, live, 3)) {
        [self hardReloadUsageWebView];
    }
}

- (void)configureClaudeFableCookie:(id)sender {
    (void)sender;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Quotas Claude en direct (avancé, non officiel)";
    alert.informativeText =
        @"Sans cookie, les jauges Claude viennent de la status line : elles ne se rafraîchissent que "
        @"lorsqu’une session « claude » en Terminal répond, et restent figées le reste du temps. "
        @"Avec le cookie, les trois jauges (5 h, semaine, Fable) sont relues en direct toutes les 5 minutes.\n\n"
        @"1. Ouvrez claude.ai/settings/usage dans votre navigateur.\n"
        @"2. Outils de développement (⌥⌘I) → onglet Réseau, puis rechargez (⌘R).\n"
        @"3. Filtrez sur « usage » et cliquez la requête du même nom.\n"
        @"4. Clic droit dessus → Copier → Copier comme cURL.\n"
        @"5. Collez tel quel ci-dessous : Status en extraira le cookie seul.\n\n"
        @"⚠️ Ce cookie vaut un accès complet à votre compte Claude. Il est conservé dans le Trousseau "
        @"de ce Mac, n’est envoyé qu’à claude.ai, et se périme à votre prochaine déconnexion.";
    [alert addButtonWithTitle:@"Enregistrer"];
    [alert addButtonWithTitle:@"Annuler"];
    if ([self usageCookie].length) [alert addButtonWithTitle:@"Effacer"];

    NSSecureTextField *field = [NSSecureTextField textFieldWithString:@""];
    field.placeholderString = @"Collez le cURL (ou le cookie brut)";
    field.frame = NSMakeRect(0, 0, 420, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertThirdButtonReturn) {
            TMKeychainSave(TMClaudeSessionCookieAccount, @"");
            [self invalidateUsageCookieCache];
            self.usageWebLoaded = NO;
            [self refresh:nil];
            return;
        }
        if (response != NSAlertFirstButtonReturn) return;
        NSString *cookie = TMExtractCookieHeader(field.stringValue);
        if (!cookie.length) {
            NSAlert *failure = [NSAlert new];
            failure.messageText = @"Cookie introuvable dans le texte collé";
            failure.informativeText = @"Collez soit le résultat de « Copier comme cURL », soit la valeur "
                                       @"complète de l’en-tête Cookie de la requête « usage ».";
            [failure beginSheetModalForWindow:self.window completionHandler:nil];
            return;
        }
        TMKeychainSave(TMClaudeSessionCookieAccount, cookie);
        [self invalidateUsageCookieCache];
        // Manual: a fresh cookie is precisely the fix for whatever caused the backoff, so don't
        // make the user wait it out.
        [self seedUsageCookies:cookie completion:^{ [self refresh:self]; }];
    }];
}

- (BOOL)runClaudeCommandInTerminal:(NSArray<NSString *> *)arguments error:(NSDictionary **)error {
    NSString *path = TMClaudeExecutablePath();
    if (!path.length) return NO;
    NSMutableArray *pieces = [NSMutableArray arrayWithObject:TMShellQuote(path)];
    for (NSString *argument in arguments) [pieces addObject:TMShellQuote(argument)];
    NSString *command = [pieces componentsJoinedByString:@" "];
    NSString *source = [NSString stringWithFormat:@"tell application \"Terminal\"\nactivate\ndo script %@\nend tell", TMAppleScriptString(command)];
    NSAppleScript *script = [[NSAppleScript alloc] initWithSource:source];
    return [script executeAndReturnError:error] != nil;
}

- (void)openClaudeInstallPage:(id)sender {
    (void)sender;
    [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://code.claude.com/docs/en/setup"]];
}

- (void)loginClaude:(id)sender {
    (void)sender;
    NSDictionary *error;
    if (![self runClaudeCommandInTerminal:@[@"auth", @"login"] error:&error]) {
        NSMutableDictionary *payload = [self.claudeAccount mutableCopy];
        payload[@"error"] = TMClaudeExecutablePath().length ? @"Terminal n’a pas pu lancer la connexion Claude." : @"Claude Code n’est pas installé.";
        self.claudeAccount = payload;
        [self pushData];
        return;
    }
    NSMutableDictionary *payload = [self.claudeAccount mutableCopy];
    payload[@"authChecking"] = @YES;
    payload[@"error"] = @"";
    self.claudeAccount = payload;
    [self pushData];
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(5 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf refreshClaudeAccountWithCompletion:nil]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(20 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf refreshClaudeAccountWithCompletion:nil]; });
}

- (void)openClaudeTerminal:(id)sender {
    (void)sender;
    NSDictionary *error;
    if (![self runClaudeCommandInTerminal:@[] error:&error]) {
        NSMutableDictionary *payload = [self.claudeAccount mutableCopy];
        payload[@"error"] = @"Impossible d’ouvrir Claude Code dans Terminal.";
        self.claudeAccount = payload;
        [self pushData];
        return;
    }
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf refreshClaudeAccountWithCompletion:nil]; });
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(45 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [weakSelf refreshClaudeAccountWithCompletion:nil]; });
}

- (void)installClaudeTracking:(id)sender {
    (void)sender;
    if (self.claudeActionRunning) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = @"Activer le suivi Claude Code ?";
    alert.informativeText = @"Status ajoute un collecteur à la status line officielle de Claude Code. L’ancienne configuration est préservée et sera restaurée à la désactivation. Aucun identifiant, prompt ou transcript n’est lu.";
    [alert addButtonWithTitle:@"Activer le suivi"];
    [alert addButtonWithTitle:@"Annuler"];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [self runClaudeBridgeCommand:@"install"];
    }];
}

- (void)uninstallClaudeTracking:(id)sender {
    (void)sender;
    if (self.claudeActionRunning) return;
    [self runClaudeBridgeCommand:@"uninstall"];
}

- (void)runClaudeBridgeCommand:(NSString *)command {
    NSString *pythonPath = TMPythonExecutablePath();
    NSString *bridgePath = [self claudeBridgePath];
    if (!pythonPath.length || !bridgePath.length) {
        NSMutableDictionary *payload = [self.claudeAccount mutableCopy];
        payload[@"error"] = !pythonPath.length ? @"Python 3 est requis pour le suivi Claude." : @"Le bridge Claude manque dans l’application.";
        self.claudeAccount = payload;
        [self pushData];
        return;
    }
    self.claudeActionRunning = YES;
    NSMutableDictionary *running = [self.claudeAccount mutableCopy];
    running[@"actionRunning"] = @YES;
    running[@"error"] = @"";
    self.claudeAccount = running;
    [self pushData];
    TMRunJSONProcess(pythonPath, @[bridgePath, command], ^(NSDictionary *json, int status, NSError *error) {
        self.claudeActionRunning = NO;
        if (error || status != 0 || ![json[@"ok"] boolValue]) {
            NSMutableDictionary *failed = [self.claudeAccount mutableCopy];
            failed[@"actionRunning"] = @NO;
            failed[@"error"] = [json[@"error"] isKindOfClass:NSString.class] ? json[@"error"] : @"L’opération de suivi Claude a échoué.";
            self.claudeAccount = failed;
            [self pushData];
            return;
        }
        [self refreshClaudeAccountWithCompletion:nil];
    });
}

- (void)refresh:(id)sender {
    if (self.refreshing) return;

    // Backoff: a manual click (sender != nil) always goes through and clears the penalty box; an
    // automatic tick is skipped while claude.ai/Codex keep erroring, so we don't hammer a failing
    // endpoint every 5 minutes.
    BOOL manual = sender != nil;
    if (manual) {
        self.consecutiveErrors = 0;
        self.nextAllowedRefresh = nil;
    } else if (self.nextAllowedRefresh && [self.nextAllowedRefresh timeIntervalSinceNow] > 0) {
        return;
    }

    self.refreshing = YES;
    [self pushData];

    dispatch_group_t group = dispatch_group_create();
    dispatch_group_enter(group);
    [self refreshOpenAIAccountWithCompletion:^{ dispatch_group_leave(group); }];
    dispatch_group_enter(group);
    [self refreshClaudeAccountWithCompletion:^{ dispatch_group_leave(group); }];
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.refreshing = NO;
        [self applyBackoffFromCurrentState];
        [self recordHistoryAndNotify];
        [self pushData];
    });
}

// Grows the backoff delay (5→10→20→40 min, capped) while either provider reports an error, clears
// it once both are clean.
- (void)applyBackoffFromCurrentState {
    BOOL hasError = [self.openAIAccount[@"error"] length] > 0 || [self.claudeAccount[@"error"] length] > 0;
    if (!hasError) {
        self.consecutiveErrors = 0;
        self.nextAllowedRefresh = nil;
        return;
    }
    self.consecutiveErrors = MIN(self.consecutiveErrors + 1, 4);
    NSInteger base = MAX(1, [NSUserDefaults.standardUserDefaults integerForKey:@"refreshIntervalMinutes"]);
    NSTimeInterval delay = base * 60 * pow(2, self.consecutiveErrors);  // exponential
    self.nextAllowedRefresh = [NSDate dateWithTimeIntervalSinceNow:MIN(delay, 40 * 60)];
}

- (NSArray *)openAIWindowsForHistory {
    NSArray *windows = self.openAIAccount[@"windows"];
    return [windows isKindOfClass:NSArray.class] ? windows : @[];
}

- (NSArray *)claudeWindowsForHistory {
    NSArray *windows = self.claudeAccount[@"windows"];
    return [windows isKindOfClass:NSArray.class] ? windows : @[];
}

- (void)recordHistoryAndNotify {
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    TMAppendHistory([self claudeWindowsForHistory], [self openAIWindowsForHistory], now);
    [self checkThresholdsForWindows:[self claudeWindowsForHistory] provider:@"Claude"];
    [self checkThresholdsForWindows:[self openAIWindowsForHistory] provider:@"OpenAI"];
    [self notifyWindowResets:[self claudeWindowsForHistory] provider:@"Claude"];
    [self notifyWindowResets:[self openAIWindowsForHistory] provider:@"OpenAI"];
}

// Fires a notification the first time a window crosses 80% and again at 95%, keyed by the window's
// reset instant so a fresh period re-arms both thresholds. Never notifies twice for the same level.
- (void)checkThresholdsForWindows:(NSArray *)windows provider:(NSString *)provider {
    if (!self.notificationsAuthorized) return;
    for (NSDictionary *w in windows) {
        double used = TMNumber(w[@"usedPercent"]);
        NSString *wid = w[@"windowId"];
        long long resetsAt = TMInteger(w[@"resetsAt"]);
        if (!wid || resetsAt <= 0) continue;
        NSString *key = [NSString stringWithFormat:@"%@:%@@%lld", provider, wid, resetsAt];
        NSInteger already = [self.notifiedThresholds[key] integerValue];
        NSInteger reached = used >= 95 ? 95 : (used >= 80 ? 80 : 0);
        if (reached > already) {
            self.notifiedThresholds[key] = @(reached);
            NSString *label = [w[@"label"] isKindOfClass:NSString.class] ? w[@"label"] : wid;
            [self postNotificationTitle:[NSString stringWithFormat:@"%@ · %@ à %ld %%", provider, label, (long)reached]
                                   body:reached >= 95 ? @"Limite presque atteinte." : @"Quota bien entamé."];
        }
    }
    // Prune keys for reset periods now in the past so the dictionary can't grow unbounded.
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    NSArray *keys = self.notifiedThresholds.allKeys;
    for (NSString *key in keys) {
        NSRange at = [key rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location != NSNotFound && [key substringFromIndex:at.location + 1].longLongValue <= now) {
            [self.notifiedThresholds removeObjectForKey:key];
        }
    }
}

- (void)postNotificationTitle:(NSString *)title body:(NSString *)body {
    UNMutableNotificationContent *content = [UNMutableNotificationContent new];
    content.title = title;
    content.body = body;
    UNNotificationRequest *request = [UNNotificationRequest requestWithIdentifier:NSUUID.UUID.UUIDString
                                                                          content:content trigger:nil];
    [UNUserNotificationCenter.currentNotificationCenter addNotificationRequest:request withCompletionHandler:nil];
}

@end

// Drapeaux one-shot : SMAppService ne peut s'enregistrer que depuis le processus de l'app, donc
// sans cela le lancement au démarrage ne serait activable qu'à la main dans les Réglages. Utile
// aussi pour scripter une installation.
static int TMRunLoginItemCommand(BOOL enable) {
    if (@available(macOS 13.0, *)) {
        NSError *error = nil;
        BOOL ok = enable ? [SMAppService.mainAppService registerAndReturnError:&error]
                         : [SMAppService.mainAppService unregisterAndReturnError:&error];
        if (!ok) {
            fprintf(stderr, "échec : %s\n", error.localizedDescription.UTF8String);
            return 1;
        }
        printf("lancement au démarrage : %s\n", enable ? "activé" : "désactivé");
        return 0;
    }
    fprintf(stderr, "macOS 13+ requis\n");
    return 1;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--register-login-item") == 0) return TMRunLoginItemCommand(YES);
            if (strcmp(argv[i], "--unregister-login-item") == 0) return TMRunLoginItemCommand(NO);
        }
        NSApplication *application = NSApplication.sharedApplication;
        TMAppDelegate *delegate = [TMAppDelegate new];
        application.delegate = delegate;
        [application run];
    }
    return 0;
}
