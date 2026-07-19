#import <Cocoa/Cocoa.h>
#import <WebKit/WebKit.h>
#import <Security/Security.h>
#import <ServiceManagement/ServiceManagement.h>
#import <UserNotifications/UserNotifications.h>
#include <string.h>

#import "StatusQuota.h"
#import "StatusAwake.h"
#import "StatusSystemMonitor.h"

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

static NSColor *TMSeverityColor(TMSeverity severity) {
    switch (severity) {
        case TMSeverityCritical: return [NSColor colorWithSRGBRed:0.98 green:0.44 blue:0.52 alpha:1];  // #FB7185
        case TMSeverityWarn:     return [NSColor colorWithSRGBRed:0.98 green:0.75 blue:0.14 alpha:1];  // #FBBF24
        default:                 return NSColor.blackColor;  // ignoré : rendu en template
    }
}

// L'icône EST la jauge : l'anneau se remplit avec la consommation, au lieu d'un pictogramme
// décoratif qui n'apprend rien. Lecture périphérique par la forme, lecture précise par le texte.
//
// Template en régime normal, pour que macOS l'inverse en clair/sombre et au survol. En alerte on
// quitte le mode template : la couleur encode alors l'urgence, pas la marque — le seul cas qui
// justifie de désobéir au thème. Ambre et rouge restent lisibles sur les deux fonds.
static NSImage *TMGaugeIcon(double fraction, BOOL hasValue, TMSeverity severity) {
    const CGFloat side = 18, radius = 6.3, lineWidth = 2.0;
    NSPoint center = NSMakePoint(side / 2, side / 2);
    NSColor *ink = TMSeverityColor(severity);

    NSImage *image = [[NSImage alloc] initWithSize:NSMakeSize(side, side)];
    [image lockFocus];

    // Piste toujours visible : le vide doit se lire autant que le plein.
    //
    // Elle reste neutre même en alerte. Teintée d'ambre ou de rouge comme l'arc, elle ne s'en
    // distinguait plus que par l'alpha, et l'anneau se lisait uniformément plein — le niveau
    // devenait illisible juste au moment où il compte. Le gris moyen tient sur les deux fonds.
    NSColor *trackInk = (severity == TMSeverityNormal)
        ? [ink colorWithAlphaComponent:0.3]                 // template : seul l'alpha compte
        : [NSColor colorWithWhite:0.55 alpha:0.6];
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
    image.template = (severity == TMSeverityNormal);
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

typedef void (^TMAppServerCompletion)(id result, NSError *error);
typedef void (^TMProcessJSONCompletion)(NSDictionary *json, int terminationStatus, NSError *error);

static NSError *TMError(NSString *message) {
    return [NSError errorWithDomain:@"Status.CodexAppServer" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Erreur inconnue"}];
}

static NSString *TMCodexExecutablePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"STATUS_CODEX_PATH"];
    if (override.length && [NSFileManager.defaultManager isExecutableFileAtPath:override]) return override;
    NSArray<NSString *> *candidates = @[
        @"/Applications/ChatGPT.app/Contents/Resources/codex",
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/codex"],
        @"/opt/homebrew/bin/codex",
        @"/usr/local/bin/codex"
    ];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return @"";
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

@interface TMCodexAppServer : NSObject
@property NSTask *task;
@property NSPipe *inputPipe;
@property NSPipe *outputPipe;
@property NSPipe *errorPipe;
@property NSMutableData *readBuffer;
@property NSMutableDictionary<NSNumber *, TMAppServerCompletion> *pending;
@property NSInteger nextRequestID;
@property BOOL initialized;
@property BOOL starting;
@property (copy) void (^notificationHandler)(NSString *method, NSDictionary *params);
- (void)start:(TMAppServerCompletion)completion;
- (void)request:(NSString *)method params:(NSDictionary *)params completion:(TMAppServerCompletion)completion;
- (void)notify:(NSString *)method params:(NSDictionary *)params;
- (void)stop;
@end

@implementation TMCodexAppServer

- (instancetype)init {
    if ((self = [super init])) {
        _readBuffer = [NSMutableData data];
        _pending = [NSMutableDictionary dictionary];
        _nextRequestID = 1;
    }
    return self;
}

- (void)start:(TMAppServerCompletion)completion {
    if (self.initialized) { if (completion) completion(@{}, nil); return; }
    if (self.starting) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self start:completion]; });
        return;
    }
    NSString *path = TMCodexExecutablePath();
    if (!path.length) {
        if (completion) completion(nil, TMError(@"Codex est introuvable. Installez l’app ChatGPT/Codex ou définissez STATUS_CODEX_PATH."));
        return;
    }
    self.starting = YES;
    self.task = [NSTask new];
    self.task.executableURL = [NSURL fileURLWithPath:path];
    self.task.arguments = @[@"app-server", @"--listen", @"stdio://"];
    self.inputPipe = [NSPipe pipe];
    self.outputPipe = [NSPipe pipe];
    self.errorPipe = [NSPipe pipe];
    self.task.standardInput = self.inputPipe;
    self.task.standardOutput = self.outputPipe;
    self.task.standardError = self.errorPipe;

    __weak typeof(self) weakSelf = self;
    self.outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:data]; });
    };
    // Drain diagnostics so the child process can never block, but never surface auth material.
    self.errorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) { (void)handle.availableData; };
    self.task.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf terminated:task.terminationStatus]; });
    };
    NSError *launchError;
    if (![self.task launchAndReturnError:&launchError]) {
        self.starting = NO;
        if (completion) completion(nil, launchError);
        return;
    }
    NSDictionary *params = @{ @"clientInfo": @{ @"name": @"status_macos", @"title": @"Status", @"version": @"0.1.0" } };
    [self sendRequest:@"initialize" params:params completion:^(id result, NSError *error) {
        self.starting = NO;
        if (!error) {
            self.initialized = YES;
            [self notify:@"initialized" params:@{}];
        }
        if (completion) completion(result, error);
    }];
}

- (void)request:(NSString *)method params:(NSDictionary *)params completion:(TMAppServerCompletion)completion {
    [self start:^(id result, NSError *error) {
        (void)result;
        if (error) { if (completion) completion(nil, error); return; }
        [self sendRequest:method params:params completion:completion];
    }];
}

- (void)sendRequest:(NSString *)method params:(NSDictionary *)params completion:(TMAppServerCompletion)completion {
    NSNumber *requestID = @(self.nextRequestID++);
    NSMutableDictionary *message = [@{ @"method": method, @"id": requestID } mutableCopy];
    if (params) message[@"params"] = params;
    if (completion) self.pending[requestID] = [completion copy];
    [self writeMessage:message];
}

- (void)notify:(NSString *)method params:(NSDictionary *)params {
    NSMutableDictionary *message = [@{ @"method": method } mutableCopy];
    if (params) message[@"params"] = params;
    [self writeMessage:message];
}

- (void)writeMessage:(NSDictionary *)message {
    NSError *error;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    @try { [self.inputPipe.fileHandleForWriting writeData:line]; }
    @catch (__unused NSException *exception) { [self terminated:-1]; }
}

- (void)consume:(NSData *)data {
    [self.readBuffer appendData:data];
    while (YES) {
        const void *bytes = self.readBuffer.bytes;
        NSUInteger length = self.readBuffer.length;
        const void *newline = memchr(bytes, '\n', length);
        if (!newline) break;
        NSUInteger lineLength = (const uint8_t *)newline - (const uint8_t *)bytes;
        NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(0, lineLength)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, lineLength + 1) withBytes:NULL length:0];
        if (!line.length) continue;
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![message isKindOfClass:NSDictionary.class]) continue;
        NSNumber *requestID = message[@"id"];
        if (requestID) {
            TMAppServerCompletion block = self.pending[requestID];
            [self.pending removeObjectForKey:requestID];
            NSDictionary *rpcError = message[@"error"];
            NSError *error = rpcError ? TMError(rpcError[@"message"] ?: @"Le serveur Codex a refusé la requête.") : nil;
            if (block) block(message[@"result"], error);
        } else {
            NSString *method = message[@"method"];
            NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : @{};
            if (method.length && self.notificationHandler) self.notificationHandler(method, params);
        }
    }
}

- (void)terminated:(int)status {
    if (!self.task && !self.starting && !self.initialized) return;
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    self.errorPipe.fileHandleForReading.readabilityHandler = nil;
    self.task = nil;
    self.starting = NO;
    self.initialized = NO;
    NSError *error = TMError(status == 0 ? @"Le serveur Codex s’est arrêté." : @"Le serveur Codex a quitté de façon inattendue.");
    NSArray *callbacks = self.pending.allValues;
    [self.pending removeAllObjects];
    for (TMAppServerCompletion block in callbacks) block(nil, error);
}

- (void)stop {
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    self.errorPipe.fileHandleForReading.readabilityHandler = nil;
    if (self.task.running) [self.task terminate];
    self.task = nil;
    self.initialized = NO;
    self.starting = NO;
}

@end










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

@implementation TMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.awake = [TMAwake new];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        @"refreshIntervalMinutes": @5,
        // lowest | claude:session | claude:weekly | openai:weekly — quel % accompagne l'icône.
        // Claude semaine par défaut : c'est la limite qui contraint réellement le travail.
        @"menuBarMetric": @"claude:weekly",
        @"hoverPopover": @YES
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
    [self requestNotificationAuthorization];
    [self observeWakeNotifications];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Re-seed sessionKey into the WebView store before the first poll. The store is persistent, so
    // this is usually a no-op; it matters on the first launch after the cookie is set, and after
    // anything clears the store.
    NSString *cookie = TMKeychainRead(TMClaudeSessionCookieAccount);
    if (cookie.length) [self seedUsageCookies:cookie completion:^{ [self refresh:nil]; }];
    else [self refresh:nil];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    self.awake.enabled = NO;  // l'assertion mourrait avec le processus, mais la relâcher est explicite
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
    self.statusItem.button.image = TMGaugeIcon(0, NO, TMSeverityNormal);
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
    // Cloudflare may interpose a challenge page; give WebKit room to solve it before giving up.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        void (^pending)(BOOL) = self.usageWebLoadCompletion;
        if (!pending) return;
        self.usageWebLoadCompletion = nil;
        pending(NO);
    });
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

    if ([metric isEqualToString:@"claude:session"]) {
        hasValue = hasClaudeSession; shown = claudeSession;
    } else if ([metric isEqualToString:@"claude:weekly"]) {
        hasValue = hasClaudeWeekly; shown = claudeWeekly;
    } else if ([metric isEqualToString:@"openai:weekly"]) {
        hasValue = hasOpenAIWeekly; shown = openAIWeekly;
    } else {
        // « lowest » = la marge la plus faible, donc le pourcentage consommé le plus élevé.
        NSArray *candidates = @[
            @[@(hasClaudeSession), @(claudeSession), @"C 5h"],
            @[@(hasClaudeWeekly), @(claudeWeekly), @"C sem"],
            @[@(hasOpenAIWeekly), @(openAIWeekly), @"AI sem"],
        ];
        for (NSArray *candidate in candidates) {
            if (![candidate[0] boolValue]) continue;
            double value = [candidate[1] doubleValue];
            if (!hasValue || value > shown) { hasValue = YES; shown = value; label = candidate[2]; }
        }
    }

    TMSeverity severity = hasValue ? TMSeverityForPercent(shown) : TMSeverityNormal;
    NSString *title = hasValue
        ? [NSString stringWithFormat:@" %@%ld%%", label ? [label stringByAppendingString:@" "] : @"", (long)(shown + 0.5)]
        : @" --";

    self.statusItem.button.image = TMGaugeIcon(shown / 100.0, hasValue, severity);
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
    return @{
        @"accounts": @{
            @"openai": self.openAIAccount ?: TMDisconnectedOpenAIAccount(@""),
            @"claude": self.claudeAccount ?: TMEmptyClaudeAccount()
        },
        @"history": TMLoadHistory(),
        @"prefs": @{
            @"launchAtLogin": @([self launchAtLoginEnabled]),
            @"menuBarMetric": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly",
            @"hoverPopover": @([self hoverPopoverEnabled]),
            @"notificationsAuthorized": @(self.notificationsAuthorized)
        },
        @"tools": @{ @"awake": @{ @"active": @(self.awake.isEnabled) } },
        @"backoffUntil": self.nextAllowedRefresh ? @(self.nextAllowedRefresh.timeIntervalSince1970 * 1000) : [NSNull null],
        @"refreshing": @(self.refreshing), @"updatedAt": @([[NSDate date] timeIntervalSince1970] * 1000)
    };
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
- (void)startSystemMonitor {
    self.systemMonitor = TMSystemMonitorCreate();
    __weak typeof(self) weakSelf = self;
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:1.0 repeats:YES block:^(NSTimer *timer) {
        [weakSelf metricsTick];
    }];
    self.metricsTimer.tolerance = 0.2;  // laisse macOS grouper les réveils, l'œil ne verra rien
}

- (void)metricsTick {
    [self.systemMonitor sample];
    BOOL dashboardVisible = self.webReady && self.window.isVisible;
    BOOL popoverVisible = self.menuWebReady && self.statusPopover.isShown;
    if (!dashboardVisible && !popoverVisible) return;

    NSData *data = [NSJSONSerialization dataWithJSONObject:[self.systemMonitor snapshot] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (dashboardVisible) {
        NSString *script = [NSString stringWithFormat:@"window.StatusApp && window.StatusApp.updateMetrics && window.StatusApp.updateMetrics(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:nil];
    }
    if (popoverVisible) {
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
    NSString *usageCookie = TMKeychainRead(TMClaudeSessionCookieAccount);
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
        if (completion) completion();
    });
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
    if (TMKeychainRead(TMClaudeSessionCookieAccount).length) [alert addButtonWithTitle:@"Effacer"];

    NSSecureTextField *field = [NSSecureTextField textFieldWithString:@""];
    field.placeholderString = @"Collez le cURL (ou le cookie brut)";
    field.frame = NSMakeRect(0, 0, 420, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertThirdButtonReturn) {
            TMKeychainSave(TMClaudeSessionCookieAccount, @"");
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
