#import "StatusLidClient.h"
#import "StatusLidProtocol.h"
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
#import "StatusAccounts.h"
#import "StatusApiCredits.h"
#import "StatusClaudeSession.h"
#import "StatusClaudeBridge.h"
#import "StatusCost.h"
#import "StatusFx.h"
#import "StatusDisplays.h"
#import "StatusMenuBarWidgets.h"
#import "StatusIconDesigns.h"
#import "StatusI18n.h"
#import "StatusUpdater.h"
#import <ApplicationServices/ApplicationServices.h>  // AXIsProcessTrusted
#import <IOKit/hidsystem/ev_keymap.h>  // NX_KEYTYPE_BRIGHTNESS_UP/DOWN
#import <IOKit/hidsystem/IOLLEvent.h>  // NX_SYSDEFINED

// Unofficial, session-cookie-based source for the live Claude quota windows, which Claude Code's
// official statusLine cannot provide on demand. The endpoint is undocumented and can change or
// break without notice; the cookie is stored locally in the Keychain and never leaves this Mac.
static NSString *const TMService = @"com.raphael.tokenmeter.credentials";
// Une entrée par compte. L'entrée historique sans suffixe reste lue une fois, à la migration.
static NSString *const TMClaudeLegacyCookieAccount = @"claude-session-cookie";
static NSString *TMClaudeCookieAccount(NSString *accountId) {
    return [NSString stringWithFormat:@"claude-session-cookie:%@", accountId];
}

// Lecture avec son issue (TMKeychainReadOutcome) : « absent » prouve qu'il n'y a pas d'entrée,
// « denied » (accès refusé, Trousseau verrouillé) ne prouve rien et ne doit pas être mémorisé.
static NSString *TMKeychainReadWithOutcome(NSString *account, NSString **outOutcome) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TMService,
        (__bridge id)kSecAttrAccount: account,
        (__bridge id)kSecReturnData: @YES,
        (__bridge id)kSecMatchLimit: (__bridge id)kSecMatchLimitOne
    };
    CFTypeRef result = NULL;
    OSStatus status = SecItemCopyMatching((__bridge CFDictionaryRef)query, &result);
    if (outOutcome) *outOutcome = TMKeychainReadOutcome(status);
    if (status != errSecSuccess) return @"";
    NSData *data = CFBridgingRelease(result);
    return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] ?: @"";
}

static NSString *TMKeychainRead(NSString *account) {
    return TMKeychainReadWithOutcome(account, NULL);
}

// Valeur vide = suppression, réussie seulement si l'entrée n'existe plus.
static BOOL TMKeychainSaveWithAccess(NSString *account, NSString *value, CFStringRef accessible) {
    NSDictionary *query = @{
        (__bridge id)kSecClass: (__bridge id)kSecClassGenericPassword,
        (__bridge id)kSecAttrService: TMService,
        (__bridge id)kSecAttrAccount: account
    };
    if (value.length == 0) return TMKeychainDeleteSucceeded(SecItemDelete((__bridge CFDictionaryRef)query));
    NSDictionary *attributes = @{
        (__bridge id)kSecValueData: [value dataUsingEncoding:NSUTF8StringEncoding],
        (__bridge id)kSecAttrAccessible: (__bridge id)accessible
    };
    OSStatus status = SecItemUpdate((__bridge CFDictionaryRef)query, (__bridge CFDictionaryRef)attributes);
    if (status == errSecItemNotFound) {
        NSMutableDictionary *item = [query mutableCopy];
        [item addEntriesFromDictionary:attributes];
        status = SecItemAdd((__bridge CFDictionaryRef)item, NULL);
    }
    return status == errSecSuccess;
}

static BOOL TMKeychainSave(NSString *account, NSString *value) {
    return TMKeychainSaveWithAccess(account, value, kSecAttrAccessibleAfterFirstUnlock);
}

// Clés d'administration : jamais copiées vers un autre appareil (sauvegarde, migration).
static BOOL TMApiKeySave(NSString *accountId, NSString *value) {
    return TMKeychainSaveWithAccess(TMApiKeychainAccount(accountId), value, kSecAttrAccessibleAfterFirstUnlockThisDeviceOnly);
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
// `widthTemplate` : le texte le plus large que ce titre puisse prendre (« 100 % » quand la valeur
// du moment est « 9 % »). Sans lui, l'élément rétrécit à chaque tick et décale toute la rangée
// d'icônes — y compris celle sous laquelle un panneau vient d'être ancré.
// Réglage global de macOS (domaine « tous les domaines », hôte courant) : c'est celui de
// `defaults -currentHost write -g …`. Une valeur nil supprime la clé.
static id TMReadSystemStatusItemPref(NSString *key) {
    CFPropertyListRef value = CFPreferencesCopyValue((__bridge CFStringRef)key, kCFPreferencesAnyApplication,
                                                     kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    return CFBridgingRelease(value);
}
static void TMWriteSystemStatusItemPref(NSString *key, id value) {
    CFPreferencesSetValue((__bridge CFStringRef)key, (__bridge CFPropertyListRef)value, kCFPreferencesAnyApplication,
                          kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
    CFPreferencesSynchronize(kCFPreferencesAnyApplication, kCFPreferencesCurrentUser, kCFPreferencesCurrentHost);
}

static NSAttributedString *TMMenuBarTitle(NSString *text, NSString *widthTemplate, TMSeverity severity, CGFloat scale) {
    // Le titre suit la taille des icônes (Réglages › Affichage) : 12 pt à l'échelle 1, arrondi au demi-point.
    NSMutableDictionary *attributes = [@{
        NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:TMMenuBarTitleFontSize(scale) weight:NSFontWeightMedium]
    } mutableCopy];
    // En régime normal, laisser macOS choisir la couleur du texte (thème, survol, contraste réduit).
    // On ne l'impose qu'en alerte, pour l'accorder à l'anneau.
    if (severity != TMSeverityNormal) attributes[NSForegroundColorAttributeName] = TMSeverityColor(severity);
    return TMTitleWithReservedWidth(text, widthTemplate, attributes);
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

// Dictionnaire de la langue effective, injecté avant tout script de la page : t() est utilisable
// dès le premier rendu. Remplacé à chaque changement de langue (voir applyLanguageChange), pour
// qu'un rechargement de la page retombe sur la bonne langue.
static void TMInstallI18nScript(WKWebView *view) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:TMI18nPayload() options:0 error:nil];
    NSString *source = [NSString stringWithFormat:@"window.__STATUS_I18N__ = %@;",
                        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    WKUserContentController *controller = view.configuration.userContentController;
    [controller removeAllUserScripts];
    [controller addUserScript:[[WKUserScript alloc] initWithSource:source
                                                     injectionTime:WKUserScriptInjectionTimeAtDocumentStart
                                                  forMainFrameOnly:YES]];
}

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

// Session des comptes API : aucune redirection suivie. Les deux Admin API n'en font pas ; en
// suivre une pourrait envoyer la clé d'administration ailleurs qu'à api.anthropic.com ou
// api.openai.com. Le 3xx revient tel quel et s'affiche comme une erreur HTTP.
@interface TMApiSessionDelegate : NSObject <NSURLSessionTaskDelegate>
@end

@implementation TMApiSessionDelegate
- (void)URLSession:(NSURLSession *)session task:(NSURLSessionTask *)task
willPerformHTTPRedirection:(NSHTTPURLResponse *)response newRequest:(NSURLRequest *)request
 completionHandler:(void (^)(NSURLRequest *))completionHandler {
    completionHandler(nil);
}
@end

@interface TMAppDelegate : NSObject <NSApplicationDelegate, WKScriptMessageHandler, WKNavigationDelegate>
@property NSWindow *window;
@property WKWebView *webView;
@property WKWebView *menuWebView;
// Une session claude.ai par compte : accountId → TMClaudeSession.
@property NSMutableDictionary<NSString *, TMClaudeSession *> *claudeSessions;
@property NSStatusItem *statusItem;
@property NSMutableArray<NSStatusItem *> *iconPreviewItems;
@property NSString *iconPreviewProvider;
@property NSPopover *statusPopover;
@property BOOL webReady;
@property BOOL menuWebReady;
@property TMSystemMonitor *systemMonitor;
@property NSTimer *metricsTimer;
@property NSDictionary *previousProcessSample;
@property NSTimeInterval previousProcessAt;
@property NSArray *topProcesses;
// Historique long (24 h) : accumulé en mémoire, écrit sur disque par à-coups pour ne pas
// solliciter le SSD chaque minute.
@property NSArray *metricsLog;
@property NSTimeInterval metricsLogLastAppend;
@property NSTimeInterval metricsLogLastSave;
@property BOOL processTickParity;
// États d'hystérésis des alertes système — un booléen par seuil surveillé.
@property BOOL alertRAMAbove, alertTempAbove, alertDiskAbove;
@property TMKeyboardLock *keyboardLock;
@property TMUpdater *updater;
// Le cookie claude.ai, lu une seule fois au lancement. Le relire à chaque rafraîchissement
// déclenchait une demande d'accès au Trousseau à chaque fois — et comme le survol de l'icône
// ouvre le popover, donc rafraîchit, cela produisait plusieurs demandes par minute.
// Le secret ne change que quand l'utilisateur le change : on invalide le cache à ce moment-là.
@property NSMutableDictionary<NSString *, NSString *> *cookieCache;
@property NSDictionary *costScan;    // dernier balayage des coûts terminal (feature 16)
@property BOOL costScanning;
@property NSTimeInterval costScanCompletedAt;
@property id globalShortcutMonitor, localShortcutMonitor;
@property TMDisplayManager *displayManager;
@property id brightnessGlobalMonitor, brightnessLocalMonitor;
@property CFMachPortRef brightnessTap;          // chemin privilégié : consomme la touche
@property CFRunLoopSourceRef brightnessTapSource;
@property NSThread *brightnessTapThread;        // le tap tourne hors du thread principal
@property CFRunLoopRef brightnessTapRunLoop;
@property BOOL brightnessPushPending;           // rafraîchissement UI déjà programmé
@property NSArray<NSDictionary *> *quotaWidgetFamilies;  // familles quota injectées dans le snapshot widgets
// Comptes API (Admin API Anthropic / OpenAI). La clé de chaque compte est lue une fois au
// Trousseau puis gardée en mémoire (« » = aucune clé, pour ne pas relire) ; elle ne quitte ce
// processus que dans l'en-tête des requêtes vers l'hôte de son fournisseur.
@property NSArray<NSDictionary *> *apiRegistry;
@property NSMutableDictionary<NSString *, NSString *> *apiKeyCache;
@property NSMutableDictionary<NSString *, NSDictionary *> *apiDaily;     // accountId → { jour UTC : dollars }
@property NSMutableDictionary<NSString *, NSDictionary *> *apiStatus;    // accountId → { updatedAt, coveredFrom, error }
@property TMApiFetchGate *apiGate;                                       // relevés en vol, jeton par compte
@property NSMutableDictionary<NSString *, NSURLSessionTask *> *apiTasks;  // requête en cours, pour l'annuler
@property NSMutableDictionary<NSString *, NSDate *> *apiNextAllowed;     // débit minimal et backoff
@property NSMutableDictionary<NSString *, NSNumber *> *apiErrorCounts;
@property NSTimer *apiTimer;
@property NSURLSession *apiSession;
@property BOOL apiPushPending;
@property NSArray<NSDictionary *> *apiWidgetFamilies;
@property NSMutableDictionary<NSString *, NSStatusItem *> *widgetItems;  // widgetId → icône dédiée
// widgetId → signature du dernier rendu poussé (TMWidgetRenderSignature). Réassigner l'image d'un
// NSStatusItem redéclenche un dessin WindowServer : à 1 Hz, on ne le fait que si les pixels changent.
@property NSMutableDictionary<NSString *, NSDictionary *> *widgetSignatures;
// Même mécanisme pour la jauge principale : metricsTick appelle updateStatusMenu chaque seconde
// quand une métrique système y est épinglée.
@property NSDictionary *statusMenuSignature;
@property NSPopover *widgetPopover;
@property WKWebView *widgetWebView;
@property BOOL widgetWebReady;
@property (copy) NSString *currentWidgetId;
// Popup regroupé : icône cliquée, à transmettre une fois à la page pour qu'elle défile jusqu'à sa section.
@property (copy) NSString *pendingWidgetFocus;
@property (copy) NSString *groupedFocusId;  // dernière icône cliquée dans le popup regroupé (pour distinguer reclic et changement d'icône)
@property NSMutableDictionary<NSString *, NSNumber *> *widgetPanelHeights;  // widgetId → hauteur mesurée
@property BOOL refreshing;
@property NSTimer *refreshTimer;
// Un serveur applicatif Codex par compte OpenAI, chacun sur son propre CODEX_HOME.
@property NSMutableDictionary<NSString *, TMCodexAppServer *> *codexServers;
@property NSMutableDictionary<NSString *, NSString *> *openAILoginIDs;
// Registre normalisé (voir StatusAccounts) et dernier payload connu de chaque compte.
@property NSArray<NSDictionary *> *accountRegistry;
@property NSMutableDictionary<NSString *, NSDictionary *> *accountPayloads;
@property NSTrackingArea *hoverArea;
@property NSTimer *hoverOpenTimer;          // délai avant ouverture : évite le surgissement en traversant la barre
@property NSTimer *hoverCloseTimer;         // grâce à la sortie : laisse le temps d'entrer dans le popover
@property BOOL popoverOpenedByHover;        // un popover ouvert au clic ne doit pas se fermer tout seul
@property NSMutableDictionary<NSString *, NSNumber *> *accountErrorCounts;
@property NSMutableDictionary<NSString *, NSDate *> *accountBackoffUntil;
@property NSTimeInterval lastQuotaRefreshAt;
// Une surface « amorcée » a déjà reçu un payload métriques complet (séries incluses) ; les ticks
// suivants n'envoient qu'un delta (TMMetricsDeltaPayload) et la série glisse côté web. L'amorçage
// retombe quand la surface se ferme ou que sa webview se recharge.
@property BOOL dashboardMetricsPrimed, popoverMetricsPrimed, widgetMetricsPrimed;
@property BOOL dashboardStale;  // payload complet non envoyé car fenêtre cachée
@property BOOL monitorViewActive;
@property BOOL macToolsVisible;
@property BOOL notificationsAuthorized;
@property TMAwake *awake;
@property TMLidClient *lidMode;
@property NSTimer *lidTimer;
@end

@implementation TMAppDelegate

- (void)applicationDidFinishLaunching:(NSNotification *)notification {
    self.updater = [TMUpdater new];
    self.awake = [TMAwake new];
    self.lidMode = [TMLidClient new];
    __weak typeof(self) weakSelf = self;
    // Le service répond toutes les 5 s (vitesse des ventilateurs) : seul l'état des outils est
    // renvoyé, pas tout le payload (historique, comptes…) à chaque fois.
    self.lidMode.onChange = ^{ [weakSelf pushTools]; };
    self.lidTimer = [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
        [weakSelf.lidMode refresh];
    }];
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    [defaults registerDefaults:@{
        @"refreshIntervalSeconds": @60,
        // lowest | claude:session | claude:weekly | openai:weekly — quel % accompagne l'icône.
        // Claude semaine par défaut : c'est la limite qui contraint réellement le travail.
        @"menuBarMetric": @"claude:weekly",
        @"hoverPopover": @YES,
        @"monitorInBackground": @NO,
        // « auto » : la jauge prend la couleur du fournisseur affiché. Voir updateStatusMenu.
        @"menuBarIconColor": @"auto",
        // blueprint reste l'apparence historique : les utilisateurs existants ne voient aucun
        // changement tant qu'ils ne choisissent pas un autre thème dans Réglages.
        @"theme": @"blueprint"
    }];
    // Migration : les valeurs d'avant l'ajout du fournisseur ne correspondent plus à rien, et
    // laisseraient l'élément bloqué sur « -- » sans jamais dire pourquoi.
    NSDictionary *migrations = @{@"session": @"claude:session", @"weekly": @"claude:weekly"};
    NSString *stored = [defaults stringForKey:@"menuBarMetric"];
    if (migrations[stored]) [defaults setObject:migrations[stored] forKey:@"menuBarMetric"];
    self.accountPayloads = [NSMutableDictionary dictionary];
    self.codexServers = [NSMutableDictionary dictionary];
    self.claudeSessions = [NSMutableDictionary dictionary];
    self.openAILoginIDs = [NSMutableDictionary dictionary];
    self.accountErrorCounts = [NSMutableDictionary dictionary];
    self.accountBackoffUntil = [NSMutableDictionary dictionary];
    self.cookieCache = [NSMutableDictionary dictionary];
    [self loadAccountRegistry];
    [self loadApiAccounts];
    // Réafficher les derniers volumes connus immédiatement, sans attendre le premier sondage : ils
    // ont été persistés en continu à chaque mise à jour. Sans cela, le grand chiffre et la barre
    // des menus restent à « — » plusieurs secondes après chaque redémarrage.
    [self restoreCachedAccounts];
    // Historique 24 h de la session précédente : il reprend là où il s'était arrêté. Les lignes
    // trop vieilles s'élaguent au premier ajout, pas ici — inutile d'écrire au lancement.
    self.metricsLog = TMLoadMetricsHistory();
    // Démarrer le compteur maintenant plutôt qu'à zéro : sinon le tout premier tick journalise une
    // ligne alors que CPU et réseau n'ont pas encore de delta (ils exigent deux échantillons) et
    // sont donc absents. Une poignée de redémarrages suffirait à cribler la vue 24 h de trous.
    self.metricsLogLastAppend = [NSDate date].timeIntervalSince1970;
    self.widgetPanelHeights = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetPanelHeights"] ?: @{}) mutableCopy];
    // Avant tout appel possible à pushData (refreshCostsInBackground en pousse un dès le
    // lancement) : `payload` lit self.displayManager sans filet, un nil ferait planter le
    // literal @{...} plutôt que d'omettre la clé.
    self.displayManager = [TMDisplayManager new];
    [self.displayManager rescan];
    [self buildWindow];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(dashboardWillClose:)
                                             name:NSWindowWillCloseNotification object:self.window];
    [self buildStatusItem];
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(statusPopoverDidClose:)
                                             name:NSPopoverDidCloseNotification object:self.statusPopover];
    if ([NSProcessInfo.processInfo.arguments containsObject:@"--preview-menu-icons"])
        [self showIconPreviews];
    [self scheduleRefresh];
    [self scheduleApiRefresh];
    [self startSystemMonitor];
    [self rebuildMenuBarWidgets];  // icônes système activées par l'utilisateur, à côté de la jauge quota
    [self refreshCostsInBackground];
    [[TMFxRate shared] refreshIfStale];  // taux de change USD→EUR, en fond, si le cache est périmé
    self.keyboardLock = [TMKeyboardLock new];
    __weak typeof(self) weakLockSelf = self;
    self.keyboardLock.stateChanged = ^(TMLockState state) { [weakLockSelf pushData]; };
    [self installGlobalShortcut];
    [self installBrightnessKeyMonitor];
    [self observeDisplayChanges];
    [self requestNotificationAuthorization];
    [self observeWakeNotifications];
    [self.window makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];

    // Ré-amorcer les sessions claude.ai avant le premier sondage. Les magasins sont persistants,
    // donc c'est en général sans effet ; cela compte au premier lancement après la saisie d'un
    // cookie, et après tout ce qui a pu vider un magasin.
    for (NSDictionary *account in [self accountsForProvider:TMProviderClaude]) {
        NSString *accountId = account[@"accountId"];
        if ([account[@"claudeSource"] isEqual:@"code"] || [account[@"claudeSource"] isEqual:@"web"]) continue;
        NSString *cookie = [self cookieForAccount:accountId];
        if (cookie.length) [[self claudeSessionForAccount:accountId] seedCookieIfNeeded:cookie];
    }
    [self refresh:nil];
    [self refreshApiAccountsForce:NO];
}

- (BOOL)applicationShouldTerminateAfterLastWindowClosed:(NSApplication *)sender { return NO; }
- (void)applicationWillTerminate:(NSNotification *)notification {
    [self.lidTimer invalidate];
    [self.lidMode invalidate];  // Le service indépendant restaure sur rupture XPC (ou après 20 s).
    self.awake.enabled = NO;  // l'assertion mourrait avec le processus, mais la relâcher est explicite
    [self.keyboardLock forceUnlock];
    [self removeGlobalShortcut];
    [self removeBrightnessKeyMonitor];
    [self.metricsTimer invalidate];
    // Dernier vidage synchrone : sans lui, jusqu'à 5 min d'historique disparaîtraient à la fermeture.
    if (self.metricsLog.count) TMSaveMetricsHistory(self.metricsLog);
    for (TMCodexAppServer *server in self.codexServers.allValues) [server stop];
    [NSWorkspace.sharedWorkspace.notificationCenter removeObserver:self];
    [NSNotificationCenter.defaultCenter removeObserver:self];
}

- (void)requestNotificationAuthorization {
    UNUserNotificationCenter *center = UNUserNotificationCenter.currentNotificationCenter;
    [center requestAuthorizationWithOptions:(UNAuthorizationOptionAlert | UNAuthorizationOptionSound)
                          completionHandler:^(BOOL granted, NSError *error) {
        // L'erreur était ignorée. Or c'est précisément elle qui explique une app qui ne notifie
        // jamais sans que rien ne le dise : macOS refuse la demande pour des raisons qui n'ont
        // rien à voir avec le choix de l'utilisateur (bundle non enregistré, signature instable).
        if (error) NSLog(@"Status: demande de notifications refusée — %@", error.localizedDescription);
        dispatch_async(dispatch_get_main_queue(), ^{
            self.notificationsAuthorized = granted;
            [self pushData];
        });
    }];
    [self refreshNotificationAuthorization];
}

// L'autorisation se change dans Réglages système à tout moment, sans que l'app en soit avertie :
// la valeur obtenue une fois au lancement finit par mentir. On relit l'état réel — au lancement et
// au réveil — pour que l'onglet Réglages dise la vérité.
- (void)refreshNotificationAuthorization {
    [UNUserNotificationCenter.currentNotificationCenter getNotificationSettingsWithCompletionHandler:
     ^(UNNotificationSettings *settings) {
        BOOL authorized = settings.authorizationStatus == UNAuthorizationStatusAuthorized
                       || settings.authorizationStatus == UNAuthorizationStatusProvisional;
        dispatch_async(dispatch_get_main_queue(), ^{
            if (self.notificationsAuthorized == authorized) return;
            self.notificationsAuthorized = authorized;
            [self pushData];
        });
    }];
}

// A machine waking from sleep has almost certainly gone stale; refresh at once rather than waiting
// out the remainder of the 5-minute timer.
- (void)observeWakeNotifications {
    [NSWorkspace.sharedWorkspace.notificationCenter addObserver:self selector:@selector(systemDidWake:)
                                                          name:NSWorkspaceDidWakeNotification object:nil];
}

- (void)systemDidWake:(NSNotification *)notification {
    [self refreshNotificationAuthorization];
    [self refresh:nil];  // automatic: if the endpoint was failing before sleep, keep honouring the backoff
    [self rescanDisplays];  // un moniteur externe peut avoir été rebranché pendant la veille
}

// Rebranchement/débranchement d'un écran, ou réveil : les identifiants DDC/CoreDisplay précédents
// ne sont plus valables tels quels, il faut réénumérer plutôt que rafraîchir en place.
- (void)observeDisplayChanges {
    [NSNotificationCenter.defaultCenter addObserver:self selector:@selector(rescanDisplays)
                                                name:NSApplicationDidChangeScreenParametersNotification object:nil];
}

- (void)rescanDisplays {
    [self.displayManager rescan];
    [self pushData];
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
    TMInstallI18nScript(self.webView);
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
    // Two provider icons, kept adjacent without text.
    self.statusItem = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
    // L'icône n'est pas posée ici : updateStatusMenu la redessine à chaque cycle, puisqu'elle
    // représente la valeur courante. Un tiret le temps de la première lecture.
    self.statusItem.button.image = TMGaugeIcon(0, NO, TMSeverityNormal, nil);
    self.statusItem.button.imagePosition = NSImageLeading;
    self.statusItem.button.target = self;
    self.statusItem.button.action = @selector(toggleStatusPopover:);
    [self installHoverTracking];

    NSRect frame = NSMakeRect(0, 0, 480, MIN(700, NSScreen.mainScreen.visibleFrame.size.height - 80));  // jauges, liste des comptes, capot fermé ; contenu défilant
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    [configuration.userContentController addScriptMessageHandler:self name:@"native"];
    self.menuWebView = [[WKWebView alloc] initWithFrame:frame configuration:configuration];
    TMInstallI18nScript(self.menuWebView);
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

- (void)closeIconPreviews {
    for (NSStatusItem *item in self.iconPreviewItems) [NSStatusBar.systemStatusBar removeStatusItem:item];
    self.iconPreviewItems = nil;
}

- (void)showIconPreviews {
    [self closeIconPreviews];
    if (!self.iconPreviewProvider) self.iconPreviewProvider=@"openai";
    [self.statusPopover close];
    self.iconPreviewItems = [NSMutableArray array];
    NSArray *ids = TMIconDesignIDs(), *names = TMIconDesignNames();
    CGFloat scale = [self menuBarIconScale], spacing = [self menuBarIconSpacing];
    // Reverse insertion keeps designs 01–06 in reading order in the menu bar.
    for (NSInteger i = ids.count - 1; i >= 0; i--) {
        NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:30];
        NSImage *preview = TMMenuBarImageWithLayout(TMProviderGauge(ids[i], @0.72, [self.iconPreviewProvider isEqual:@"openai"]), scale, spacing);
        preview.template = NO;
        item.button.image = preview;
        item.length = MAX(30, preview.size.width + 12);  // l'aperçu suit la taille et l'espacement réglés
        item.button.identifier = ids[i];
        item.button.toolTip = TMTP(@"m.iconPreview", @{@"i": [NSString stringWithFormat:@"%02ld", (long)i + 1], @"name": TMTranslateFR(names[i]), @"provider": self.iconPreviewProvider});
        item.button.accessibilityLabel = item.button.toolTip;
        item.button.target = self;
        item.button.action = @selector(selectIconPreview:);
        [self.iconPreviewItems addObject:item];
    }
}

- (void)selectIconPreview:(NSButton *)sender {
    NSString *style = sender.identifier;
    if (![TMIconDesignIDs() containsObject:style]) return;
    [NSUserDefaults.standardUserDefaults setObject:style forKey:[@"menuBarIconStyle." stringByAppendingString:self.iconPreviewProvider ?: @"openai"]];
    [self closeIconPreviews];
    [self updateStatusMenu];
    [self pushData];
}

#pragma mark - Widgets de la barre des menus (icônes système multiples)

// L'ordre du réglage `menuBarWidgets` EST l'ordre d'affichage : c'est lui que les boutons
// monter/descendre manipulent. On ne fait que filtrer les ids inconnus (réglage d'une version
// ultérieure, ou fichier bricolé à la main) et les doublons.
- (NSArray<NSString *> *)enabledWidgets {
    NSArray *stored = [NSUserDefaults.standardUserDefaults arrayForKey:@"menuBarWidgets"];
    NSArray *catalogue = TMMenuBarWidgetIDs();
    NSMutableArray *valid = [NSMutableArray array];
    for (NSString *wid in stored)
        if ([wid isKindOfClass:NSString.class] && [catalogue containsObject:wid] && ![valid containsObject:wid])
            [valid addObject:wid];
    return valid;
}

// Crée/détruit les NSStatusItem pour coller à la liste activée. Idempotent : appelé au lancement
// et à chaque bascule de réglage.
- (void)rebuildMenuBarWidgets {
    if (!self.widgetItems) self.widgetItems = [NSMutableDictionary dictionary];
    NSArray<NSString *> *enabled = [self enabledWidgets];

    // Retirer les widgets désactivés.
    for (NSString *wid in self.widgetItems.allKeys)
        if (![enabled containsObject:wid]) {
            [NSStatusBar.systemStatusBar removeStatusItem:self.widgetItems[wid]];
            [self.widgetItems removeObjectForKey:wid];
            [self.widgetSignatures removeObjectForKey:wid];
        }

    // Ajouter les manquants. L'ordre d'affichage vient de la création : macOS insère chaque
    // nouveau NSStatusItem à gauche des précédents, d'où le parcours à l'envers pour que le
    // premier de la liste finisse le plus à gauche. Un simple ajout ne réordonne donc pas
    // l'existant — c'est reorderMenuBarWidgets qui s'en charge en recréant tout.
    for (NSString *wid in enabled.reverseObjectEnumerator) {
        if (self.widgetItems[wid]) continue;
        NSStatusItem *item = [NSStatusBar.systemStatusBar statusItemWithLength:NSVariableStatusItemLength];
        item.button.image = TMMenuBarImageWithLayout(TMWidgetImage(TMWidgetReadout(wid, @{})),
                                                     [self menuBarIconScale], [self menuBarIconSpacing]);  // tiret en attendant le 1er tick
        item.button.imagePosition = NSImageLeading;
        item.button.target = self;
        item.button.action = @selector(widgetClicked:);
        item.button.identifier = wid;  // pour retrouver le widget au clic et au redessin
        self.widgetItems[wid] = item;
        [self.widgetSignatures removeObjectForKey:wid];  // item neuf (tiret) : forcer le 1er rendu
    }
    [self refreshQuotaWidgetFamilies];
    [self updateMenuBarWidgetsFromMonitor];
}

// Réordonner impose de tout recréer : la position d'un NSStatusItem est fixée à sa création et
// aucune API publique ne la déplace après coup. On détruit donc l'ensemble avant de laisser
// rebuildMenuBarWidgets les recréer dans le bon ordre. Visible à l'écran (les icônes clignotent
// brièvement), mais c'est le seul chemin disponible.
- (void)reorderMenuBarWidgets {
    for (NSStatusItem *item in self.widgetItems.allValues)
        [NSStatusBar.systemStatusBar removeStatusItem:item];
    [self.widgetItems removeAllObjects];
    [self rebuildMenuBarWidgets];
}

// Chaque widget a son propre panneau d'info (façon iStat), distinct du popover quota : un WKWebView
// léger (widget.html) qui affiche le détail focalisé de la métrique cliquée.
// Largeur du panneau d'info : fixe (le contenu est calibré dessus), contrairement à la hauteur.
static const CGFloat TMWidgetPanelWidth = 264;
static const CGFloat TMWidgetPanelDefaultHeight = 220;
// Popup regroupé (réglage « Popups des widgets » = Regroupé) : un seul panneau, un peu plus large,
// pour les cartes de résumé de tous les widgets activés.
static const CGFloat TMWidgetGroupedPanelWidth = 300;
static NSString *const TMGroupedWidgetId = @"grouped";  // identifiant du panneau regroupé (affichage, niveau de détail)

- (BOOL)widgetPopupGrouped {
    return [[NSUserDefaults.standardUserDefaults stringForKey:@"widgetPopupMode"] isEqualToString:@"grouped"];
}

// Widgets présentés par le popup regroupé : ceux de la barre des menus qui ont un panneau moniteur
// (les widgets de quotas/API ouvrent le popover des comptes), dans leur ordre d'affichage.
- (NSArray<NSString *> *)groupedWidgetIds {
    NSMutableArray *ids = [NSMutableArray array];
    for (NSString *wid in [self enabledWidgets])
        if (!TMWidgetUsesAccounts(wid)) [ids addObject:wid];
    return ids;
}

- (NSInteger)groupedDetailLevel {
    id level = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetDetail"][TMGroupedWidgetId];
    return [level isKindOfClass:NSNumber.class] ? MAX(0, MIN(2, [level integerValue])) : 0;  // défaut : Résumé
}

- (CGFloat)widgetPanelWidthFor:(NSString *)wid {
    return [wid isEqualToString:TMGroupedWidgetId] ? TMWidgetGroupedPanelWidth : TMWidgetPanelWidth;
}

// Clé de mémorisation de la hauteur d'un panneau. Celle du regroupé dépend du niveau et du nombre
// de widgets : une hauteur mesurée au niveau Résumé ne vaut rien pour l'Hyper détaillé.
- (NSString *)panelHeightKeyFor:(NSString *)wid {
    if (![wid isEqualToString:TMGroupedWidgetId]) return wid;
    return [NSString stringWithFormat:@"%@.%ld.%lu", TMGroupedWidgetId, (long)[self groupedDetailLevel], (unsigned long)[self groupedWidgetIds].count];
}

- (void)ensureWidgetPopover {
    if (self.widgetPopover) return;
    NSRect frame = NSMakeRect(0, 0, TMWidgetPanelWidth, TMWidgetPanelDefaultHeight);
    WKWebViewConfiguration *config = [WKWebViewConfiguration new];
    [config.userContentController addScriptMessageHandler:self name:@"native"];
    self.widgetWebView = [[WKWebView alloc] initWithFrame:frame configuration:config];
    TMInstallI18nScript(self.widgetWebView);
    self.widgetWebView.navigationDelegate = self;
    self.widgetWebView.underPageBackgroundColor = NSColor.clearColor;
    NSURL *url = [NSBundle.mainBundle URLForResource:@"widget" withExtension:@"html"];
    [self.widgetWebView loadFileURL:url allowingReadAccessToURL:url.URLByDeletingLastPathComponent];
    NSViewController *controller = [NSViewController new];
    controller.view = self.widgetWebView;
    controller.preferredContentSize = frame.size;
    self.widgetPopover = [NSPopover new];
    self.widgetPopover.behavior = NSPopoverBehaviorTransient;
    // Sans cela, chaque ajustement de hauteur (changement de widget, section qui apparaît) se
    // joue en animation : le panneau se déplie sous le curseur au lieu de s'afficher fait.
    self.widgetPopover.animates = NO;
    self.widgetPopover.contentSize = frame.size;
    self.widgetPopover.contentViewController = controller;
}

// Hauteur du panneau = hauteur réelle de son contenu, mesurée par la page et poussée ici. Une
// taille fixe tronquait net les panneaux longs (CPU s'arrêtait au milieu de « charge », la liste
// des processus n'apparaissait jamais) tout en laissant du vide sous les courts.
- (void)applyWidgetPanelHeight:(CGFloat)height forWidget:(NSString *)wid {
    if (height < 80) return;  // mesure aberrante (page pas encore rendue) : on garde l'existante
    CGFloat maxHeight = MAX(240, NSScreen.mainScreen.visibleFrame.size.height - 40);
    height = ceil(MIN(height, maxHeight));
    NSString *heightKey = wid ? [self panelHeightKeyFor:wid] : nil;
    if (heightKey) {
        self.widgetPanelHeights[heightKey] = @(height);
        // Persistées : au relancement, le premier affichage de chaque panneau part déjà de la
        // bonne taille au lieu de s'ouvrir puis de se redimensionner sous le curseur.
        [NSUserDefaults.standardUserDefaults setObject:self.widgetPanelHeights forKey:@"widgetPanelHeights"];
    }
    if (!self.widgetPopover || fabs(self.widgetPopover.contentSize.height - height) < 1) return;
    NSSize size = NSMakeSize([self widgetPanelWidthFor:self.currentWidgetId], height);
    // Les deux, et dans cet ordre : NSPopover se cale sur la taille préférée de son
    // contentViewController dès qu'elle est renseignée, et ignore alors contentSize seul.
    self.widgetPopover.contentViewController.preferredContentSize = size;
    self.widgetPopover.contentSize = size;
}

- (NSDictionary *)widgetMetricsPayload {
    NSMutableDictionary *payload = [[self.systemMonitor snapshot] mutableCopy];
    payload[@"prefs"] = @{ @"theme": [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"blueprint",
                           @"panels": [NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetPanelConfig"] ?: @{},
                           // widgetId → niveau de détail du panneau (0 résumé, 1 détaillé, 2 hyper détaillé).
                           @"detail": [NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetDetail"] ?: @{},
                           // Popups séparés ou regroupé ; en regroupé, ids des widgets système activés, dans l'ordre d'affichage.
                           @"popupMode": [self widgetPopupGrouped] ? @"grouped" : @"separate",
                           @"widgets": [self groupedWidgetIds] };
    payload[@"processes"] = self.topProcesses ?: @[];  // top consommateurs, pour les panneaux CPU/Mémoire
    payload[@"intervalSeconds"] = @([self metricsInterval]);  // cadence des séries : graduations du niveau « hyper détaillé »
    return payload;
}

// Pousse le contenu du widget courant (show = change de widget + données ; les ticks suivants ne
// font qu'actualiser les données).
- (void)pushWidgetMetrics {
    if (!self.widgetWebReady || !self.currentWidgetId) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:[self widgetMetricsPayload] options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    // Popup regroupé : l'icône cliquée n'est transmise qu'une fois (3e argument), pour que la page défile
    // jusqu'à sa section — un rafraîchissement dû à un réglage ne doit pas la faire re-défiler.
    NSString *focusArg = @"";
    if ([self.currentWidgetId isEqualToString:TMGroupedWidgetId] && self.pendingWidgetFocus
        && [TMMenuBarWidgetIDs() containsObject:self.pendingWidgetFocus]) {
        focusArg = [NSString stringWithFormat:@", '%@'", self.pendingWidgetFocus];
    }
    self.pendingWidgetFocus = nil;
    NSString *script = [NSString stringWithFormat:@"window.StatusWidget && window.StatusWidget.show('%@', %@%@);", self.currentWidgetId, json, focusArg];
    [self.widgetWebView evaluateJavaScript:script completionHandler:nil];
    self.widgetMetricsPrimed = YES;  // payload complet envoyé : les ticks peuvent passer au delta
}

- (void)widgetClicked:(NSButton *)sender {
    NSString *wid = sender.identifier;
    // Widgets de consommation : leur détail, c'est le popover des quotas (comptes et fenêtres),
    // pas un panneau moniteur — widget.html ne saurait rien en dire de plus.
    if (TMWidgetUsesAccounts(wid)) {
        if (self.statusPopover.shown) { [self.statusPopover close]; return; }
        [self showPopoverFromButton:sender];
        return;
    }
    // Réglage « Popups des widgets » = Regroupé : toutes les icônes ouvrent le même popup. Reclic sur
    // l'icône déjà au premier plan : il se ferme ; clic sur une autre icône pendant qu'il est ouvert :
    // il reste ouvert et défile jusqu'à la section de ce widget.
    BOOL grouped = [self widgetPopupGrouped];
    NSString *panelId = grouped ? TMGroupedWidgetId : wid;
    if (self.widgetPopover.shown && [self.currentWidgetId isEqual:panelId]) {
        if (!grouped || [self.groupedFocusId isEqual:wid]) { [self.widgetPopover close]; return; }  // reclic : bascule
        self.groupedFocusId = wid;
        self.pendingWidgetFocus = wid;
        [self pushWidgetMetrics];
        return;
    }
    [self ensureWidgetPopover];
    self.currentWidgetId = panelId;
    self.groupedFocusId = grouped ? wid : nil;
    self.pendingWidgetFocus = grouped ? wid : nil;
    // Largeur propre au panneau, et hauteur déjà mesurée si on la connaît : les poser avant
    // l'affichage évite le saut du premier frame, le temps que la page remesure et confirme.
    NSNumber *known = self.widgetPanelHeights[[self panelHeightKeyFor:panelId]];
    NSSize size = NSMakeSize([self widgetPanelWidthFor:panelId], known ? known.doubleValue : self.widgetPopover.contentSize.height);
    self.widgetPopover.contentViewController.preferredContentSize = size;
    self.widgetPopover.contentSize = size;
    [self pushWidgetMetrics];  // remplit avant l'affichage si le web est prêt
    [self.widgetPopover showRelativeToRect:sender.bounds ofView:sender preferredEdge:NSRectEdgeMinY];
}

// Redessine chaque widget depuis un snapshot moniteur. Les styles « bars »/« pie » posent la
// valeur en titre système à côté de l'image ; « twoLine »/« battery » embarquent tout leur texte
// dans l'image (titre vide).
// Forme et couleur choisies par l'utilisateur pour un widget (réglage menuBarWidgetConfig), ou nil
// (= forme naturelle / couleur auto).
- (NSDictionary *)widgetStyleFor:(NSString *)wid {
    NSDictionary *config = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"menuBarWidgetConfig"];
    NSDictionary *one = [config[wid] isKindOfClass:NSDictionary.class] ? config[wid] : nil;
    return one;
}

// Les widgets de consommation hebdomadaire ne lisent pas le moniteur système : leurs chiffres
// viennent des comptes, agrégés par fournisseur comme la jauge. On les injecte dans le snapshot
// sous forme de familles homonymes, pour que le moteur des widgets les traite comme les autres.
// La série (coûteuse : relecture de l'historique sur disque) n'est calculée que si la forme
// choisie la dessine.
// Recalculé quand les quotas bougent (pushData), pas à chaque tick du moniteur : la lecture des
// comptes touche le Trousseau et l'historique sur disque — hors de question à 1 Hz.
- (void)refreshQuotaWidgetFamilies {
    [self refreshApiWidgetFamilies];  // même déclencheur : les icônes de crédit API suivent
    NSArray *pairs = @[@[@"claudeWeek", @"claude:weekly"], @[@"codexWeek", @"openai:weekly"]];
    NSMutableArray *wanted = [NSMutableArray array];
    for (NSArray *pair in pairs) if (self.widgetItems[pair[0]]) [wanted addObject:pair];
    if (!wanted.count) { self.quotaWidgetFamilies = @[]; return; }

    NSArray *accounts = [self accountPayloadList];
    NSMutableArray *families = [NSMutableArray array];
    for (NSArray *pair in wanted) {
        NSString *wid = pair[0], *metric = pair[1];
        NSDictionary *resolved = TMResolveMenuBarMetric(metric, accounts);
        if (!resolved) continue;  // fournisseur non connecté : la famille manque, le widget montre un tiret
        id shape = [self widgetStyleFor:wid][@"shape"];
        if (![shape isKindOfClass:NSString.class]) shape = @"";
        NSArray *series = [@[@"bars", @"graph"] containsObject:shape] ? [self menuBarSeriesForMetric:metric] : @[];
        [families addObject:@{ @"id": wid,
                               @"now": @{ @"percent": @(TMNumber(resolved[@"usedPercent"])) },
                               @"series": @{ @"percent": series ?: @[] } }];
    }
    self.quotaWidgetFamilies = families;
}

- (NSDictionary *)snapshotWithQuotaFamilies:(NSDictionary *)snapshot {
    NSArray *injected = [(self.quotaWidgetFamilies ?: @[]) arrayByAddingObjectsFromArray:self.apiWidgetFamilies ?: @[]];
    if (!injected.count) return snapshot;
    NSArray *existing = [snapshot[@"families"] isKindOfClass:NSArray.class] ? snapshot[@"families"] : @[];
    NSMutableDictionary *result = [snapshot mutableCopy] ?: [NSMutableDictionary dictionary];
    result[@"families"] = [existing arrayByAddingObjectsFromArray:injected];
    return result;
}

- (void)updateMenuBarWidgets:(NSDictionary *)snapshot {
    if (!self.widgetItems.count) return;
    snapshot = [self snapshotWithQuotaFamilies:snapshot];
    if (!self.widgetSignatures) self.widgetSignatures = [NSMutableDictionary dictionary];
    [self.widgetItems enumerateKeysAndObjectsUsingBlock:^(NSString *wid, NSStatusItem *item, BOOL *stop) {
        NSDictionary *readout = TMWidgetReadout(wid, snapshot);
        NSDictionary *style = [self widgetStyleFor:wid];
        NSString *shape = [style[@"shape"] isKindOfClass:NSString.class] ? style[@"shape"] : nil;
        NSString *color = [style[@"color"] isKindOfClass:NSString.class] ? style[@"color"] : nil;
        CGFloat scale = [self menuBarIconScale], spacing = [self menuBarIconSpacing];
        NSDictionary *signature = TMWidgetRenderSignatureWithLayout(readout, shape, color, scale, spacing);
        if ([self.widgetSignatures[wid] isEqual:signature]) return;  // mêmes pixels : rien à redessiner
        self.widgetSignatures[wid] = signature;
        item.button.image = TMMenuBarImageWithLayout(TMWidgetImageStyled(readout, shape, color), scale, spacing);
        // Le titre système (valeur à côté) n'accompagne que les formes « graphe/jauge » ; les formes
        // qui portent déjà leur texte (twoLine/battery/text) n'ont pas de titre séparé.
        BOOL shapeCarriesText = TMWidgetShapeCarriesText(readout, shape);
        NSString *title = shapeCarriesText ? @"" : readout[@"title"];
        if ([title length]) {
            item.button.attributedTitle = TMMenuBarTitle(title, readout[@"valueTemplate"],
                                                         (TMSeverity)[readout[@"severity"] integerValue], scale);
            item.button.imagePosition = NSImageLeading;
        } else {
            item.button.attributedTitle = [[NSAttributedString alloc] initWithString:@""];
            item.button.imagePosition = NSImageOnly;
        }
        item.button.image.accessibilityDescription = TMMenuBarWidgetLabel(wid);
    }];
}

// Sans moniteur (seuls des widgets de comptes sont actifs, voir startSystemMonitor), un snapshot
// vide suffit : leurs familles sont injectées. Avant, ces widgets restaient au tiret.
- (void)updateMenuBarWidgetsFromMonitor {
    if (!self.widgetItems.count) return;
    [self updateMenuBarWidgets:self.systemMonitor ? [self.systemMonitor snapshot] : @{}];
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
        NSString *fam = @"cpu", *key = @"total";
        if ([metric isEqualToString:@"system:temp"]) { fam = @"sensors"; key = @"tempC"; }
        else if ([metric isEqualToString:@"system:battery"]) { fam = @"battery"; key = @"percent"; }
        for (NSDictionary *family in [self.systemMonitor snapshot][@"families"]) {
            if ([family[@"id"] isEqualToString:fam]) {
                NSArray *series = family[@"series"][key];
                return [series isKindOfClass:NSArray.class] ? series : @[];
            }
        }
        return @[];
    }

    BOOL (^matches)(NSString *) = ^BOOL(NSString *key) {
        return TMHistoryKeyMatchesMetric(key, metric);
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

- (NSString *)metricForProvider:(NSString *)provider {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    return TMProviderMenuMetric(provider,[defaults dictionaryForKey:@"providerMenuMetrics"] ?: @{},
        [defaults stringForKey:@"menuBarMetric"]);
}

- (void)updateStatusMenu {
    NSArray *accounts = [self accountPayloadList];

    NSString *openAIStyle=[self iconStyleForProvider:@"openai"], *claudeStyle=[self iconStyleForProvider:@"claude"];
    NSDictionary *openAI=TMResolveMenuBarMetric([self metricForProvider:@"openai"],accounts);
    NSDictionary *claude=TMResolveMenuBarMetric([self metricForProvider:@"claude"],accounts);
    NSMutableArray *selected=[NSMutableArray array];
    for (NSString *provider in @[@"openai",@"claude"]) {
        NSDictionary *quota=[provider isEqual:@"openai"] ? openAI : claude;
        [selected addObject:quota ? TMTP(@"m.tooltip.remaining", @{
            @"provider": [provider isEqual:@"openai"] ? @"OpenAI" : @"Claude",
            @"label": TMTranslateQuotaLabel(quota[@"label"]), @"short": TMTranslateFR(quota[@"shortLabel"]),
            @"v": [NSString stringWithFormat:@"%.0f", 100-MIN(100,MAX(0,TMNumber(quota[@"usedPercent"])))]}) :
            TMTP(@"m.tooltip.unavailable", @{@"provider": provider})];
    }
    self.statusItem.button.toolTip=[selected componentsJoinedByString:@"\n"];
    self.statusItem.button.accessibilityLabel=[self.statusItem.button.toolTip stringByAppendingString:TMT(@"m.accessibility")];
    NSNumber *a=openAI ? @(1-TMNumber(openAI[@"usedPercent"])/100) : nil;
    NSNumber *c=claude ? @(1-TMNumber(claude[@"usedPercent"])/100) : nil;
    CGFloat layoutScale=[self menuBarIconScale], layoutSpacing=[self menuBarIconSpacing];
    NSDictionary *signature=@{@"openai":openAIStyle,@"claude":claudeStyle,@"a":a ?: NSNull.null,@"c":c ?: NSNull.null,@"openAIAccount":openAI[@"accountId"] ?: @"",@"claudeAccount":claude[@"accountId"] ?: @"",@"scale":@(layoutScale),@"spacing":@(layoutSpacing)};
    if ([self.statusMenuSignature isEqual:signature]) return;
    self.statusMenuSignature=signature;
    // One native item keeps the two independently configured icons adjacent, even near a notch.
    NSImage *left=TMProviderGauge(openAIStyle,a,YES), *right=TMProviderGauge(claudeStyle,c,NO);
    NSImage *pair=[NSImage imageWithSize:NSMakeSize(44,18) flipped:NO drawingHandler:^BOOL(NSRect rect){
        [left drawInRect:NSMakeRect(0,0,18,18)];
        [right drawInRect:NSMakeRect(26,0,18,18)];
        return YES;
    }];
    pair.template=NO;
    NSImage *laidOut=TMMenuBarImageWithLayout(pair,layoutScale,layoutSpacing);  // identique à `pair` aux réglages par défaut
    self.statusItem.button.image=laidOut;
    self.statusItem.button.imagePosition=NSImageOnly;
    self.statusItem.button.attributedTitle=[[NSAttributedString alloc] initWithString:@""];
    self.statusItem.button.title=@"";
    self.statusItem.length=laidOut.size.width+12;  // 56 pour la paire 44 pt par défaut
}

#pragma mark - Taille et espacement des icônes

- (CGFloat)menuBarIconScale {
    return TMMenuBarIconScaleFromValue([NSUserDefaults.standardUserDefaults objectForKey:@"menuBarIconScale"]);
}

- (CGFloat)menuBarIconSpacing {
    return TMMenuBarIconSpacingFromValue([NSUserDefaults.standardUserDefaults objectForKey:@"menuBarIconSpacing"]);
}

- (NSString *)iconStyleForProvider:(NSString *)provider {
    NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
    NSString *style=[defaults stringForKey:[@"menuBarIconStyle." stringByAppendingString:provider]];
    if ([TMIconDesignIDs() containsObject:style]) return style;
    // Clé héritée de l'époque d'un seul dessin pour les deux fournisseurs : sans ce repli, une
    // installation qui n'a jamais rouvert les Réglages retombait sur l'anneau épais sans prévenir.
    NSString *legacy=[defaults stringForKey:@"menuBarIconStyle"];
    return [TMIconDesignIDs() containsObject:legacy] ? legacy : @"boldRing";
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
    [self showPopoverFromButton:self.statusItem.button];
}

// Le popover est partagé par toutes les icônes (jauge quota et widgets système) : on l'ancre sous
// le bouton réellement cliqué, pas systématiquement sous la jauge.
- (void)showPopoverFromButton:(NSButton *)button {
    if (!button) button = self.statusItem.button;
    [self.statusPopover showRelativeToRect:button.bounds ofView:button preferredEdge:NSRectEdgeMinY];
    [self startSystemMonitor];
    [self refresh:nil];
}

- (void)statusPopoverDidClose:(NSNotification *)notification {
    (void)notification;
    [self startSystemMonitor];
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

#pragma mark - Luminosité des écrans

// Un cran de touche F1/F2, appliqué à tous les écrans pilotables ensemble — la touche physique
// règle l'ambiance générale du poste, contrairement aux curseurs de l'onglet Écrans/du popover
// qui restent indépendants (voir design). Valeur alignée sur le pas habituel de macOS.
static const double TMBrightnessKeyStepPercent = 6.0;

- (BOOL)brightnessKeysEnabled {
    return [NSUserDefaults.standardUserDefaults boolForKey:@"brightnessKeysEnabled"];
}

// Relit l'écran interne après coup : quand c'est macOS qui l'a réglé, la valeur réelle n'arrive
// qu'APRÈS l'événement — lire tout de suite rendrait l'ancienne.
- (void)scheduleBuiltinBrightnessSync {
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.06 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [weakSelf.displayManager syncBuiltinDisplaysFromHardware];
        [weakSelf scheduleBrightnessPush];
    });
}

// Rafraîchit les curseurs APRÈS coup, une fois par rafale d'appuis. pushData recalcule tout le
// payload (XPC vers smd, validation de signature du service capot…) : mesuré jusqu'à 3,2 s.
// Appelé dans le callback du tap, il retenait chaque appui suivant, puis la file se vidait d'un
// coup — la luminosité « continuait à monter toute seule » après deux ou trois appuis rapides.
- (void)scheduleBrightnessPush {
    __weak typeof(self) weakSelf = self;
    dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) strongSelf = weakSelf;
        if (!strongSelf || strongSelf.brightnessPushPending) return;
        strongSelf.brightnessPushPending = YES;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.25 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            weakSelf.brightnessPushPending = NO;
            [weakSelf pushData];
        });
    });
}

// Un cran de F1/F2 sur le SEUL écran survolé par la souris — comme les curseurs de l'onglet
// Écrans, un écran à la fois. Retourne YES si Status a réglé l'écran lui-même : l'appelant doit
// alors empêcher macOS d'agir en plus (sinon l'écran interne bougerait aussi).
//   — souris sur l'écran interne, ou cible inconnue : on laisse macOS faire, on relit ensuite ;
//   — souris sur un externe pilotable : on applique le pas nous-mêmes.
- (BOOL)applyBrightnessStepIncrease:(BOOL)increase {
    TMDisplay *target = [self.displayManager displayUnderMouse];
    if (!target || target.kind == TMDisplayKindBuiltin) {
        [self scheduleBuiltinBrightnessSync];
        return NO;
    }
    if (!target.available || !target.brightnessPercent) return NO;  // écran sans réponse : rien à régler
    double next = TMSteppedBrightness(target.brightnessPercent.doubleValue, increase, TMBrightnessKeyStepPercent);
    if (![target setBrightnessPercent:next]) return NO;
    [self scheduleBrightnessPush];
    return YES;
}

#pragma mark Interception des touches F1/F2

// NX_SUBTYPE_AUX_CONTROL_BUTTONS = 8. data1 empaquette (codeTouche << 16 | étatTouche << 8 | …) ;
// 0x0A signale un appui (down), y compris en répétition. Même mécanisme que celui utilisé par la
// plupart des utilitaires qui interceptent les touches média — non documenté par Apple, mais
// stable depuis des années.
static BOOL TMDecodeBrightnessKey(NSEvent *event, BOOL *outIncrease, BOOL *outIsDown) {
    if (event.subtype != 8) return NO;
    NSInteger data1 = event.data1;
    int keyCode = (int)((data1 & 0xFFFF0000) >> 16);
    int keyState = (int)((data1 & 0x0000FF00) >> 8);
    if (keyCode == NX_KEYTYPE_BRIGHTNESS_UP) *outIncrease = YES;
    else if (keyCode == NX_KEYTYPE_BRIGHTNESS_DOWN) *outIncrease = NO;
    else return NO;
    *outIsDown = (keyState == 0x0A);
    return YES;
}

- (void)reenableBrightnessTap { if (self.brightnessTap) CGEventTapEnable(self.brightnessTap, true); }

// Chemin privilégié : un tap CoreGraphics, seul moyen d'EMPÊCHER macOS de régler l'écran interne
// quand la souris est ailleurs. Sans lui, la touche réglerait toujours l'interne en plus de
// l'externe visé — exactement ce qu'on cherche à supprimer.
// Le callback s'exécute sur un thread dédié (voir installBrightnessTap) et ne fait que le strict
// nécessaire — choisir l'écran, écrire la luminosité, quelques millisecondes : tant qu'il n'a pas
// rendu la main, les touches système suivantes attendent derrière lui.
static CGEventRef TMBrightnessTapCallback(CGEventTapProxy proxy, CGEventType type, CGEventRef event, void *context) {
    TMAppDelegate *delegate = (__bridge TMAppDelegate *)context;
    if (type == kCGEventTapDisabledByTimeout || type == kCGEventTapDisabledByUserInput) {
        [delegate reenableBrightnessTap];
        return event;
    }
    NSEvent *nsEvent = [NSEvent eventWithCGEvent:event];
    BOOL increase = NO, isDown = NO;
    if (!nsEvent || !TMDecodeBrightnessKey(nsEvent, &increase, &isDown)) return event;

    // Le relâchement passe TOUJOURS. macOS répète lui-même la touche, en aval du tap, tant qu'il
    // n'a pas vu son relâchement (vérifié : un appui sans relâchement mène l'écran de 69 % à 0 %
    // en 1,5 s). L'ancien code avalait le relâchement dès que l'appui précédent avait été
    // consommé ; si l'appui, lui, était passé (tap suspendu par macOS pendant un callback lent),
    // la luminosité filait toute seule. Un relâchement orphelin, lui, est sans effet (vérifié).
    if (!isDown) return event;
    return [delegate applyBrightnessStepIncrease:increase] ? NULL : event;
}

// Thread dédié plutôt que la boucle principale : celle-ci est régulièrement occupée (tick du
// moniteur, quotas, rendu des WebView), et un appui reçu pendant ce temps était appliqué en retard.
- (BOOL)installBrightnessTap {
    if (!AXIsProcessTrusted()) return NO;  // sans Accessibilité, pas de tap : repli sur les moniteurs
    self.brightnessTap = CGEventTapCreate(kCGHIDEventTap, kCGHeadInsertEventTap, kCGEventTapOptionDefault,
                                          CGEventMaskBit(NX_SYSDEFINED), TMBrightnessTapCallback,
                                          (__bridge void *)self);
    if (!self.brightnessTap) return NO;  // permission listée mais pas effective
    self.brightnessTapSource = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, self.brightnessTap, 0);
    CFRunLoopSourceRef source = self.brightnessTapSource;
    dispatch_semaphore_t ready = dispatch_semaphore_create(0);
    __weak typeof(self) weakSelf = self;
    NSThread *thread = [[NSThread alloc] initWithBlock:^{
        CFRunLoopRef runLoop = CFRunLoopGetCurrent();
        weakSelf.brightnessTapRunLoop = runLoop;
        CFRunLoopAddSource(runLoop, source, kCFRunLoopCommonModes);
        dispatch_semaphore_signal(ready);
        CFRunLoopRun();  // rend la main quand removeBrightnessKeyMonitor arrête la boucle
    }];
    thread.name = @"com.raphael.status.brightness-keys";
    thread.qualityOfService = NSQualityOfServiceUserInteractive;
    self.brightnessTapThread = thread;
    [thread start];
    dispatch_semaphore_wait(ready, DISPATCH_TIME_FOREVER);
    CGEventTapEnable(self.brightnessTap, true);
    return YES;
}

// Repli sans Accessibilité : on observe sans pouvoir consommer. macOS règle alors l'écran interne
// quoi qu'il arrive — on le remet donc à sa valeur d'avant dès que la cible était un externe.
// Visible (l'indicateur macOS s'affiche une fraction de seconde), mais l'écran interne retrouve
// sa luminosité : c'est le comportement demandé, au mieux de ce que permet l'API publique.
- (void)handleSystemDefinedEvent:(NSEvent *)event {
    BOOL increase = NO, isDown = NO;
    if (!TMDecodeBrightnessKey(event, &increase, &isDown) || !isDown) return;
    TMDisplay *builtin = [self.displayManager builtinDisplay];
    NSNumber *before = builtin.brightnessPercent;
    if (![self applyBrightnessStepIncrease:increase]) return;  // cible = interne : macOS a raison de faire
    if (!builtin || !before) return;
    __weak typeof(self) weakSelf = self;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.12 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        [builtin setBrightnessPercent:before.doubleValue];
        [weakSelf scheduleBrightnessPush];
    });
}

- (void)installBrightnessKeyMonitor {
    [self removeBrightnessKeyMonitor];
    if (![self brightnessKeysEnabled]) return;
    if ([self installBrightnessTap]) return;
    __weak typeof(self) weakSelf = self;
    self.brightnessGlobalMonitor = [NSEvent addGlobalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                                                          handler:^(NSEvent *event) {
        [weakSelf handleSystemDefinedEvent:event];
    }];
    self.brightnessLocalMonitor = [NSEvent addLocalMonitorForEventsMatchingMask:NSEventMaskSystemDefined
                                                                        handler:^NSEvent *(NSEvent *event) {
        [weakSelf handleSystemDefinedEvent:event];
        return event;
    }];
}

- (void)removeBrightnessKeyMonitor {
    if (self.brightnessGlobalMonitor) { [NSEvent removeMonitor:self.brightnessGlobalMonitor]; self.brightnessGlobalMonitor = nil; }
    if (self.brightnessLocalMonitor) { [NSEvent removeMonitor:self.brightnessLocalMonitor]; self.brightnessLocalMonitor = nil; }
    if (self.brightnessTap) CGEventTapEnable(self.brightnessTap, false);
    if (self.brightnessTapRunLoop) {
        if (self.brightnessTapSource) CFRunLoopRemoveSource(self.brightnessTapRunLoop, self.brightnessTapSource, kCFRunLoopCommonModes);
        CFRunLoopStop(self.brightnessTapRunLoop);
        self.brightnessTapRunLoop = NULL;
        self.brightnessTapThread = nil;
    }
    if (self.brightnessTapSource) { CFRelease(self.brightnessTapSource); self.brightnessTapSource = NULL; }
    if (self.brightnessTap) {
        CFMachPortInvalidate(self.brightnessTap);
        CFRelease(self.brightnessTap); self.brightnessTap = NULL;
    }
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
    if (self.dashboardStale) [self pushData];
    [NSApp activateIgnoringOtherApps:YES];
    [self startSystemMonitor];
}

- (void)dashboardWillClose:(NSNotification *)notification {
    (void)notification;
    [self startSystemMonitor];
}

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    // Une webview qui (re)charge repart sans état : le prochain payload métriques doit être complet.
    if (webView == self.widgetWebView) { self.widgetWebReady = YES; [self pushWidgetMetrics]; return; }
    if (webView == self.menuWebView) { self.menuWebReady = YES; self.popoverMetricsPrimed = NO; }
    else { self.webReady = YES; self.dashboardMetricsPrimed = NO; }
    [self pushData];
}

- (void)userContentController:(WKUserContentController *)userContentController didReceiveScriptMessage:(WKScriptMessage *)message {
    NSDictionary *body = [message.body isKindOfClass:NSDictionary.class] ? message.body : nil;
    NSString *action = body ? body[@"action"] : message.body;
    if (![action isKindOfClass:NSString.class]) return;  // message mal formé : jamais isEqualToString: sur autre chose
    if ([action isEqualToString:@"refresh"]) [self refresh:self];  // explicit click: bypass backoff
    // Un clic dans le popover vaut épinglage, comme un clic sur l'icône (voir toggleStatusPopover).
    if ([action isEqualToString:@"pinPopover"]) {
        [self.hoverCloseTimer invalidate]; self.hoverCloseTimer = nil;
        self.popoverOpenedByHover = NO;
    }
    if ([action isEqualToString:@"toggleLaunchAtLogin"]) [self toggleLaunchAtLogin];
    if ([action isEqualToString:@"toggleHoverPopover"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![self hoverPopoverEnabled] forKey:@"hoverPopover"];
        [self pushData];
    }
    if ([action isEqualToString:@"setMenuBarMetric"]) {
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"lowest";
        NSUserDefaults *defaults=NSUserDefaults.standardUserDefaults;
        NSMutableDictionary *selections=[NSMutableDictionary dictionary];
        for (NSString *provider in @[@"openai",@"claude"])
            selections[provider]=[self metricForProvider:provider];
        NSArray *parts=[value componentsSeparatedByString:@":"];
        NSString *provider=[value hasPrefix:@"acct:"] && parts.count==4 ? parts[1] : parts.firstObject;
        if ([@[@"openai",@"claude"] containsObject:provider])
            selections[provider]=TMProviderMenuMetric(provider,@{provider:value},nil);
        [defaults setObject:selections forKey:@"providerMenuMetrics"];
        [defaults setObject:value forKey:@"menuBarMetric"];
        [self startSystemMonitor];
        [self pushData];
    }
    if ([action isEqualToString:@"setTheme"]) {
        // Entrée non fiable (vient de la webview) : seuls les identifiants de themes.css et Resources/themes/*.css
        // sont acceptés, sinon un thème mal orthographié figerait l'app sur les jetons par
        // défaut de :root sans jamais le dire.
        static NSSet<NSString *> *validThemes;
        static dispatch_once_t onceToken;
        dispatch_once(&onceToken, ^{
            validThemes = [NSSet setWithArray:@[@"blueprint", @"phosphore", @"synthwave", @"circuit", @"holograme", @"ion",
                                                    @"moderne", @"dark", @"neon", @"bento", @"widget"]];
        });
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"";
        if ([validThemes containsObject:value]) {
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"theme"];
            [self pushData];
        }
    }
    if ([action isEqualToString:@"setLanguage"]) {
        // Entrée non fiable (vient de la webview) : « auto » ou l'une des langues livrées.
        NSString *value = [body[@"value"] isKindOfClass:NSString.class] ? body[@"value"] : @"";
        if ([value isEqualToString:@"auto"] || [TMSupportedLanguages() containsObject:value]) {
            [NSUserDefaults.standardUserDefaults setObject:value forKey:@"language"];
            [self applyLanguageChange];
        }
    }
    if ([action isEqualToString:@"toggleKeyboardLock"]) {
        [self.statusPopover close];  // l'overlay va tout recouvrir ; un popover transient resterait orphelin
        [self.keyboardLock toggle];
    }
    if ([action isEqualToString:@"checkForUpdates"]) [self.updater checkForUpdates];
    if ([action isEqualToString:@"toggleAutoUpdates"]) {
        self.updater.automatic = !self.updater.automatic;
        [self pushData];
    }
    if ([action isEqualToString:@"toggleGlobalShortcut"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"globalShortcutEnabled"] forKey:@"globalShortcutEnabled"];
        [self installGlobalShortcut];
        [self pushData];
    }
    if ([action isEqualToString:@"exportHistoryCSV"]) [self exportHistoryCSV];
    if ([action isEqualToString:@"setMenuBarIconColor"]) {
        [NSUserDefaults.standardUserDefaults setObject:body[@"value"] forKey:@"menuBarIconColor"];
        [self updateStatusMenu];
        [self pushData];
    }
    if ([action isEqualToString:@"setSystemMenuBarSpacing"]) {
        // Réglage macOS global (toutes les apps), appliqué à la prochaine ouverture de session. Seul un
        // préréglage connu écrit quelque chose ; « normal » supprime les deux clés (réglage d'origine).
        NSDictionary<NSString *, NSNumber *> *values = TMSystemSpacingValues(body[@"preset"]);
        if (values) {
            TMWriteSystemStatusItemPref(@"NSStatusItemSpacing", values[@"spacing"]);
            TMWriteSystemStatusItemPref(@"NSStatusItemSelectionPadding", values[@"padding"]);
            [self pushData];
        }
    }
    if ([action isEqualToString:@"setMenuBarIconLayout"]) {
        // Valeurs validées contre les listes autorisées : tout le reste est ignoré (une valeur
        // inconnue ne doit ni changer le réglage ni le remettre au défaut).
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        BOOL changed = NO;
        id scale = body[@"scale"], spacing = body[@"spacing"];
        if (TMMenuBarIconScaleIsAllowed(scale)) {
            [defaults setDouble:TMMenuBarIconScaleFromValue(scale) forKey:@"menuBarIconScale"]; changed = YES;
        }
        if (TMMenuBarIconSpacingIsAllowed(spacing)) {
            [defaults setDouble:TMMenuBarIconSpacingFromValue(spacing) forKey:@"menuBarIconSpacing"]; changed = YES;
        }
        if (changed) {
            [self.widgetSignatures removeAllObjects];  // forcer le redessin des widgets…
            self.statusMenuSignature = nil;             // …et de la jauge quota
            [self updateMenuBarWidgetsFromMonitor];
            [self updateStatusMenu];
            if (self.iconPreviewItems) [self showIconPreviews];
        }
        [self pushData];
    }
    if ([action isEqualToString:@"setProviderMenuIconStyle"]) {
        NSString *provider=body[@"provider"], *style=body[@"value"];
        if ([@[@"openai",@"claude"] containsObject:provider] && [TMIconDesignIDs() containsObject:style]) {
            [NSUserDefaults.standardUserDefaults setObject:style forKey:[@"menuBarIconStyle." stringByAppendingString:provider]];
            [self closeIconPreviews]; [self updateStatusMenu]; [self pushData];
        }
    }
    if ([action isEqualToString:@"previewMenuIcons"]) {
        self.iconPreviewProvider=[body[@"provider"] isEqual:@"claude"] ? @"claude" : @"openai";
        [self showIconPreviews];
    }
    if ([action isEqualToString:@"closeMenuIconPreviews"]) [self closeIconPreviews];
    if ([action isEqualToString:@"setBrightness"]) {
        NSString *displayId = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        if (displayId) [self.displayManager setBrightnessPercent:[body[@"value"] doubleValue] forIdentifier:displayId];
        [self pushData];
    }
    if ([action isEqualToString:@"resizeWidgetPanel"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : self.currentWidgetId;
        [self applyWidgetPanelHeight:[body[@"height"] doubleValue] forWidget:wid];
    }
    if ([action isEqualToString:@"setMenuBarWidget"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        if (wid) {
            NSMutableArray *widgets = [([NSUserDefaults.standardUserDefaults arrayForKey:@"menuBarWidgets"] ?: @[]) mutableCopy];
            BOOL on = [body[@"on"] boolValue];
            if (on && ![widgets containsObject:wid]) [widgets addObject:wid];
            if (!on) [widgets removeObject:wid];
            [NSUserDefaults.standardUserDefaults setObject:widgets forKey:@"menuBarWidgets"];
            // Recréation complète plutôt qu'un simple ajout : un widget activé est ajouté en fin
            // de liste, donc à droite — or macOS place tout nouvel item à gauche. Sans cela,
            // l'ordre affiché divergerait de celui des Réglages.
            [self reorderMenuBarWidgets];
            [self startSystemMonitor];
            [self pushData];
        }
    }
    if ([action isEqualToString:@"setMenuBarWidgetStyle"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        if (wid) {
            NSMutableDictionary *config = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"menuBarWidgetConfig"] ?: @{}) mutableCopy];
            NSMutableDictionary *one = [([config[wid] isKindOfClass:NSDictionary.class] ? config[wid] : @{}) mutableCopy];
            if ([body[@"shape"] isKindOfClass:NSString.class]) one[@"shape"] = body[@"shape"];
            if ([body[@"color"] isKindOfClass:NSString.class]) one[@"color"] = body[@"color"];
            config[wid] = one;
            [NSUserDefaults.standardUserDefaults setObject:config forKey:@"menuBarWidgetConfig"];
            [self refreshQuotaWidgetFamilies];        // la forme choisie décide si la série est lue
            [self updateMenuBarWidgetsFromMonitor];  // redessine tout de suite avec le nouveau style
            [self pushData];
        }
    }
    if ([action isEqualToString:@"moveMenuBarWidget"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        NSInteger delta = [body[@"delta"] integerValue];
        if (wid && delta) {
            NSArray *moved = TMArrayByMovingItem([self enabledWidgets], wid, delta);
            [NSUserDefaults.standardUserDefaults setObject:moved forKey:@"menuBarWidgets"];
            [self reorderMenuBarWidgets];
            [self pushData];
        }
    }
    // Contenu d'un panneau d'info : chaque section (top processus, répartition…) est activable
    // indépendamment par widget. Absent = affiché (défaut). Stocké dans widgetPanelConfig.
    if ([action isEqualToString:@"setWidgetPanelSection"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        NSString *section = [body[@"section"] isKindOfClass:NSString.class] ? body[@"section"] : nil;
        if (wid && section) {
            NSMutableDictionary *config = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetPanelConfig"] ?: @{}) mutableCopy];
            NSMutableDictionary *one = [([config[wid] isKindOfClass:NSDictionary.class] ? config[wid] : @{}) mutableCopy];
            one[section] = @([body[@"on"] boolValue]);
            config[wid] = one;
            [NSUserDefaults.standardUserDefaults setObject:config forKey:@"widgetPanelConfig"];
            [self pushWidgetMetrics];  // rafraîchit le panneau ouvert avec le nouveau contenu
            [self pushData];
        }
    }
    // Niveau de détail d'un panneau d'info (0 résumé · 1 détaillé · 2 hyper détaillé), mémorisé par
    // widget dans widgetDetail. Identifiant limité aux widgets système, niveau borné à 0…2.
    if ([action isEqualToString:@"setWidgetDetail"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : nil;
        // « grouped » : niveau global du popup regroupé, en plus des ids de widgets.
        if (wid && ([wid isEqualToString:TMGroupedWidgetId] || ([TMMenuBarWidgetIDs() containsObject:wid] && !TMWidgetUsesAccounts(wid)))
            && [body[@"level"] isKindOfClass:NSNumber.class]) {
            NSInteger level = MAX(0, MIN(2, [body[@"level"] integerValue]));
            NSMutableDictionary *detail = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetDetail"] ?: @{}) mutableCopy];
            detail[wid] = @(level);
            [NSUserDefaults.standardUserDefaults setObject:detail forKey:@"widgetDetail"];
            [self pushWidgetMetrics];  // rafraîchit le panneau ouvert au nouveau niveau
        }
    }
    // Popups des widgets : « separate » (un panneau par widget, défaut) ou « grouped » (un seul popup).
    // Un popup ouvert dans l'ancien mode est fermé : sa largeur et son contenu n'ont plus de sens.
    if ([action isEqualToString:@"setWidgetPopupMode"]) {
        NSString *mode = [body[@"mode"] isKindOfClass:NSString.class] ? body[@"mode"] : nil;
        if ([mode isEqualToString:@"separate"] || [mode isEqualToString:@"grouped"]) {
            [NSUserDefaults.standardUserDefaults setObject:mode forKey:@"widgetPopupMode"];
            [self.widgetPopover close];
            [self pushData];
        }
    }
    // Alerte système : activation et/ou seuil. Le seuil est borné pour rester utile — une alerte
    // température à 5 °C ou un disque à 300 % ne préviendrait de rien.
    if ([action isEqualToString:@"setAlert"]) {
        NSString *key = [body[@"key"] isKindOfClass:NSString.class] ? body[@"key"] : nil;
        if (key && TMAlertDefaults()[key]) {
            NSMutableDictionary *alerts = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"alerts"] ?: @{}) mutableCopy];
            double current = 0;
            BOOL enabled = [self alertEnabled:key threshold:&current];
            NSMutableDictionary *one = [@{ @"on": @(enabled), @"threshold": @(current) } mutableCopy];
            if ([body[@"on"] isKindOfClass:NSNumber.class]) one[@"on"] = @([body[@"on"] boolValue]);
            if ([body[@"threshold"] isKindOfClass:NSNumber.class]) {
                double value = [body[@"threshold"] doubleValue];
                double lower = [key isEqualToString:@"memory"] ? 2 : ([key isEqualToString:@"apiCredit"] ? 1 : 50);
                double upper = [key isEqualToString:@"memory"] ? 4 : ([key isEqualToString:@"temp"] ? 110
                             : [key isEqualToString:@"apiCredit"] ? 10000 : 99);
                one[@"threshold"] = @(MIN(upper, MAX(lower, round(value))));
            }
            alerts[key] = one;
            [NSUserDefaults.standardUserDefaults setObject:alerts forKey:@"alerts"];
            // Un seuil qui change remet l'hystérésis à zéro : sinon une alerte « déjà déclenchée »
            // au-dessus de l'ancien seuil resterait muette sous le nouveau.
            self.alertTempAbove = self.alertDiskAbove = self.alertRAMAbove = NO;
            [self pushData];
        }
    }
    if ([action isEqualToString:@"openResetSource"]) {
        NSDictionary *sources = @{
            @"claude-study":@"https://claude-resets.com/",
            @"claude-help":@"https://support.claude.com/en/articles/9797557-usage-limit-best-practices",
            @"codex-monitor":@"https://codex-reset.com/",
            @"codex-history":@"https://savemetibo.com/"};
        NSString *source = [body[@"source"] isKindOfClass:NSString.class] ? sources[body[@"source"]] : nil;
        if (source) [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:source]];
    }
    if ([action isEqualToString:@"toggleBrightnessKeys"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"brightnessKeysEnabled"] forKey:@"brightnessKeysEnabled"];
        [self installBrightnessKeyMonitor];
        [self pushData];
    }
    if ([action isEqualToString:@"setMetricsInterval"]) {
        [NSUserDefaults.standardUserDefaults setInteger:[body[@"value"] integerValue] forKey:@"metricsIntervalSeconds"];
        [self startSystemMonitor];  // recrée le timer à la nouvelle cadence
        [self pushData];
    }
    if ([action isEqualToString:@"setQuotaRefreshInterval"]) {
        NSInteger seconds = [body[@"value"] integerValue];
        if ([@[@30, @60, @120, @300] containsObject:@(seconds)]) {
            [NSUserDefaults.standardUserDefaults setInteger:seconds forKey:@"refreshIntervalSeconds"];
            [self scheduleRefresh];
            [self pushData];
        }
    }
    if ([action isEqualToString:@"setMonitorVisible"]) {
        self.monitorViewActive = [body[@"visible"] boolValue];
        [self startSystemMonitor];
    }
    if ([action isEqualToString:@"setMacToolsVisible"]) {
        self.macToolsVisible = [body[@"visible"] boolValue];
        [self startSystemMonitor];
    }
    if ([action isEqualToString:@"toggleMonitorInBackground"]) {
        NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
        [defaults setBool:![defaults boolForKey:@"monitorInBackground"] forKey:@"monitorInBackground"];
        [self startSystemMonitor];
        [self pushData];
    }
    if ([action isEqualToString:@"openNotificationSettings"]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.Notifications-Settings.extension"]];
    }
    if ([action isEqualToString:@"openStorageSettings"]) {
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"x-apple.systempreferences:com.apple.settings.Storage"]];
    }
    if ([action isEqualToString:@"openDashboard"]) [self openDashboard:nil];
    if ([action isEqualToString:@"quit"]) [NSApp terminate:nil];
    if ([action isEqualToString:@"authorizeLidMode"]) [self.lidMode requestAuthorization];
    if ([action isEqualToString:@"startLidMode"]) {
        NSNumber *minutes=[body[@"minutes"] isKindOfClass:NSNumber.class] ? body[@"minutes"] : nil;
        if (minutes && minutes.doubleValue==minutes.integerValue && minutes.integerValue>=1 && minutes.integerValue<=240)
            [self.lidMode startMinutes:minutes.integerValue];
    }
    if ([action isEqualToString:@"stopLidMode"]) [self.lidMode stop];
    if ([action isEqualToString:@"startFanBoost"]) {
        NSNumber *minutes=[body[@"minutes"] isKindOfClass:NSNumber.class] ? body[@"minutes"] : nil;
        if (minutes && minutes.doubleValue==minutes.integerValue && minutes.integerValue>=1 && minutes.integerValue<=60)
        {
            NSNumber *percent=[body[@"percent"] isKindOfClass:NSNumber.class] ? body[@"percent"] : @100;
            if (percent.integerValue>=50 && percent.integerValue<=100)
                [self.lidMode startFanBoostMinutes:minutes.integerValue percent:percent.integerValue];
        }
    }
    if ([action isEqualToString:@"stopFanBoost"]) [self.lidMode stopFanBoost];
    if ([action isEqualToString:@"showLidMode"]) {
        [self openDashboard:nil];
        [self.webView evaluateJavaScript:@"settingsTab='system'; goToView('settings');" completionHandler:nil];
    }
    if ([action isEqualToString:@"toggleAwake"]) {
        self.awake.enabled = !self.awake.isEnabled;
        [self pushData];
    }
    if ([self handleApiAction:action body:body]) return;
    // Actions de compte : toutes portent un accountId, sauf l'ajout qui porte un fournisseur.
    NSString *accountId = [body[@"accountId"] isKindOfClass:NSString.class] ? body[@"accountId"] : @"";
    if ([action isEqualToString:@"addAccount"]) {
        NSString *provider = [body[@"provider"] isKindOfClass:NSString.class] ? body[@"provider"] : @"";
        if (provider.length) [self addAccountForProvider:provider];
    }
    if (!accountId.length) return;
    if ([action isEqualToString:@"loginOpenAI"]) [self loginOpenAIAccount:accountId];
    if ([action isEqualToString:@"logoutOpenAI"]) [self confirmLogoutOpenAIAccount:accountId];
    if ([action isEqualToString:@"connectClaudeWeb"]) [self connectClaudeWebAccount:accountId];
    if ([action isEqualToString:@"connectClaudeCode"]) [self connectClaudeCodeAccount:accountId];
    if ([action isEqualToString:@"openClaudeCode"]) [self openClaudeCodeAccount:accountId];
    if ([action isEqualToString:@"disconnectClaudeCode"]) [self disconnectClaudeCodeAccount:accountId];
    if ([action isEqualToString:@"configureClaudeCookie"]) [self configureClaudeCookieForAccount:accountId];
    if ([action isEqualToString:@"removeAccount"]) [self confirmRemoveAccount:accountId];
    if ([action isEqualToString:@"renameAccount"]) [self renameAccount:accountId];
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
            alert.messageText = enabled ? TMT(@"a.login.disableFail") : TMT(@"a.login.enableFail");
            // Unsigned/ad-hoc builds moved around the disk are frequently refused by SMAppService.
            alert.informativeText = TMTP(@"a.login.hint", @{@"error": error.localizedDescription ?: @""});
            [alert beginSheetModalForWindow:self.window completionHandler:nil];
        }
        [self pushData];
    }
}

- (NSDictionary *)payload {
    NSArray *history = TMLoadHistory();
    return @{
        @"accounts": [self accountPayloadList],
        @"accountLimit": @(TMMaxAccountsPerProvider),
        @"apiAccounts": [self apiAccountPayloadList],
        @"apiAccountLimit": @(TMMaxApiAccountsPerProvider),
        @"history": TMHistoryForDisplay(history, NSDate.date.timeIntervalSince1970),
        @"displays": [self.displayManager snapshot] ?: @[],
        @"costs": [self costPayload],
        @"metricsLog": self.metricsLog ?: @[],  // 24 h, une ligne/minute — cadence lente, pas dans pushMetrics
        @"prefs": @{
            @"launchAtLogin": @([self launchAtLoginEnabled]),
            @"menuBarMetric": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] ?: @"claude:weekly",
            @"hoverPopover": @([self hoverPopoverEnabled]),
            @"metricsInterval": @([self metricsInterval]),
            @"monitorInBackground": @([NSUserDefaults.standardUserDefaults boolForKey:@"monitorInBackground"]),
            @"quotaRefreshIntervalSeconds": @([self quotaRefreshIntervalSeconds]),
            @"apiRefreshIntervalSeconds": @([self apiRefreshIntervalSeconds]),
            @"providerMenuMetrics":@{@"openai":[self metricForProvider:@"openai"],@"claude":[self metricForProvider:@"claude"]},
            @"providerIconStyles":@{@"openai":[self iconStyleForProvider:@"openai"],@"claude":[self iconStyleForProvider:@"claude"]},
            @"menuBarIconColor": [NSUserDefaults.standardUserDefaults stringForKey:@"menuBarIconColor"] ?: @"auto",
            @"systemMenuBarSpacing": TMSystemSpacingPresetFor(TMReadSystemStatusItemPref(@"NSStatusItemSpacing"),
                                                                 TMReadSystemStatusItemPref(@"NSStatusItemSelectionPadding")),
            @"menuBarIconScale": @([self menuBarIconScale]),
            @"menuBarIconSpacing": @([self menuBarIconSpacing]),
            @"globalShortcut": @([NSUserDefaults.standardUserDefaults boolForKey:@"globalShortcutEnabled"]),
            @"accessibilityTrusted": @(AXIsProcessTrusted()),
            @"updates": @{ @"available": @(self.updater.available), @"automatic": @(self.updater.automatic),
                           @"version": NSBundle.mainBundle.infoDictionary[@"CFBundleShortVersionString"] ?: @"" },
            @"brightnessKeys": @([self brightnessKeysEnabled]),
            @"menuBarWidgets": [NSUserDefaults.standardUserDefaults arrayForKey:@"menuBarWidgets"] ?: @[],
            @"menuBarWidgetConfig": [NSUserDefaults.standardUserDefaults dictionaryForKey:@"menuBarWidgetConfig"] ?: @{},
            @"widgetPanelConfig": [NSUserDefaults.standardUserDefaults dictionaryForKey:@"widgetPanelConfig"] ?: @{},
            @"widgetPopupMode": [self widgetPopupGrouped] ? @"grouped" : @"separate",
            @"alerts": [self alertsPayload],
            @"notificationsAuthorized": @(self.notificationsAuthorized),
            @"theme": [NSUserDefaults.standardUserDefaults stringForKey:@"theme"] ?: @"blueprint",
            @"language": [NSUserDefaults.standardUserDefaults stringForKey:@"language"] ?: @"auto"
        },
        @"tools": [self toolsPayload],
        @"backoffCount": @([self pausedAccountCount]),
        @"refreshing": @(self.refreshing), @"updatedAt": @(self.lastQuotaRefreshAt * 1000)
    };
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

// Coût équivalent API (feature 16). Le premier balayage lit ~700 Mo de logs (~20 s) : en fond,
// avec « calcul en cours ». Les suivants sont incrémentaux (~0,2 s) grâce au cache token-usage.json.
- (void)refreshCostsInBackground {
    if (self.costScanning || (self.costScanCompletedAt > 0 &&
        NSDate.date.timeIntervalSince1970 - self.costScanCompletedAt < 300)) return;
    self.costScanning = YES;
    [self pushData];  // affiche « calcul en cours » au premier passage
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        NSDictionary *scan = TMScanTerminalCosts();
        dispatch_async(dispatch_get_main_queue(), ^{
            self.costScan = scan;
            self.costScanCompletedAt = NSDate.date.timeIntervalSince1970;
            self.costScanning = NO;
            [self pushData];
        });
    });
}

// Ventilation par modèle sur une fenêtre donnée, plus les tarifs appliqués (pour l'infobulle) et
// le total de tokens non tarifés. La ventilation explique le total accentué : elle doit donc
// porter exactement sur la même fenêtre que lui, d'où le paramètre.
- (NSDictionary *)modelDetailForBuckets:(NSDictionary *)buckets since:(NSTimeInterval)startEpoch {
    NSMutableArray<NSDictionary *> *breakdown = [NSMutableArray array];
    NSMutableDictionary *prices = [NSMutableDictionary dictionary];
    double unpriced = 0;
    for (NSDictionary *row in TMModelBreakdownSince(buckets, startEpoch)) {
        if ([row[@"tokens"] doubleValue] <= 0) continue;  // pseudo-modèles à 0 token (<synthetic>…) : bruit
        [breakdown addObject:row];
        TMPrices p;
        if (row[@"cost"] && TMPricesForModel(row[@"model"], &p)) {
            prices[row[@"model"]] = @{ @"input": @(p.input), @"output": @(p.output),
                                       @"cacheRead": @(p.cacheRead), @"cacheWrite": @(p.cacheWrite),
                                       @"cacheWrite1h": @(p.cacheWrite1h) };
        } else {
            unpriced += [row[@"tokens"] doubleValue];  // modèle sans tarif : tokens comptés à part
        }
    }
    return @{ @"breakdown": breakdown, @"prices": prices, @"unpricedTokens": @(unpriced) };
}

// Coûts par fenêtre, dérivés du dernier balayage. nil tant que le premier n'a pas abouti.
- (NSDictionary *)costPayload {
    if (!self.costScan) return @{ @"scanning": @(self.costScanning) };
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSDictionary *claude = self.costScan[@"claude"], *codex = self.costScan[@"codex"];
    NSDictionary *cb = claude[@"buckets"], *xb = codex[@"buckets"];
    // Deux fenêtres affichées, bornées explicitement plutôt que « tout ce qui a été lu » : un
    // fichier modifié hier peut contenir des lignes bien plus anciennes, qui gonfleraient le
    // total 8 jours sans lui appartenir.
    NSTimeInterval since8 = now - 8 * 86400, since30 = now - 30 * 86400;
    NSDictionary *cd8 = [self modelDetailForBuckets:cb since:since8];
    NSDictionary *cd30 = [self modelDetailForBuckets:cb since:since30];
    NSDictionary *xd8 = [self modelDetailForBuckets:xb since:since8];
    NSDictionary *xd30 = [self modelDetailForBuckets:xb since:since30];
    TMFxRate *fx = [TMFxRate shared];
    // Une entrée par période : montant, ventilation par modèle et tarifs appliqués vont ensemble,
    // sans quoi le tableau parlerait d'une fenêtre et le total d'une autre.
    NSDictionary * (^period)(NSDictionary *, NSDictionary *, double) =
        ^NSDictionary *(NSDictionary *buckets, NSDictionary *detail, double startEpoch) {
        return @{ @"total": @(TMCostSince(buckets, startEpoch)),
                  @"breakdown": detail[@"breakdown"], @"prices": detail[@"prices"],
                  @"unpricedTokens": detail[@"unpricedTokens"] };
    };
    return @{
        @"scanning": @NO,
        @"asOf": TMPricesAsOfDate,
        @"eurPerUsd": @(fx.eurPerUsd),        // taux live si dispo, repli sur la constante compilée
        @"fxAsOf": fx.asOfDate,               // date du relevé de change réellement utilisé
        // Étiquette « usage terminal » côté web : le web (claude.ai, chatgpt.com) n'est pas journalisé.
        // `total8d` reste publié tel quel : le popover compact de la barre des menus le lit encore.
        @"claude": @{ @"session": @(TMCostSince(cb, now - 5 * 3600)),
                      @"weekly": @(TMCostSince(cb, now - 7 * 86400)),
                      @"total8d": @(TMCostSince(cb, since8)),
                      @"periods": @{ @"d8": period(cb, cd8, since8), @"d30": period(cb, cd30, since30) },
                      @"breakdown": cd8[@"breakdown"], @"prices": cd8[@"prices"],
                      @"unpricedTokens": cd8[@"unpricedTokens"] },
        // Codex : « approximatif » — deux signaux de tokens divergent, et des modèles sans tarif.
        @"codex": @{ @"weekly": @(TMCostSince(xb, now - 7 * 86400)),
                     @"total8d": @(TMCostSince(xb, since8)),
                     @"periods": @{ @"d8": period(xb, xd8, since8), @"d30": period(xb, xd30, since30) },
                     @"breakdown": xd8[@"breakdown"], @"prices": xd8[@"prices"],
                     @"unpricedTokens": xd8[@"unpricedTokens"] },
    };
}

// Volumes courants persistés en continu (écriture atomique), pour survivre à un redémarrage ou un
// arrêt brutal : la dernière écriture reflète toujours le dernier état affiché, rien à vider à la
// fermeture. Le collage vit dans pushData, l'unique point traversé après chaque changement de compte.
- (void)persistAccountsCache {
    NSMutableDictionary *cache = [NSMutableDictionary dictionary];
    for (NSDictionary *payload in [self accountPayloadList]) cache[payload[@"accountId"]] = payload;
    if (!cache.count) return;
    TMSaveAccountsCache(cache);
}

// Remet un compte restauré dans un état sûr : fenêtres périmées écartées, fraîcheur recalculée
// (des heures hors ligne = mesure figée), drapeaux transitoires remis à plat — le premier sondage
// réévaluera tout. Une donnée restaurée n'est jamais « en direct ».
- (NSDictionary *)sanitizedRestoredAccount:(id)raw now:(long long)now {
    if (![raw isKindOfClass:NSDictionary.class] || ![(NSDictionary *)raw count]) return nil;
    NSMutableDictionary *account = [raw mutableCopy];
    NSArray *windows = [account[@"windows"] isKindOfClass:NSArray.class] ? account[@"windows"] : @[];
    account[@"windows"] = TMDropExpiredWindows(windows);
    long long capturedAt = TMInteger(account[@"capturedAt"]);
    if (capturedAt > 0) account[@"stale"] = @(now - capturedAt > 1800);
    account[@"liveSource"] = @NO;
    account[@"connecting"] = @NO;
    account[@"error"] = @"";
    return account;
}

- (void)restoreCachedAccounts {
    NSDictionary *cache = TMLoadAccountsCache();
    if (!cache) return;
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    for (NSDictionary *account in self.accountRegistry) {
        NSString *accountId = account[@"accountId"];
        NSDictionary *restored = [self sanitizedRestoredAccount:cache[accountId] now:now];
        if (restored) [self setPayload:restored forAccount:accountId];
    }
}

- (NSDictionary *)toolsPayload {
    return @{
        @"awake": @{ @"active": @(self.awake.isEnabled) },
        @"lidMode": self.lidMode.snapshot ?: @{},
        @"keyboardLock": @{ @"state": self.keyboardLock.state == TMLockStateLocked ? @"locked"
                                    : self.keyboardLock.state == TMLockStateBlocked ? @"blocked" : @"unlocked" }
    };
}

// Recharge le dictionnaire et le pousse à toutes les surfaces web déjà créées, sans rechargement
// de page : elles se redessinent via StatusI18n.onChange. Le natif (tooltips, icônes de barre)
// repasse par pushData.
- (void)applyLanguageChange {
    TMI18nReload();
    NSData *data = [NSJSONSerialization dataWithJSONObject:TMI18nPayload() options:0 error:nil];
    NSString *script = [NSString stringWithFormat:@"window.StatusI18n && window.StatusI18n.set(%@);",
                        [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding]];
    for (WKWebView *view in @[self.webView ?: NSNull.null, self.menuWebView ?: NSNull.null,
                              self.widgetWebView ?: NSNull.null]) {
        if (![view isKindOfClass:WKWebView.class]) continue;
        TMInstallI18nScript(view);
        [view evaluateJavaScript:script completionHandler:nil];
    }
    [self pushData];
    [self pushWidgetMetrics];
}

- (void)pushTools {
    NSData *data = [NSJSONSerialization dataWithJSONObject:@{@"tools": [self toolsPayload]} options:0 error:nil];
    NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    if (self.menuWebReady)
        [self.menuWebView evaluateJavaScript:[NSString stringWithFormat:@"window.StatusMenu && window.StatusMenu.patch && window.StatusMenu.patch(%@);", json] completionHandler:nil];
    if (self.webReady && self.window.isVisible)
        [self.webView evaluateJavaScript:[NSString stringWithFormat:@"window.StatusApp && window.StatusApp.patch && window.StatusApp.patch(%@);", json] completionHandler:nil];
}

- (void)pushData {
    [self persistAccountsCache];
    NSDictionary *payload = [self payload];
    // Le tableau de bord (historique, journal 24 h, coûts : plus d'1 Mo) n'est alimenté que fenêtre
    // visible ; openDashboard le remet à jour à l'ouverture. Le popup reçoit une version allégée.
    BOOL dashboardVisible = self.webReady && self.window.isVisible;
    self.dashboardStale = !dashboardVisible;
    if (dashboardVisible) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:payload options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        NSString *script = [NSString stringWithFormat:@"window.StatusApp && window.StatusApp.update(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"Status dashboard JavaScript error: %@", error);
        }];
    }
    if (self.menuWebReady) {
        NSMutableDictionary *menu = [payload mutableCopy];
        [menu removeObjectsForKeys:@[@"history", @"metricsLog", @"costs"]];
        NSData *menuData = [NSJSONSerialization dataWithJSONObject:menu options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:menuData encoding:NSUTF8StringEncoding];
        NSString *script = [NSString stringWithFormat:@"window.StatusMenu && window.StatusMenu.update(%@);", json];
        [self.menuWebView evaluateJavaScript:script completionHandler:^(id result, NSError *error) {
            if (error) NSLog(@"Status menu JavaScript error: %@", error);
        }];
    }
    [self updateStatusMenu];
    [self refreshQuotaWidgetFamilies];       // les widgets de consommation suivent les mêmes chiffres
    [self updateMenuBarWidgetsFromMonitor];
}

#pragma mark - Moniteur système

// Le moniteur matériel reste dormant hors de sa vue, sauf demande explicite (widgets,
// métrique système épinglée ou suivi en arrière-plan). Les quotas ont leur propre cadence.
- (NSTimeInterval)metricsInterval {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:@"metricsIntervalSeconds"];
    return (seconds == 2 || seconds == 5) ? seconds : 1;
}

- (void)startSystemMonitor {
    BOOL systemWidgetEnabled = NO;
    for (NSString *widgetId in [self enabledWidgets])
        if (!TMWidgetUsesAccounts(widgetId)) { systemWidgetEnabled = YES; break; }
    BOOL needed = [NSUserDefaults.standardUserDefaults boolForKey:@"monitorInBackground"]
        || (self.monitorViewActive && self.window.isVisible)
        || (self.macToolsVisible && self.statusPopover.isShown)
        || systemWidgetEnabled
        || [[NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] hasPrefix:@"system:"];
    [self.metricsTimer invalidate];
    self.metricsTimer = nil;
    if (!needed) {
        self.systemMonitor = nil;
        self.previousProcessSample = nil;
        self.topProcesses = nil;
        self.dashboardMetricsPrimed = NO;
        self.popoverMetricsPrimed = NO;
        return;
    }
    if (!self.systemMonitor) self.systemMonitor = TMSystemMonitorCreate();
    __weak typeof(self) weakSelf = self;
    self.metricsTimer = [NSTimer scheduledTimerWithTimeInterval:[self metricsInterval] repeats:YES block:^(NSTimer *timer) {
        [weakSelf metricsTick];
    }];
    self.metricsTimer.tolerance = [self metricsInterval] * 0.2;  // macOS groupe les réveils, l'œil ne verra rien
    [self metricsTick];
}

// Valeurs par défaut des alertes. Les alertes système sont volontairement hautes : elles signalent
// un état anormal, pas une machine qui travaille. Les alertes quota (seuil « entamé » réglable,
// rappel fixe à 95 %, réinitialisation hebdo) sont le cœur du produit : actives d'office.
// `quotaReset` est un événement sans seuil — son 0 n'est qu'un remplissage de structure.
// L'utilisateur règle ou coupe chaque alerte séparément (préférence `alerts`).
static NSDictionary *TMAlertDefaults(void) {
    return @{ @"temp": @90, @"disk": @90, @"memory": @4, @"quota": @80, @"quotaReset": @0, @"apiCredit": @10 };
}

// Réglage d'une alerte : activée ? et à quel seuil ? Absent = activée au seuil par défaut, pour que
// les alertes marchent sans configuration préalable.
- (BOOL)alertEnabled:(NSString *)key threshold:(double *)outThreshold {
    NSDictionary *alerts = [NSUserDefaults.standardUserDefaults dictionaryForKey:@"alerts"];
    NSDictionary *one = [alerts[key] isKindOfClass:NSDictionary.class] ? alerts[key] : nil;
    double fallback = [TMAlertDefaults()[key] doubleValue];
    NSNumber *threshold = [one[@"threshold"] isKindOfClass:NSNumber.class] ? one[@"threshold"] : nil;
    if (outThreshold) *outThreshold = threshold ? threshold.doubleValue : fallback;
    NSNumber *on = [one[@"on"] isKindOfClass:NSNumber.class] ? one[@"on"] : nil;
    return on ? on.boolValue : YES;
}

// État résolu des trois alertes (défauts compris) pour l'interface de réglages.
- (NSDictionary *)alertsPayload {
    NSMutableDictionary *payload = [NSMutableDictionary dictionary];
    for (NSString *key in TMAlertDefaults()) {
        double threshold = 0;
        BOOL enabled = [self alertEnabled:key threshold:&threshold];
        payload[key] = @{ @"on": @(enabled), @"threshold": @(threshold) };
    }
    return payload;
}

- (void)checkSystemAlerts:(NSDictionary *)snapshot {
    NSMutableDictionary *byId = [NSMutableDictionary dictionary];
    for (NSDictionary *family in snapshot[@"families"]) byId[family[@"id"]] = family[@"now"];

    // Pression mémoire : l'échelle noyau est 1/2/4 (normale/avertissement/critique), pas un
    // pourcentage — le seuil réglable choisit donc le niveau déclencheur.
    double threshold = 0;
    BOOL above = self.alertRAMAbove;
    NSNumber *pressure = byId[@"ram"][@"pressureLevel"];
    if ([self alertEnabled:@"memory" threshold:&threshold] && pressure
        && TMThresholdShouldFire(&above, pressure.doubleValue, threshold, threshold - 2))
        [self postNotificationTitle:TMT(@"n.mem.title")
                               body:TMT(@"n.mem.body")];
    self.alertRAMAbove = above;

    above = self.alertTempAbove;
    NSNumber *temp = byId[@"sensors"][@"tempC"];
    if ([self alertEnabled:@"temp" threshold:&threshold] && temp
        && TMThresholdShouldFire(&above, temp.doubleValue, threshold, TMAlertRearmThreshold(threshold)))
        [self postNotificationTitle:TMT(@"n.temp.title")
                               body:TMTP(@"n.temp.body", @{@"v": [NSString stringWithFormat:@"%.0f", temp.doubleValue]})];
    self.alertTempAbove = above;

    above = self.alertDiskAbove;
    NSNumber *diskUsed = byId[@"disk"][@"usedPercent"];
    if ([self alertEnabled:@"disk" threshold:&threshold] && diskUsed
        && TMThresholdShouldFire(&above, diskUsed.doubleValue, threshold, TMAlertRearmThreshold(threshold)))
        [self postNotificationTitle:TMT(@"n.disk.title")
                               body:TMTP(@"n.disk.body", @{@"v": [NSString stringWithFormat:@"%.0f", diskUsed.doubleValue]})];
    self.alertDiskAbove = above;
}

// Journalise une ligne par minute dans l'historique 24 h, et sauvegarde toutes les 5 minutes.
// Tourne quelles que soient les surfaces ouvertes : c'est justement l'intérêt de pouvoir consulter
// après coup ce qui s'est passé pendant qu'on ne regardait pas.
- (void)appendLongHistory:(NSDictionary *)snapshot {
    NSTimeInterval now = [NSDate date].timeIntervalSince1970;
    if (self.metricsLogLastAppend && now - self.metricsLogLastAppend < TMLongHistoryInterval) return;
    NSDictionary *row = TMLongHistoryRow(snapshot, now);
    if (!row) return;
    self.metricsLogLastAppend = now;
    self.metricsLog = TMLongHistoryAppend(self.metricsLog, row, TMLongHistoryMaxAge,
                                          (NSUInteger)(TMLongHistoryMaxAge / TMLongHistoryInterval) + 60);
    if (now - self.metricsLogLastSave >= 300) {
        self.metricsLogLastSave = now;
        NSArray *rows = self.metricsLog;
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{ TMSaveMetricsHistory(rows); });
    }
}

- (void)metricsTick {
    [self.systemMonitor sample];
    NSDictionary *snapshot = [self.systemMonitor snapshot];
    [self checkSystemAlerts:snapshot];  // les alertes veillent même toutes surfaces fermées
    [self appendLongHistory:snapshot];  // idem : l'historique 24 h se remplit en arrière-plan
    [self updateMenuBarWidgets:snapshot];  // icônes système : toujours à jour, même surfaces fermées
    if (self.widgetPopover.isShown && self.widgetWebReady) {  // panneau d'info d'un widget ouvert
        NSDictionary *widgetPayload = [self widgetMetricsPayload];
        if (self.widgetMetricsPrimed) widgetPayload = TMMetricsDeltaPayload(widgetPayload);
        self.widgetMetricsPrimed = YES;
        NSData *data = [NSJSONSerialization dataWithJSONObject:widgetPayload options:0 error:nil];
        NSString *json = [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
        [self.widgetWebView evaluateJavaScript:[NSString stringWithFormat:@"window.StatusWidget && window.StatusWidget.updateMetrics(%@);", json] completionHandler:nil];
    } else self.widgetMetricsPrimed = NO;

    BOOL dashboardVisible = self.webReady && self.window.isVisible && self.monitorViewActive;
    BOOL popoverVisible = self.menuWebReady && self.statusPopover.isShown && self.macToolsVisible;
    BOOL widgetVisible = self.widgetPopover.isShown && self.widgetWebReady;  // panneau d'info d'un widget
    if (!dashboardVisible) self.dashboardMetricsPrimed = NO;  // fermée : le prochain envoi réamorce
    if (!popoverVisible) self.popoverMetricsPrimed = NO;
    BOOL menuBarWantsSystem = [[NSUserDefaults.standardUserDefaults stringForKey:@"menuBarMetric"] hasPrefix:@"system:"];
    if (menuBarWantsSystem) [self updateStatusMenu];
    // Le relevé des processus alimente aussi les panneaux CPU/Mémoire des widgets : on l'active dès
    // qu'une surface qui en a besoin est visible.
    if (!dashboardVisible && !widgetVisible) {
        self.previousProcessSample = nil;
        if (popoverVisible) [self pushMetrics:snapshot dashboard:NO popover:YES];
        return;
    }

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
                                           now - self.previousProcessAt, 10);  // 10 : le niveau « hyper détaillé » des panneaux en liste dix
    }
    self.previousProcessSample = processSample;
    self.previousProcessAt = now;

    NSMutableDictionary *payload = [snapshot mutableCopy];
    payload[@"processes"] = self.topProcesses ?: @[];
    payload[@"intervalSeconds"] = @([self metricsInterval]);
    [self pushMetrics:payload dashboard:dashboardVisible popover:popoverVisible];
}

- (void)pushMetrics:(NSDictionary *)payload dashboard:(BOOL)dashboard popover:(BOOL)popover {
    // Après l'amorçage (payload complet, séries incluses), chaque tick n'envoie qu'un delta :
    // sérialiser 6 × 300 points par seconde pour des séries que le client sait faire glisser
    // lui-même était le principal poste CPU d'une surface ouverte.
    NSString *(^encode)(NSDictionary *) = ^NSString *(NSDictionary *dict) {
        NSData *data = [NSJSONSerialization dataWithJSONObject:dict options:0 error:nil];
        return [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding];
    };
    NSString *fullJSON = nil, *deltaJSON = nil;  // encodés au besoin, partagés entre surfaces
    if (dashboard) {
        NSString *json = self.dashboardMetricsPrimed
            ? (deltaJSON = deltaJSON ?: encode(TMMetricsDeltaPayload(payload)))
            : (fullJSON = fullJSON ?: encode(payload));
        self.dashboardMetricsPrimed = YES;
        NSString *script = [NSString stringWithFormat:@"window.StatusApp && window.StatusApp.updateMetrics && window.StatusApp.updateMetrics(%@);", json];
        [self.webView evaluateJavaScript:script completionHandler:nil];
    }
    if (popover) {
        NSString *json = self.popoverMetricsPrimed
            ? (deltaJSON = deltaJSON ?: encode(TMMetricsDeltaPayload(payload)))
            : (fullJSON = fullJSON ?: encode(payload));
        self.popoverMetricsPrimed = YES;
        NSString *script = [NSString stringWithFormat:@"window.StatusMenu && window.StatusMenu.updateMetrics && window.StatusMenu.updateMetrics(%@);", json];
        [self.menuWebView evaluateJavaScript:script completionHandler:nil];
    }
}

- (void)scheduleRefresh {
    [self.refreshTimer invalidate];
    NSInteger seconds = [self quotaRefreshIntervalSeconds];
    // Via a block, not @selector(refresh:): NSTimer passes *itself* as the argument, which refresh:
    // would read as a non-nil sender — i.e. a manual click — and every automatic tick would clear
    // the backoff it is supposed to obey.
    __weak typeof(self) weakSelf = self;
    self.refreshTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:YES block:^(NSTimer *timer) {
        [weakSelf refresh:nil];
    }];
    self.refreshTimer.tolerance = MIN(5, seconds * 0.1);
}

- (NSInteger)quotaRefreshIntervalSeconds {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:@"refreshIntervalSeconds"];
    return [@[@30, @60, @120, @300] containsObject:@(seconds)] ? seconds : 60;
}

#pragma mark - Registre de comptes

// Le registre est la seule source de vérité sur « quels comptes existent ». Les payloads, les
// serveurs Codex et les sessions claude.ai s'y raccrochent par accountId.
- (void)loadAccountRegistry {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    NSArray *stored = TMNormalizeAccountRegistry([defaults arrayForKey:TMAccountsDefaultsKey]);
    NSDictionary *migration = TMMigrateLegacyRegistry(stored);
    self.accountRegistry = migration[@"registry"];

    NSString *openaiId = migration[@"openaiAccountId"], *claudeId = migration[@"claudeAccountId"];
    if (openaiId || claudeId) {
        // Première exécution après la mise à jour : les données du mono-compte se rattachent aux
        // comptes qui viennent d'être créés, sinon les courbes repartiraient de zéro et le cookie
        // déjà saisi serait à recoller.
        [defaults setObject:self.accountRegistry forKey:TMAccountsDefaultsKey];
        NSArray *history = TMMigrateHistoryKeys(TMLoadHistory(), openaiId, claudeId);
        NSData *data = [NSJSONSerialization dataWithJSONObject:history options:0 error:nil];
        [data writeToFile:TMHistoryPath() atomically:YES];
        NSString *legacyCookie = TMKeychainRead(TMClaudeLegacyCookieAccount);
        if (legacyCookie.length && claudeId.length) {
            TMKeychainSave(TMClaudeCookieAccount(claudeId), legacyCookie);
            TMKeychainSave(TMClaudeLegacyCookieAccount, @"");
        }
        TMSaveAccountsCache(TMMigrateLegacyAccountsCache(TMLoadAccountsCache(), openaiId, claudeId));
    }
    [self resetAutoDerivedLabelsOnce];
}

// Les libellés posés par les versions précédentes venaient tous du fournisseur (e-mail,
// organisation) : aucun n'a été choisi par l'utilisateur. Les effacer une fois rend la
// numérotation visible ; le drapeau garantit qu'un nom donné ensuite à la main ne sera pas
// balayé au lancement suivant.
- (void)resetAutoDerivedLabelsOnce {
    NSUserDefaults *defaults = NSUserDefaults.standardUserDefaults;
    if ([defaults boolForKey:@"accountLabelsNumbered"]) return;
    for (NSDictionary *account in self.accountRegistry) {
        self.accountRegistry = TMRegistrySetting(self.accountRegistry, account[@"accountId"], @"label", @"");
    }
    [defaults setBool:YES forKey:@"accountLabelsNumbered"];
    [self saveAccountRegistry];
}

- (void)saveAccountRegistry {
    [NSUserDefaults.standardUserDefaults setObject:self.accountRegistry forKey:TMAccountsDefaultsKey];
}

- (NSArray<NSDictionary *> *)accountsForProvider:(NSString *)provider {
    return TMAccountsForProvider(self.accountRegistry, provider);
}

// Payload complet d'un compte : ce que le registre en sait, plus le dernier état sondé.
- (NSDictionary *)payloadForAccount:(NSDictionary *)account index:(NSInteger)index {
    NSString *accountId = account[@"accountId"];
    NSString *provider = account[@"provider"];
    NSDictionary *known = self.accountPayloads[accountId];
    if (![known isKindOfClass:NSDictionary.class]) {
        known = [provider isEqualToString:TMProviderOpenAI] ? TMDisconnectedOpenAIAccount(@"")
                                                            : TMEmptyClaudeAccount();
    }
    NSMutableDictionary *payload = [known mutableCopy];
    payload[@"accountId"] = accountId;
    payload[@"provider"] = provider;
    NSMutableDictionary *displayAccount = [account mutableCopy];
    displayAccount[@"email"] = known[@"email"] ?: @"";
    payload[@"label"] = TMAccountDisplayLabel(displayAccount, index);
    payload[@"customLabel"] = account[@"label"] ?: @"";
    NSString *resetKey = [NSString stringWithFormat:@"lastresetobserved:%@#%@", provider, accountId];
    payload[@"lastWeeklyResetObservedAt"] = @([[NSUserDefaults.standardUserDefaults
        dictionaryForKey:@"quotaNotificationState"][resetKey] longLongValue]);
    payload[@"weeklyResetStats"] = TMWeeklyResetStatistics(
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"quotaNotificationState"],
        [NSString stringWithFormat:@"%@#%@", provider, accountId], NSDate.date.timeIntervalSince1970);
    payload[@"orgId"] = account[@"orgId"] ?: @"";
    payload[@"orgName"] = account[@"orgName"] ?: @"";
    if ([provider isEqualToString:TMProviderOpenAI]) payload[@"billing"] = [self openAIBillingForAccount:accountId];
    if ([provider isEqualToString:TMProviderClaude]) {
        payload[@"claudeSource"] = account[@"claudeSource"] ?: @"";
        payload[@"cookieConfigured"] = ([account[@"claudeSource"] isEqual:@"code"] || [account[@"claudeSource"] isEqual:@"web"]) ? @NO : @([self cookieForAccount:accountId].length > 0);
        if ([account[@"claudeSource"] isEqual:@"code"]) {
            payload[@"orgId"] = known[@"orgId"] ?: @"";
            payload[@"orgName"] = @"";
        }
    }
    return payload;
}

// Prochaine facturation OpenAI : lue dans l'id_token ChatGPT du CODEX_HOME du compte, sans réseau.
// Le fichier n'est relu que s'il a changé ; le report mensuel d'une échéance passée est recalculé.
- (NSDictionary *)openAIBillingForAccount:(NSString *)accountId {
    static NSMutableDictionary *cache;
    if (!cache) cache = [NSMutableDictionary dictionary];
    NSString *path = [[self codexHomeForAccount:accountId] stringByAppendingPathComponent:@"auth.json"];
    NSDate *modified = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil].fileModificationDate;
    if (!modified) return @{@"status":@"unknown"};
    NSDictionary *entry = cache[accountId];
    if (![entry[@"modified"] isEqual:modified]) {
        NSData *data = [NSData dataWithContentsOfFile:path];
        NSDictionary *auth = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        NSDictionary *tokens = [auth isKindOfClass:NSDictionary.class] ? auth[@"tokens"] : nil;
        NSString *token = [tokens isKindOfClass:NSDictionary.class] && [tokens[@"id_token"] isKindOfClass:NSString.class] ? tokens[@"id_token"] : @"";
        entry = @{@"modified": modified, @"token": token};
        cache[accountId] = entry;
    }
    return TMOpenAIBillingFromIDToken(entry[@"token"], NSDate.date.timeIntervalSince1970);
}

// Claude : échéance de subscription_details quand le relevé est en direct ; sinon la dernière connue.
// Les noms de champs (jamais leurs valeurs) sont journalisés une fois : la forme n'est pas documentée.
- (NSDictionary *)claudeBillingFrom:(NSDictionary *)json live:(BOOL)live account:(NSString *)accountId {
    id details = json[@"subscription_details"];
    static BOOL logged = NO;
    if (!logged && [details isKindOfClass:NSDictionary.class]) {
        logged = YES;
        NSLog(@"Status billing: subscription_details keys=%@", [[details allKeys] componentsJoinedByString:@","]);
    }
    NSDictionary *billing = live ? TMClaudeBillingFromSubscription(details, NSDate.date.timeIntervalSince1970) : nil;
    if ([billing[@"status"] isEqual:@"known"]) return billing;
    NSDictionary *previous = [self knownPayload:accountId][@"billing"];
    return [previous isKindOfClass:NSDictionary.class] ? previous : @{@"status":@"unknown"};
}

// Tous les comptes, dans l'ordre d'affichage, chacun avec son payload courant.
- (NSArray<NSDictionary *> *)accountPayloadList {
    NSMutableArray *out = [NSMutableArray array];
    for (NSString *provider in @[TMProviderOpenAI, TMProviderClaude]) {
        NSArray *accounts = [self accountsForProvider:provider];
        [accounts enumerateObjectsUsingBlock:^(NSDictionary *account, NSUInteger index, BOOL *stop) {
            [out addObject:[self payloadForAccount:account index:index]];
        }];
    }
    return out;
}

- (void)setPayload:(NSDictionary *)payload forAccount:(NSString *)accountId {
    if (!accountId.length || ![payload isKindOfClass:NSDictionary.class]) return;
    self.accountPayloads[accountId] = payload;
}

- (NSDictionary *)knownPayload:(NSString *)accountId {
    NSDictionary *payload = self.accountPayloads[accountId];
    return [payload isKindOfClass:NSDictionary.class] ? payload : @{};
}

- (void)mergePayload:(NSDictionary *)changes forAccount:(NSString *)accountId {
    NSMutableDictionary *payload = [[self knownPayload:accountId] mutableCopy];
    [payload addEntriesFromDictionary:changes];
    [self setPayload:payload forAccount:accountId];
}

#pragma mark - Ajout et suppression de comptes

- (void)addAccountForProvider:(NSString *)provider {
    if (TMProviderIsFull(self.accountRegistry, provider)) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = TMT(@"a.limit.title");
        alert.informativeText = TMTP(@"a.limit.body", @{@"n": @(TMMaxAccountsPerProvider)});
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    NSString *accountId = TMNewAccountID();
    NSArray *next = TMRegistryAdding(self.accountRegistry, provider, accountId, @"");
    if (!next) return;
    self.accountRegistry = next;
    [self saveAccountRegistry];
    [self pushData];
    // Enchaîner sur la connexion : un compte ajouté sans identité ne dit rien et n'affiche rien.
    if ([provider isEqualToString:TMProviderOpenAI]) [self loginOpenAIAccount:accountId];
    else [self connectClaudeWebAccount:accountId];
}

- (void)confirmRemoveAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (!account) return;
    NSString *provider = account[@"provider"];
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.remove.title");
    alert.informativeText = [provider isEqualToString:TMProviderOpenAI]
        ? TMT(@"a.remove.openai")
        : TMT(@"a.remove.claude");
    [alert addButtonWithTitle:TMT(@"a.delete")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        [self removeAccount:accountId];
    }];
}

- (void)removeAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (!account) return;
    NSString *provider = account[@"provider"];

    if ([provider isEqualToString:TMProviderOpenAI]) {
        TMCodexAppServer *server = self.codexServers[accountId];
        // Déconnecter avant d'arrêter : sinon le jeton resterait valide sur le disque, dans un
        // dossier qu'on s'apprête à effacer.
        [server request:@"account/logout" params:nil completion:^(id result, NSError *error) {
            (void)result; (void)error;
            [server stop];
        }];
        [self.codexServers removeObjectForKey:accountId];
        [self.openAILoginIDs removeObjectForKey:accountId];
        [NSFileManager.defaultManager removeItemAtPath:[self codexHomeForAccount:accountId] error:nil];
    } else {
        NSString *profile = TMClaudeProfilePath(accountId);
        if (profile) [NSFileManager.defaultManager removeItemAtPath:[profile stringByAppendingPathComponent:@"bridge.json"] error:nil];
        TMClaudeSession *session = self.claudeSessions[accountId];
        [session destroy];
        [self.claudeSessions removeObjectForKey:accountId];
        TMKeychainSave(TMClaudeCookieAccount(accountId), @"");
        [self.cookieCache removeObjectForKey:accountId];
    }

    // Purge de l'historique : sans elle, le graphe garderait des séries que plus rien ne nomme.
    NSArray *history = TMHistoryDroppingAccount(TMLoadHistory(), accountId);
    NSData *data = [NSJSONSerialization dataWithJSONObject:history options:0 error:nil];
    [data writeToFile:TMHistoryPath() atomically:YES];

    NSMutableDictionary *quotaState = [[NSUserDefaults.standardUserDefaults dictionaryForKey:@"quotaNotificationState"] mutableCopy];
    NSString *suffix = [NSString stringWithFormat:@":%@#%@", provider, accountId];
    for (NSString *key in quotaState.allKeys)
        if ([key hasSuffix:suffix] || [key containsString:[suffix stringByAppendingString:@":"]])
            [quotaState removeObjectForKey:key];
    [NSUserDefaults.standardUserDefaults setObject:quotaState ?: @{} forKey:@"quotaNotificationState"];
    [self.accountPayloads removeObjectForKey:accountId];
    [self.accountErrorCounts removeObjectForKey:accountId];
    [self.accountBackoffUntil removeObjectForKey:accountId];
    self.accountRegistry = TMRegistryRemoving(self.accountRegistry, accountId);
    [self saveAccountRegistry];
    [self pushData];
}

- (void)renameAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (!account) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.rename.title");
    alert.informativeText = TMT(@"a.rename.body");
    [alert addButtonWithTitle:TMT(@"a.save")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    NSTextField *field = [NSTextField textFieldWithString:account[@"label"] ?: @""];
    field.frame = NSMakeRect(0, 0, 320, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"label",
                                                 field.stringValue ?: @"");
        [self saveAccountRegistry];
        [self pushData];
    }];
}

#pragma mark - OpenAI, un serveur Codex par compte

- (NSString *)codexHomeForAccount:(NSString *)accountId {
    return [[TMSupportDirectory() stringByAppendingPathComponent:@"codex"]
            stringByAppendingPathComponent:accountId];
}

// Un CODEX_HOME par compte : les comptes ne se marchent pas dessus, et se déconnecter dans Status
// ne déconnecte plus la session Codex partagée du Mac.
- (TMCodexAppServer *)codexServerForAccount:(NSString *)accountId {
    TMCodexAppServer *existing = self.codexServers[accountId];
    if (existing) return existing;
    TMCodexAppServer *server = [TMCodexAppServer new];
    server.codexHome = [self codexHomeForAccount:accountId];
    __weak typeof(self) weakSelf = self;
    server.notificationHandler = ^(NSString *method, NSDictionary *params) {
        [weakSelf handleCodexNotification:method params:params forAccount:accountId];
    };
    self.codexServers[accountId] = server;
    return server;
}

// Un processus Codex consomme environ 100 à 150 Mo. Les authentifications restent sur disque
// dans le CODEX_HOME de chaque compte ; seul le processus de lecture est éphémère.
- (void)releaseCodexServer:(TMCodexAppServer *)server forAccount:(NSString *)accountId {
    if (self.codexServers[accountId] != server || self.openAILoginIDs[accountId]
        || [[self knownPayload:accountId][@"connecting"] boolValue]) return;
    if (!server.isIdle) {
        __weak typeof(self) weakSelf = self;
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.5 * NSEC_PER_SEC)),
                       dispatch_get_main_queue(), ^{ [weakSelf releaseCodexServer:server forAccount:accountId]; });
        return;
    }
    server.notificationHandler = nil;
    [self.codexServers removeObjectForKey:accountId];
    [server stop];
}

- (void)refreshOpenAIAccount:(NSString *)accountId completion:(void (^)(void))completion {
    TMCodexAppServer *server = [self codexServerForAccount:accountId];
    [server request:@"account/read" params:@{ @"refreshToken": @NO } completion:^(id result, NSError *error) {
        if (error) {
            [self mergePayload:@{ @"connecting": @NO,
                                  @"error": error.localizedDescription ?: TMT(@"e.codex.failed") }
                    forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
            if (completion) completion();
            return;
        }
        NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSDictionary *account = [response[@"account"] isKindOfClass:NSDictionary.class] ? response[@"account"] : nil;
        if (![account[@"type"] isEqualToString:@"chatgpt"]) {
            NSString *notice = [account[@"type"] isEqualToString:@"apiKey"]
                ? TMT(@"a.openai.apiKey")
                : @"";
            [self setPayload:TMOpenAIAccountPayload(account, nil, NO, notice) forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
            if (completion) completion();
            return;
        }
        [server request:@"account/rateLimits/read" params:nil completion:^(id rateResult, NSError *rateError) {
            NSDictionary *rateResponse = [rateResult isKindOfClass:NSDictionary.class] ? rateResult : @{};
            NSMutableDictionary *payload = [TMOpenAIAccountPayload(account, rateResponse, NO,
                                            rateError.localizedDescription) mutableCopy];
            if (!rateError && [payload[@"windows"] count] > 0) {
                long long now = (long long)NSDate.date.timeIntervalSince1970;
                payload[@"capturedAt"] = @(now);
                payload[@"liveSource"] = @YES;
                self.lastQuotaRefreshAt = now;
            }
            [self setPayload:payload forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
            if (completion) completion();
        }];
    }];
}

- (void)loginOpenAIAccount:(NSString *)accountId {
    if ([[self knownPayload:accountId][@"connecting"] boolValue]) return;
    [self mergePayload:@{ @"connecting": @YES, @"error": @"" } forAccount:accountId];
    [self pushData];
    NSDictionary *params = @{ @"type": @"chatgpt", @"appBrand": @"codex", @"useHostedLoginSuccessPage": @YES };
    TMCodexAppServer *server = [self codexServerForAccount:accountId];
    [server request:@"account/login/start" params:params
                                         completion:^(id result, NSError *error) {
        NSDictionary *response = [result isKindOfClass:NSDictionary.class] ? result : @{};
        NSString *loginID = [response[@"loginId"] isKindOfClass:NSString.class] ? response[@"loginId"] : @"";
        NSString *authURL = [response[@"authUrl"] isKindOfClass:NSString.class] ? response[@"authUrl"] : @"";
        if (error || !loginID.length || !authURL.length) {
            [self mergePayload:@{ @"connecting": @NO,
                                  @"error": error.localizedDescription ?: @"Le serveur Codex n’a pas fourni de lien de connexion." }
                    forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
            return;
        }
        NSURL *url = [NSURL URLWithString:authURL];
        if (![url.scheme.lowercaseString isEqualToString:@"https"]) {
            [self mergePayload:@{ @"connecting": @NO, @"error": TMT(@"e.openai.insecure") }
                    forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
            return;
        }
        self.openAILoginIDs[accountId] = loginID;
        [NSWorkspace.sharedWorkspace openURL:url];
    }];
}

- (void)confirmLogoutOpenAIAccount:(NSString *)accountId {
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.openaiOut.title");
    // Chaque compte a son propre CODEX_HOME : contrairement aux versions précédentes, la session
    // Codex du Mac et les autres comptes ne sont pas touchés.
    alert.informativeText = TMT(@"a.openaiOut.body");
    [alert addButtonWithTitle:TMT(@"a.disconnect")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        TMCodexAppServer *server = [self codexServerForAccount:accountId];
        [server request:@"account/logout" params:nil
                                             completion:^(id result, NSError *error) {
            (void)result;
            [self.openAILoginIDs removeObjectForKey:accountId];
            [self setPayload:TMDisconnectedOpenAIAccount(error.localizedDescription) forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:server forAccount:accountId];
        }];
    }];
}

- (void)handleCodexNotification:(NSString *)method params:(NSDictionary *)params
                     forAccount:(NSString *)accountId {
    if ([method isEqualToString:@"account/login/completed"]) {
        NSString *loginID = [params[@"loginId"] isKindOfClass:NSString.class] ? params[@"loginId"] : @"";
        NSString *expected = self.openAILoginIDs[accountId];
        if (expected.length && loginID.length && ![loginID isEqualToString:expected]) return;
        [self.openAILoginIDs removeObjectForKey:accountId];
        if (![params[@"success"] boolValue]) {
            [self mergePayload:@{ @"connecting": @NO,
                                  @"error": [params[@"error"] isKindOfClass:NSString.class] ? params[@"error"] : TMT(@"e.openai.cancelled") }
                    forAccount:accountId];
            [self pushData];
            [self releaseCodexServer:self.codexServers[accountId] forAccount:accountId];
            return;
        }
        [self refreshOpenAIAccount:accountId completion:nil];
        return;
    }
    if ([method isEqualToString:@"account/updated"] || [method isEqualToString:@"account/rateLimits/updated"]) {
        [self refreshOpenAIAccount:accountId completion:nil];
    }
}

#pragma mark - Claude Code : profils isolés et compteurs officiels

- (void)connectClaudeCodeAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (![account[@"provider"] isEqual:TMProviderClaude]) return;
    if (!TMClaudeExecutable()) {
        [self mergePayload:@{@"error":TMT(@"e.claude.install")} forAccount:accountId];
        [NSWorkspace.sharedWorkspace openURL:[NSURL URLWithString:@"https://code.claude.com/docs/en/setup"]];
        [self pushData]; return;
    }
    NSString *helper = [NSBundle.mainBundle pathForResource:@"status-claude-collector" ofType:nil];
    NSString *commandPath = nil; NSError *error = nil;
    if (!TMPrepareClaudeProfile(accountId, helper, &commandPath, &error)) {
        [self mergePayload:@{@"error":error.localizedDescription ?: TMT(@"e.claude.profile")} forAccount:accountId];
        [self pushData]; return;
    }
    self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"claudeSource", @"code");
    [self saveAccountRegistry];
    [self setPayload:@{@"source":@"claude_code_statusline", @"connected":@NO, @"windows":@[], @"error":@"", @"liveSource":@NO} forAccount:accountId];
    [self pushData];
    [NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:commandPath]];
    [self pollClaudeConnection:accountId attempts:24];
}

- (void)pollClaudeConnection:(NSString *)accountId attempts:(NSInteger)attempts {
    if (attempts <= 0) return;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, 10 * NSEC_PER_SEC), dispatch_get_main_queue(), ^{
        if (![TMAccountWithID(self.accountRegistry, accountId)[@"claudeSource"] isEqual:@"code"]) return;
        NSString *marker = [TMClaudeProfilePath(accountId) stringByAppendingPathComponent:@"bridge.json"];
        if (![NSFileManager.defaultManager fileExistsAtPath:marker]) return;
        [self refreshClaudeAccount:accountId completion:^{
            if (![[self knownPayload:accountId][@"capturedAt"] longLongValue]) [self pollClaudeConnection:accountId attempts:attempts - 1];
        }];
    });
}

- (void)openClaudeCodeAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (![account[@"provider"] isEqual:TMProviderClaude] || ![account[@"claudeSource"] isEqual:@"code"]) return;
    NSString *path = [TMClaudeProfilePath(accountId) stringByAppendingPathComponent:@"Ouvrir Claude.command"];
    if (![NSWorkspace.sharedWorkspace openURL:[NSURL fileURLWithPath:path]]) {
        [self mergePayload:@{@"error":TMT(@"e.claude.openProfile")} forAccount:accountId];
        [self pushData];
    }
}

- (void)disconnectClaudeCodeAccount:(NSString *)accountId {
    NSDictionary *account = TMAccountWithID(self.accountRegistry, accountId);
    if (![account[@"provider"] isEqual:TMProviderClaude] || ![account[@"claudeSource"] isEqual:@"code"]) return;
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        BOOL ok = TMLogoutClaudeProfile(accountId);
        dispatch_async(dispatch_get_main_queue(), ^{
            if (!TMAccountWithID(self.accountRegistry, accountId)) return;
            [self setPayload:@{@"source":@"claude_code_statusline", @"connected":@NO, @"windows":@[], @"liveSource":@NO,
                @"error":ok ? @"" : TMT(@"e.claude.logoutFail")} forAccount:accountId];
            [self pushData];
        });
    });
}

// La migration n'est appliquée qu'après vérification de l'organisation ET réception de quotas.
- (void)connectClaudeWebAccount:(NSString *)accountId {
    NSDictionary *entry = TMAccountWithID(self.accountRegistry, accountId);
    if (![entry[@"provider"] isEqual:TMProviderClaude]) return;
    NSString *source = entry[@"claudeSource"] ?: @"";
    NSString *expected = [source isEqual:@"code"] ? [self knownPayload:accountId][@"orgId"] : entry[@"orgId"];
    expected = expected ?: @"";
    TMClaudeSession *session = [self claudeSessionForAccount:accountId];
    [session showLoginForLabel:TMAccountDisplayLabel(entry, 0) completion:^(NSArray *organizations) {
        NSDictionary *current = TMAccountWithID(self.accountRegistry, accountId);
        if (!current || ![(current[@"claudeSource"] ?: @"") isEqual:source]) { [session finishLogin]; return; }
        NSDictionary *organization = TMClaudeWebOrganization(organizations, expected);
        if (organization) { [self validateClaudeWebOrganization:organization account:accountId source:source session:session]; return; }
        if (expected.length) {
            [session showLoginMessage:TMT(@"e.claude.mismatch")]; return;
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = TMT(@"a.org.titleAccount");
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0,0,360,28) pullsDown:NO];
        for (NSDictionary *org in organizations) [picker addItemWithTitle:org[@"name"] ?: org[@"uuid"]];
        alert.accessoryView = picker;
        [alert addButtonWithTitle:TMT(@"a.choose")]; [alert addButtonWithTitle:TMT(@"a.cancel")];
        // La fenêtre de connexion reste visible pendant ce choix explicite.
        [alert beginSheetModalForWindow:NSApp.keyWindow completionHandler:^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn || picker.indexOfSelectedItem < 0) {
                [session showLoginMessage:TMT(@"e.claude.pickCancelled")]; return;
            }
            [self validateClaudeWebOrganization:organizations[picker.indexOfSelectedItem] account:accountId source:source session:session];
        }];
    }];
}
- (void)validateClaudeWebOrganization:(NSDictionary *)organization account:(NSString *)accountId
    source:(NSString *)source session:(TMClaudeSession *)session {
    NSString *orgId = organization[@"uuid"];
    if (![[NSUUID alloc] initWithUUIDString:orgId]) { [session showLoginMessage:@"Organisation Claude invalide."]; return; }
    [session fetchUsage:orgId completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *current = TMAccountWithID(self.accountRegistry, accountId);
        if (!session.loginVisible || !current || ![(current[@"claudeSource"] ?: @"") isEqual:source]) return;
        NSArray *windows = json ? TMClaudeWindowsFromUsagePayload(json) : @[];
        double weeklyUsed = -1;
        for (NSDictionary *window in windows) if (TMWindowIsPrimaryWeekly(window)) weeklyUsed = TMNumber(window[@"usedPercent"]);
        if (error || weeklyUsed < 0) { [session showLoginMessage:error.localizedDescription ?: TMT(@"e.claude.weeklyUnavailable")]; return; }
        self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"orgId", orgId);
        self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"claudeSource", @"web");
        [self saveAccountRegistry];
        [self setPayload:@{@"windows":windows,
            @"extraCredits":TMClaudeExtraCredits(json, json[@"overage_spend_limit"], json[@"prepaid/credits"]),
            @"billing":TMClaudeBillingFromSubscription(json[@"subscription_details"], NSDate.date.timeIntervalSince1970),
            @"capturedAt":@((long long)NSDate.date.timeIntervalSince1970),
            @"connected":@YES, @"liveSource":@YES, @"stale":@NO,
            @"manualReset":@{@"status":@"unknown"}, @"error":@""} forAccount:accountId];
        [session finishLogin];
        [self recordHistoryAndNotify]; [self pushData];
        [session checkManualResetAvailabilityForWeeklyUsedPercent:weeklyUsed completion:^(NSDictionary *availability) {
            NSDictionary *latest = TMAccountWithID(self.accountRegistry, accountId);
            if (![latest[@"claudeSource"] isEqual:@"web"] || ![latest[@"orgId"] isEqual:orgId]) return;
            [self mergePayload:@{@"manualReset": availability} forAccount:accountId];
            [self pushData];
        }];
    }];
}

#pragma mark - Claude, une session claude.ai par compte

// Cookie mémorisé : un seul accès au Trousseau par compte et par lancement. Le relire à chaque
// sondage déclenchait une demande d'accès à chaque fois — et comme survoler l'icône rafraîchit,
// cela produisait plusieurs demandes par minute.
- (NSString *)cookieForAccount:(NSString *)accountId {
    NSString *cached = self.cookieCache[accountId];
    if (cached) return cached;
    NSString *cookie = TMKeychainRead(TMClaudeCookieAccount(accountId)) ?: @"";
    self.cookieCache[accountId] = cookie;
    return cookie;
}

- (void)invalidateCookieCacheForAccount:(NSString *)accountId {
    [self.cookieCache removeObjectForKey:accountId];
}

- (TMClaudeSession *)claudeSessionForAccount:(NSString *)accountId {
    TMClaudeSession *existing = self.claudeSessions[accountId];
    if (existing) return existing;
    TMClaudeSession *session = [[TMClaudeSession alloc] initWithAccountID:accountId];
    self.claudeSessions[accountId] = session;
    return session;
}

- (void)refreshClaudeAccount:(NSString *)accountId completion:(void (^)(void))completion {
    NSDictionary *entry = TMAccountWithID(self.accountRegistry, accountId);
    if ([entry[@"claudeSource"] isEqual:@"code"]) {
        dispatch_async(dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
            NSDictionary *payload = TMClaudeBridgePayload(accountId);
            dispatch_async(dispatch_get_main_queue(), ^{
                if ([TMAccountWithID(self.accountRegistry, accountId)[@"claudeSource"] isEqual:@"code"]) {
                    [self setPayload:payload forAccount:accountId];
                    [self pushData];
                }
                if (completion) completion();
            });
        });
        return;
    }
    BOOL web = [entry[@"claudeSource"] isEqual:@"web"];
    TMClaudeSession *activeSession = self.claudeSessions[accountId];
    if (activeSession.loginVisible) { if (completion) completion(); return; }
    NSString *cookie = web ? @"" : [self cookieForAccount:accountId];
    NSString *orgId = entry[@"orgId"];

    if (!cookie.length && !web) {
        [self mergePayload:@{ @"cookieConfigured": @NO, @"liveSource": @NO,
                              @"error": @"" } forAccount:accountId];
        if (completion) completion();
        return;
    }
    if (!orgId.length && web) {
        [self mergePayload:@{@"connected":@NO, @"liveSource":@NO, @"error":TMT(@"e.claude.reconnect")} forAccount:accountId];
        if (completion) completion(); return;
    }
    if (!orgId.length) {
        // Cookie posé mais organisation encore inconnue : la résoudre est le seul chemin vers les
        // quotas, la CLI locale n'étant plus consultée.
        [self resolveOrganizationForAccount:accountId completion:^(BOOL ok) {
            if (!ok) { if (completion) completion(); return; }
            [self refreshClaudeAccount:accountId completion:completion];
        }];
        return;
    }

    TMClaudeSession *session = [self claudeSessionForAccount:accountId];
    [session seedCookieIfNeeded:cookie];
    // Un compte migré porte son org id sans son nom : celui-ci n'était renseigné qu'à la pose du
    // cookie. On le comble une fois, sinon le compte resterait un numéro sans rien pour le situer.
    if (!web && ![entry[@"orgName"] length]) {
        [session fetchOrganizations:^(NSArray *organizations, NSError *organizationsError) {
            if (organizationsError) return;
            for (NSDictionary *organization in organizations) {
                if (![organization[@"uuid"] isEqualToString:orgId]) continue;
                self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId,
                                                         @"orgName", organization[@"name"]);
                [self saveAccountRegistry];
                [self pushData];
                break;
            }
        }];
    }
    [session fetchUsage:orgId completion:^(NSDictionary *json, NSError *error) {
        NSDictionary *current = TMAccountWithID(self.accountRegistry, accountId);
        if (!current || ![(current[@"claudeSource"] ?: @"") isEqual:(entry[@"claudeSource"] ?: @"")] ||
            ![current[@"orgId"] isEqual:orgId]) { if (completion) completion(); return; }
        NSArray *windows = json ? TMClaudeWindowsFromUsagePayload(json) : @[];
        BOOL live = windows.count > 0;
        long long capturedAt = live ? (long long)NSDate.date.timeIntervalSince1970
                                    : TMInteger([self knownPayload:accountId][@"capturedAt"]);
        // Viscosité : quand le sondage ne rapporte aucune fenêtre, garder les dernières connues
        // avec leur horodatage plutôt que de vider l'affichage. Une fenêtre réinitialisée
        // réapparaît à bas pourcentage, pas à zéro fenêtre : « aucune fenêtre » signale une lacune
        // de collecte, pas une remise à zéro. Les fenêtres réellement périmées sont écartées.
        if (!live) {
            NSArray *previous = [[self knownPayload:accountId][@"windows"] isKindOfClass:NSArray.class]
                ? [self knownPayload:accountId][@"windows"] : @[];
            windows = TMDropExpiredWindows(previous);
        }
        NSTimeInterval age = capturedAt > 0 ? NSDate.date.timeIntervalSince1970 - capturedAt : 0;
        if (live) self.lastQuotaRefreshAt = capturedAt;
        [self setPayload:@{
            @"windows": windows, @"capturedAt": @(capturedAt),
            @"extraCredits": live ? TMClaudeExtraCredits(json, json[@"overage_spend_limit"], json[@"prepaid/credits"]) : @{@"status":@"unknown"},
            @"billing": [self claudeBillingFrom:json live:live account:accountId],
            @"stale": @(!live && capturedAt > 0 && age > 1800), @"liveSource": @(live),
            @"cookieConfigured": @(!web), @"connected": @(live || [[self knownPayload:accountId][@"connected"] boolValue]), @"orgId": orgId,
            @"manualReset": @{@"status": @"unknown"},
            @"error": error.localizedDescription ?: @""
        } forAccount:accountId];
        [self pushData];
        [self monitorClaudeSourceHealth:accountId live:live];
        if (completion) completion();
        double weeklyUsed = -1;
        if (live) for (NSDictionary *window in windows)
            if (TMWindowIsPrimaryWeekly(window)) weeklyUsed = TMNumber(window[@"usedPercent"]);
        if (weeklyUsed >= 0) [session checkManualResetAvailabilityForWeeklyUsedPercent:weeklyUsed completion:^(NSDictionary *availability) {
            NSDictionary *latest = TMAccountWithID(self.accountRegistry, accountId);
            if (!latest || ![(latest[@"claudeSource"] ?: @"") isEqual:(entry[@"claudeSource"] ?: @"")] ||
                ![latest[@"orgId"] isEqual:orgId]) return;
            [self mergePayload:@{@"manualReset": availability} forAccount:accountId];
            [self pushData];
        }];
        else [session park];  // pas de lecture de la page Utilisation : libérer claude.ai tout de suite
    }];
}

// Fraîcheur de la source d'un compte. Le cookie est la seule source : quand il ne répond plus, les
// jauges de CE compte ne sont plus alimentées — d'où une alerte, puis un rechargement de sa
// WebView si l'échec dure. Les autres comptes ne sont pas concernés.
- (void)monitorClaudeSourceHealth:(NSString *)accountId live:(BOOL)live {
    TMClaudeSession *session = [self claudeSessionForAccount:accountId];
    BOOL wasStale = session.wasStale;
    NSInteger failures = session.failures;
    NSDictionary *entry = TMAccountWithID(self.accountRegistry, accountId);
    NSInteger index = [[self accountsForProvider:TMProviderClaude] indexOfObject:entry];
    NSString *label = TMAccountDisplayLabel(entry, index == NSNotFound ? 0 : index);

    if (TMStaleAlertShouldFire(&wasStale, !live)) {
        [self postNotificationTitle:TMTP(@"n.stale.title", @{@"label": label})
                               body:[entry[@"claudeSource"] isEqual:@"web"] ? TMT(@"n.stale.web") : TMT(@"n.stale.cookie")];
    }
    if (TMWatchdogShouldReload(&failures, live, 3)) {
        if (![entry[@"claudeSource"] isEqual:@"web"])
            [[self claudeSessionForAccount:accountId] hardReloadWithCookieHeader:[self cookieForAccount:accountId]
                                                                     completion:^{ [self refresh:nil]; }];
    }
    session.wasStale = wasStale;
    session.failures = failures;
}

// Résout l'organisation d'un compte depuis son seul cookie. Plusieurs organisations : on demande
// laquelle — deviner reviendrait à afficher les quotas d'une autre équipe sans le dire.
- (void)resolveOrganizationForAccount:(NSString *)accountId completion:(void (^)(BOOL ok))completion {
    NSString *cookie = [self cookieForAccount:accountId];
    TMClaudeSession *session = [self claudeSessionForAccount:accountId];
    [session seedCookieIfNeeded:cookie];
    [session fetchOrganizations:^(NSArray *organizations, NSError *error) {
        if (error || !organizations.count) {
            [self mergePayload:@{ @"error": error.localizedDescription ?: @"Organisation Claude introuvable." }
                    forAccount:accountId];
            [self pushData];
            if (completion) completion(NO);
            return;
        }
        if (organizations.count == 1) {
            [self adoptOrganization:organizations[0] forAccount:accountId];
            if (completion) completion(YES);
            return;
        }
        NSAlert *alert = [NSAlert new];
        alert.messageText = TMT(@"a.org.title");
        alert.informativeText = TMT(@"a.org.cookieBody");
        NSPopUpButton *picker = [[NSPopUpButton alloc] initWithFrame:NSMakeRect(0, 0, 320, 26) pullsDown:NO];
        for (NSDictionary *organization in organizations) [picker addItemWithTitle:organization[@"name"]];
        alert.accessoryView = picker;
        [alert addButtonWithTitle:TMT(@"a.choose")];
        [alert addButtonWithTitle:TMT(@"a.cancel")];
        [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
            if (response != NSAlertFirstButtonReturn) { if (completion) completion(NO); return; }
            NSInteger index = MAX(0, MIN((NSInteger)organizations.count - 1, picker.indexOfSelectedItem));
            [self adoptOrganization:organizations[index] forAccount:accountId];
            if (completion) completion(YES);
        }];
    }];
}

- (void)adoptOrganization:(NSDictionary *)organization forAccount:(NSString *)accountId {
    self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"orgId", organization[@"uuid"]);
    // Le nom d'organisation identifie le compte sans devenir son nom : le nom reste « Claude 1 »,
    // court et stable, et l'organisation s'affiche en dessous.
    self.accountRegistry = TMRegistrySetting(self.accountRegistry, accountId, @"orgName", organization[@"name"]);
    [self saveAccountRegistry];
    [self mergePayload:@{ @"error": @"" } forAccount:accountId];
    [self pushData];
}

- (void)configureClaudeCookieForAccount:(NSString *)accountId {
    BOOL configured = [self cookieForAccount:accountId].length > 0;
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.cookie.title");
    alert.informativeText = TMT(@"a.cookie.body");
    [alert addButtonWithTitle:TMT(@"a.save")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    if (configured) [alert addButtonWithTitle:TMT(@"a.erase")];

    NSSecureTextField *field = [NSSecureTextField textFieldWithString:@""];
    field.placeholderString = TMT(@"a.cookie.placeholder");
    field.frame = NSMakeRect(0, 0, 420, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;

    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertThirdButtonReturn) {
            TMKeychainSave(TMClaudeCookieAccount(accountId), @"");
            [self invalidateCookieCacheForAccount:accountId];
            [[self claudeSessionForAccount:accountId] destroy];
            [self.claudeSessions removeObjectForKey:accountId];
            [self setPayload:TMEmptyClaudeAccount() forAccount:accountId];
            [self refresh:nil];
            return;
        }
        if (response != NSAlertFirstButtonReturn) return;
        NSString *cookie = TMExtractCookieHeader(field.stringValue);
        if (!cookie.length) {
            [self mergePayload:@{ @"error": TMT(@"e.cookie.none") }
                    forAccount:accountId];
            [self pushData];
            return;
        }
        TMKeychainSave(TMClaudeCookieAccount(accountId), cookie);
        [self invalidateCookieCacheForAccount:accountId];
        // Un cookie neuf est précisément le remède au blocage en cours : ne pas faire attendre le
        // backoff, et repartir d'une session propre.
        [[self claudeSessionForAccount:accountId] hardReloadWithCookieHeader:cookie completion:^{
            [self resolveOrganizationForAccount:accountId completion:^(BOOL ok) {
                (void)ok;
                [self refresh:self];
            }];
        }];
    }];
}

- (void)refreshOpenAIAccounts:(NSArray<NSDictionary *> *)accounts
                    atIndex:(NSUInteger)index force:(BOOL)force completion:(void (^)(void))completion {
    if (index >= accounts.count) { if (completion) completion(); return; }
    NSString *accountId = accounts[index][@"accountId"];
    if (!force && [self.accountBackoffUntil[accountId] timeIntervalSinceNow] > 0) {
        [self refreshOpenAIAccounts:accounts atIndex:index + 1 force:force completion:completion];
        return;
    }
    [self refreshOpenAIAccount:accountId completion:^{
        [self updateBackoffForAccount:accountId];
        [self refreshOpenAIAccounts:accounts atIndex:index + 1 force:force completion:completion];
    }];
}

- (void)refresh:(id)sender {
    if (self.refreshing) return;

    // Un clic manuel retente tous les comptes. Le backoff automatique est isolé par compte :
    // une session Claude défaillante ne doit jamais figer les cinq compteurs OpenAI.
    BOOL manual = sender != nil;
    if (manual) {
        [self.accountErrorCounts removeAllObjects];
        [self.accountBackoffUntil removeAllObjects];
    }

    self.refreshing = YES;
    if (manual) [self refreshApiAccountsForce:YES];
    [self pushData];

    dispatch_group_t group = dispatch_group_create();
    NSArray<NSDictionary *> *openAIAccounts = [self accountsForProvider:TMProviderOpenAI];
    if (openAIAccounts.count) {
        dispatch_group_enter(group);
        [self refreshOpenAIAccounts:openAIAccounts atIndex:0 force:manual
                       completion:^{ dispatch_group_leave(group); }];
    }
    for (NSDictionary *account in [self accountsForProvider:TMProviderClaude]) {
        NSString *accountId = account[@"accountId"];
        if (!manual && [self.accountBackoffUntil[accountId] timeIntervalSinceNow] > 0) continue;
        dispatch_group_enter(group);
        [self refreshClaudeAccount:accountId completion:^{
            [self updateBackoffForAccount:accountId];
            dispatch_group_leave(group);
        }];
    }
    dispatch_group_notify(group, dispatch_get_main_queue(), ^{
        self.refreshing = NO;
        [self recordHistoryAndNotify];
        [self refreshCostsInBackground];  // limité à 5 min, indépendamment des quotas
        [self pushData];
    });
}

// Une erreur ne ralentit que son compte. Une réponse valide le ramène immédiatement à la cadence
// normale ; les comptes des deux fournisseurs continuent indépendamment.
- (void)updateBackoffForAccount:(NSString *)accountId {
    NSString *error = [self knownPayload:accountId][@"error"];
    if (![error isKindOfClass:NSString.class] || !error.length) {
        [self.accountErrorCounts removeObjectForKey:accountId];
        [self.accountBackoffUntil removeObjectForKey:accountId];
        return;
    }
    NSInteger failures = MIN([self.accountErrorCounts[accountId] integerValue] + 1, 6);
    self.accountErrorCounts[accountId] = @(failures);
    NSTimeInterval delay = MIN([self quotaRefreshIntervalSeconds] * pow(2, failures), 40 * 60);
    self.accountBackoffUntil[accountId] = [NSDate dateWithTimeIntervalSinceNow:delay];
}

- (NSUInteger)pausedAccountCount {
    NSUInteger count = 0;
    for (NSDate *date in self.accountBackoffUntil.allValues)
        if (date.timeIntervalSinceNow > 0) count++;
    return count;
}

// [provider, accountId, fenêtres] par compte : la forme attendue par TMAppendHistory et, avec un
// libellé à la place de l'accountId, par les décisions de notification.
- (NSArray *)historyPairs {
    NSMutableArray *pairs = [NSMutableArray array];
    for (NSDictionary *payload in [self accountPayloadList]) {
        if ([payload[@"claudeSource"] isEqual:@"code"]) continue;
        NSArray *windows = [payload[@"windows"] isKindOfClass:NSArray.class] ? payload[@"windows"] : @[];
        [pairs addObject:@[payload[@"provider"], payload[@"accountId"], windows]];
    }
    return pairs;
}

- (void)recordHistoryAndNotify {
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    TMAppendHistory([self historyPairs], now);
    for (NSDictionary *payload in [self accountPayloadList]) {
        if ([payload[@"claudeSource"] isEqual:@"code"]) TMRecordClaudeBridgeHistory(payload[@"accountId"], payload);
    }
    [self notifyQuotaChanges];
}

// Seuils quota (clé « quota » des alertes, réglable ; rappel fixe à 95 %) et réinitialisations
// hebdomadaires (clé « quotaReset »). La décision est pure — TMQuotaNotificationDecisions — et son
// état persiste dans les préférences : un reset hebdo n'arrive qu'une fois par semaine, le rater
// parce que l'app a redémarré entre les deux observations le ferait passer inaperçu.
- (void)notifyQuotaChanges {
    double threshold = 0;
    NSArray<NSNumber *> *levels = @[];
    if ([self alertEnabled:@"quota" threshold:&threshold])
        levels = threshold < 95 ? @[@(threshold), @95] : @[@(threshold)];
    BOOL weeklyResets = [self alertEnabled:@"quotaReset" threshold:NULL];
    // Les clés d'état incluent l'identifiant du compte : deux comptes ne se réarment pas l'un
    // l'autre. Le libellé, lui, sert au texte de la notification.
    NSMutableArray *pairs = [NSMutableArray array];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    for (NSDictionary *payload in [self accountPayloadList]) {
        NSArray *windows = [payload[@"windows"] isKindOfClass:NSArray.class] ? payload[@"windows"] : @[];
        NSString *key = [NSString stringWithFormat:@"%@#%@", payload[@"provider"], payload[@"accountId"]];
        labels[key] = payload[@"label"] ?: @"";
        [pairs addObject:@[key, windows]];
    }
    NSDictionary *result = TMQuotaNotificationDecisions(
        [NSUserDefaults.standardUserDefaults dictionaryForKey:@"quotaNotificationState"],
        pairs, levels, weeklyResets, NSDate.date.timeIntervalSince1970);
    [NSUserDefaults.standardUserDefaults setObject:result[@"state"] forKey:@"quotaNotificationState"];
    // Aucune garde sur `notificationsAuthorized` ici. Ce drapeau n'est renseigné qu'en asynchrone,
    // après le premier sondage : le garder ferait taire les événements de ce premier tour — alors
    // que l'état, lui, a déjà avancé, si bien qu'un reset détecté dans les secondes suivant le
    // lancement était perdu pour de bon. On soumet toujours ; une notification non autorisée est
    // écartée par macOS, sans effet de bord.
    for (NSDictionary *event in result[@"events"]) {
        if ([event[@"kind"] isEqualToString:@"reset"]) {
            NSDateFormatter *fmt = [NSDateFormatter new];
            fmt.locale = [NSLocale localeWithLocaleIdentifier:TMLocaleIdentifier()];
            fmt.dateStyle = NSDateFormatterMediumStyle;
            fmt.timeStyle = NSDateFormatterShortStyle;
            fmt.doesRelativeDateFormatting = YES;
            NSString *until = [fmt stringFromDate:[NSDate dateWithTimeIntervalSince1970:TMNumber(event[@"resetsAt"])]];
            [self postNotificationTitle:TMTP(@"n.reset.title", @{@"provider": labels[event[@"provider"]] ?: event[@"provider"]})
                                   body:TMTP(@"n.reset.body", @{@"until": until})];
        } else {
            NSInteger level = [event[@"level"] integerValue];
            [self postNotificationTitle:TMTP(@"n.threshold.title", @{@"provider": labels[event[@"provider"]] ?: event[@"provider"], @"label": TMTranslateQuotaLabel(event[@"label"]), @"level": @(level)})
                                   body:level >= 95 ? TMT(@"n.threshold.high") : TMT(@"n.threshold.mid")];
        }
    }
}

#pragma mark - Comptes API (Admin API Anthropic / OpenAI)

// Ni Anthropic ni OpenAI n'exposent le solde de crédits : on relève le coût par jour UTC et on
// estime le reste à partir d'un solde saisi (ou d'un budget mensuel). Voir StatusApiCredits.h.
// La clé d'administration vit au Trousseau, une entrée par compte ; elle n'apparaît jamais dans
// les préférences, le payload des pages web, les journaux ni les messages d'erreur.

static NSString *TMApiCostsPath(void) {
    return [TMSupportDirectory() stringByAppendingPathComponent:@"api-costs.json"];
}

- (void)loadApiAccounts {
    self.apiRegistry = TMNormalizeApiRegistry([NSUserDefaults.standardUserDefaults arrayForKey:TMApiAccountsDefaultsKey]);
    self.apiKeyCache = [NSMutableDictionary dictionary];
    self.apiDaily = [NSMutableDictionary dictionary];
    self.apiStatus = [NSMutableDictionary dictionary];
    self.apiGate = [TMApiFetchGate new];
    self.apiTasks = [NSMutableDictionary dictionary];
    self.apiNextAllowed = [NSMutableDictionary dictionary];
    self.apiErrorCounts = [NSMutableDictionary dictionary];
    // Derniers coûts connus : l'icône et le popover ont un chiffre dès le lancement, et le premier
    // relevé peut se contenter des derniers jours. Rien de secret dans ce fichier.
    NSData *data = [NSData dataWithContentsOfFile:TMApiCostsPath()];
    NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if ([cache isKindOfClass:NSDictionary.class]) {
        for (NSDictionary *account in self.apiRegistry) {
            NSDictionary *entry = cache[account[@"accountId"]];
            if (![entry isKindOfClass:NSDictionary.class] || ![entry[@"daily"] isKindOfClass:NSDictionary.class]) continue;
            self.apiDaily[account[@"accountId"]] = TMApiDailyMerging(entry[@"daily"], nil, 0);
            self.apiStatus[account[@"accountId"]] = @{ @"updatedAt": @([entry[@"updatedAt"] doubleValue]),
                                                       @"coveredFrom": @([entry[@"coveredFrom"] doubleValue]) };
        }
    }
    NSURLSessionConfiguration *config = NSURLSessionConfiguration.ephemeralSessionConfiguration;
    config.HTTPCookieStorage = nil;
    config.HTTPShouldSetCookies = NO;
    config.URLCache = nil;
    config.requestCachePolicy = NSURLRequestReloadIgnoringLocalCacheData;
    config.timeoutIntervalForRequest = 30;
    self.apiSession = [NSURLSession sessionWithConfiguration:config delegate:[TMApiSessionDelegate new] delegateQueue:nil];
}

- (void)saveApiRegistry {
    [NSUserDefaults.standardUserDefaults setObject:self.apiRegistry forKey:TMApiAccountsDefaultsKey];
}

- (void)saveApiCosts {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *account in self.apiRegistry) {
        NSString *accountId = account[@"accountId"];
        if (!self.apiDaily[accountId]) continue;
        out[accountId] = @{ @"daily": self.apiDaily[accountId],
                            @"updatedAt": self.apiStatus[accountId][@"updatedAt"] ?: @0,
                            @"coveredFrom": self.apiStatus[accountId][@"coveredFrom"] ?: @0 };
    }
    NSData *data = [NSJSONSerialization dataWithJSONObject:out options:0 error:nil];
    [data writeToFile:TMApiCostsPath() atomically:YES];
}

- (NSString *)apiKeyForAccount:(NSString *)accountId {
    NSString *cached = self.apiKeyCache[accountId];
    if (cached) return cached;
    NSString *outcome = nil;
    NSString *key = TMKeychainReadWithOutcome(TMApiKeychainAccount(accountId), &outcome) ?: @"";
    // Accès refusé : ne rien mémoriser, la prochaine lecture pourra réussir (Trousseau déverrouillé,
    // accès accordé). Seule une absence avérée se retient.
    if ([outcome isEqualToString:@"denied"]) {
        [self setApiStatus:@{ @"error": @"api.err.keychain" } forAccount:accountId];
        return @"";
    }
    self.apiKeyCache[accountId] = key;
    return key;
}

// Clé changée, effacée ou compte supprimé : le relevé en vol est abandonné (requête annulée,
// réponses tardives ignorées). `resetHistory` oublie les coûts relevés, qui peuvent appartenir à
// une autre organisation que la nouvelle clé.
- (void)abandonApiFetchForAccount:(NSString *)accountId resetHistory:(BOOL)resetHistory {
    [self.apiGate invalidateAccount:accountId];
    [self.apiTasks[accountId] cancel];
    [self.apiTasks removeObjectForKey:accountId];
    [self.apiErrorCounts removeObjectForKey:accountId];
    [self.apiNextAllowed removeObjectForKey:accountId];
    if (!resetHistory) return;
    [self.apiDaily removeObjectForKey:accountId];
    [self.apiStatus removeObjectForKey:accountId];
    NSMutableDictionary *state = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"apiAlertState"] ?: @{}) mutableCopy];
    for (NSString *key in state.allKeys) if ([key hasPrefix:[accountId stringByAppendingString:@":"]]) [state removeObjectForKey:key];
    [NSUserDefaults.standardUserDefaults setObject:state forKey:@"apiAlertState"];
    [self saveApiCosts];
}

- (NSInteger)apiRefreshIntervalSeconds {
    NSInteger seconds = [NSUserDefaults.standardUserDefaults integerForKey:@"apiRefreshIntervalSeconds"];
    return [@[@300, @600, @900] containsObject:@(seconds)] ? seconds : 300;
}

// Cadence propre, indépendante des quotas : les coûts arrivent avec environ 5 min de retard
// (Anthropic), relever plus souvent ne montrerait rien de plus.
- (void)scheduleApiRefresh {
    [self.apiTimer invalidate];
    self.apiTimer = nil;
    if (!self.apiRegistry.count) return;
    NSInteger seconds = [self apiRefreshIntervalSeconds];
    __weak typeof(self) weakSelf = self;
    self.apiTimer = [NSTimer scheduledTimerWithTimeInterval:seconds repeats:YES block:^(NSTimer *timer) {
        [weakSelf refreshApiAccountsForce:NO];
    }];
    self.apiTimer.tolerance = seconds * 0.1;
}

- (void)refreshApiAccountsForce:(BOOL)force {
    for (NSDictionary *account in self.apiRegistry) [self refreshApiAccount:account[@"accountId"] force:force];
}

- (void)setApiStatus:(NSDictionary *)changes forAccount:(NSString *)accountId {
    NSMutableDictionary *status = [(self.apiStatus[accountId] ?: @{}) mutableCopy];
    [status addEntriesFromDictionary:changes];
    for (NSString *key in changes) if (changes[key] == NSNull.null) [status removeObjectForKey:key];
    self.apiStatus[accountId] = status;
}

- (NSString *)apiUserAgent {
    NSString *version = [NSBundle.mainBundle objectForInfoDictionaryKey:@"CFBundleShortVersionString"] ?: @"dev";
    return [NSString stringWithFormat:@"Status/%@ (macOS)", version];
}

- (void)refreshApiAccount:(NSString *)accountId force:(BOOL)force {
    NSDictionary *account = TMApiAccountWithID(self.apiRegistry, accountId);
    if (!account || [self.apiGate isFetching:accountId]) return;
    // Anthropic recommande au plus une requête par minute en continu : même un clic manuel attend
    // 15 s entre deux relevés du même compte, et la cadence automatique respecte le backoff.
    NSDate *nextAllowed = self.apiNextAllowed[accountId];
    NSTimeInterval lastAttempt = [self.apiStatus[accountId][@"attemptAt"] doubleValue];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    if (!force && nextAllowed.timeIntervalSinceNow > 0) return;
    if (force && now - lastAttempt < 15) return;

    NSString *key = [self apiKeyForAccount:accountId];
    if (!key.length) {
        if (![self.apiStatus[accountId][@"error"] isEqual:@"api.err.keychain"])
            [self setApiStatus:@{ @"error": @"api.err.noKey" } forAccount:accountId];
        [self scheduleApiPush];
        return;
    }
    NSTimeInterval queryStart = TMApiQueryStart(account, now);
    NSTimeInterval coveredFrom = [self.apiStatus[accountId][@"coveredFrom"] doubleValue];
    NSTimeInterval lastSuccess = [self.apiStatus[accountId][@"updatedAt"] doubleValue];
    // Relevé incrémental dès que tout l'intervalle est en cache : depuis le dernier relevé réussi,
    // un jour de recouvrement compris (les jours clos ne bougent plus).
    BOOL incremental = NO;
    NSTimeInterval start = TMApiFetchStart(queryStart, self.apiDaily[accountId] != nil, coveredFrom, lastSuccess, now, &incremental);
    NSString *provider = account[@"provider"];

    NSUInteger token = [self.apiGate beginForAccount:accountId];
    [self setApiStatus:@{ @"attemptAt": @(now) } forAccount:accountId];
    [self scheduleApiPush];
    [self fetchApiCosts:provider key:key start:start page:nil days:@{} pages:0 account:accountId token:token
             completion:^(NSDictionary *days, NSString *errorKey) {
        // Réponse d'un relevé abandonné (clé changée, compte supprimé) : rien n'en est gardé.
        if (![self.apiGate finish:token forAccount:accountId]) return;
        [self.apiTasks removeObjectForKey:accountId];
        if (!TMApiAccountWithID(self.apiRegistry, accountId)) return;
        if (errorKey) {
            NSInteger failures = MIN([self.apiErrorCounts[accountId] integerValue] + 1, 5);
            self.apiErrorCounts[accountId] = @(failures);
            // Doublé à chaque échec ; 5 s de marge pour ne pas manquer le tick qui tombe pile dessus.
            NSTimeInterval delay = MIN([self apiRefreshIntervalSeconds] * pow(2, failures - 1), 3600) - 5;
            self.apiNextAllowed[accountId] = [NSDate dateWithTimeIntervalSinceNow:delay];
            [self setApiStatus:@{ @"error": errorKey } forAccount:accountId];
        } else {
            NSTimeInterval done = NSDate.date.timeIntervalSince1970;
            [self.apiErrorCounts removeObjectForKey:accountId];
            self.apiNextAllowed[accountId] = [NSDate dateWithTimeIntervalSinceNow:60];
            self.apiDaily[accountId] = TMApiDailyMerging(self.apiDaily[accountId], days, queryStart);
            [self setApiStatus:@{ @"error": NSNull.null, @"updatedAt": @(done),
                                  @"coveredFrom": @(incremental ? coveredFrom : queryStart) } forAccount:accountId];
            NSArray *resolved = TMApiRegistryResolvingBaseline(self.apiRegistry, accountId, self.apiDaily[accountId], done);
            if (![resolved isEqual:self.apiRegistry]) { self.apiRegistry = resolved; [self saveApiRegistry]; }
            [self saveApiCosts];
        }
        [self notifyApiCredit];
        [self scheduleApiPush];
    }];
}

// Pages successives du rapport de coûts. Tout revient sur le fil principal. Les erreurs ne portent
// qu'un code (clé i18n) : ni le corps de la réponse ni la requête ne sont journalisés.
- (void)fetchApiCosts:(NSString *)provider key:(NSString *)key start:(NSTimeInterval)start page:(NSString *)page
                 days:(NSDictionary *)days pages:(NSInteger)pages account:(NSString *)accountId token:(NSUInteger)token
           completion:(void (^)(NSDictionary *days, NSString *errorKey))completion {
    // Abandonné entre deux pages : pas de requête de plus avec l'ancienne clé.
    if (![self.apiGate isCurrent:token forAccount:accountId]) { completion(nil, @"api.err.http"); return; }
    NSMutableURLRequest *request = TMApiCostRequest(provider, key, start, page, [self apiUserAgent]);
    if (!request) { completion(nil, @"api.err.http"); return; }
    NSURLSessionDataTask *task = [self.apiSession dataTaskWithRequest:request
                                                    completionHandler:^(NSData *data, NSURLResponse *response, NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            if (![self.apiGate isCurrent:token forAccount:accountId]) { completion(nil, @"api.err.http"); return; }
            NSHTTPURLResponse *http = [response isKindOfClass:NSHTTPURLResponse.class] ? (NSHTTPURLResponse *)response : nil;
            if (error || !http) { completion(nil, @"api.err.network"); return; }
            if (!TMApiURLAllowed(http.URL)) { completion(nil, @"api.err.http"); return; }
            if (http.statusCode != 200) {
                NSLog(@"Status API %@ : HTTP %ld", provider, (long)http.statusCode);
                completion(nil, TMApiErrorKey(http.statusCode));
                return;
            }
            id json = data.length ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
            NSString *parseError = nil;
            NSDictionary *parsed = TMApiParseCostPage(provider, json, &parseError);
            if (!parsed) { completion(nil, parseError ?: @"api.err.malformed"); return; }
            NSMutableDictionary *merged = [days mutableCopy];
            [merged addEntriesFromDictionary:parsed[@"days"]];
            NSString *next = parsed[@"nextPage"];
            if (!next.length) { completion(merged, nil); return; }
            // 30 pages couvrent largement l'année de recul permise. Au-delà, le relevé est
            // incomplet : il ne remplace pas les chiffres connus.
            if (pages + 1 >= 30) { completion(nil, @"api.err.incomplete"); return; }
            [self fetchApiCosts:provider key:key start:start page:next days:merged pages:pages + 1
                        account:accountId token:token completion:completion];
        });
    }];
    self.apiTasks[accountId] = task;
    [task resume];
}

// Plusieurs comptes répondent souvent dans la même seconde : un seul pushData (coûteux) pour tous.
- (void)scheduleApiPush {
    if (self.apiPushPending) return;
    self.apiPushPending = YES;
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.3 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
        self.apiPushPending = NO;
        [self pushData];
    });
}

- (double)apiAlertThreshold {
    double threshold = 10;
    [self alertEnabled:@"apiCredit" threshold:&threshold];
    return threshold;
}

// Synthèses dans l'ordre d'affichage (Anthropic puis OpenAI), avec ce que l'interface doit savoir.
- (NSArray<NSDictionary *> *)apiAccountPayloadList {
    NSMutableArray *out = [NSMutableArray array];
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    double threshold = [self apiAlertThreshold];
    for (NSString *provider in @[TMApiProviderAnthropic, TMApiProviderOpenAI]) {
        [TMApiAccountsForProvider(self.apiRegistry, provider) enumerateObjectsUsingBlock:^(NSDictionary *account, NSUInteger index, BOOL *stop) {
            NSString *accountId = account[@"accountId"];
            NSMutableDictionary *payload = [TMApiSummary(account, self.apiDaily[accountId], now, threshold) mutableCopy];
            NSDictionary *status = self.apiStatus[accountId] ?: @{};
            payload[@"label"] = TMApiAccountDisplayLabel(account, index);
            payload[@"customLabel"] = account[@"label"] ?: @"";
            payload[@"keyConfigured"] = @([self apiKeyForAccount:accountId].length > 0);
            payload[@"hasData"] = @(self.apiDaily[accountId] != nil);
            payload[@"updatedAt"] = @([status[@"updatedAt"] doubleValue] * 1000);
            payload[@"refreshing"] = @([self.apiGate isFetching:accountId]);
            payload[@"error"] = status[@"error"] ?: @"";
            if (account[@"balanceUSD"]) payload[@"balanceUSD"] = account[@"balanceUSD"];
            if (account[@"balanceSetAt"]) payload[@"balanceSetAt"] = @([account[@"balanceSetAt"] doubleValue] * 1000);
            if (account[@"budgetUSD"]) payload[@"budgetUSD"] = account[@"budgetUSD"];
            [out addObject:payload];
        }];
    }
    return out;
}

// Un widget par fournisseur, recalculé en même temps que les widgets de quota (pushData), jamais
// au tick du moniteur.
- (void)refreshApiWidgetFamilies {
    NSArray *pairs = @[@[@"anthropicApi", TMApiProviderAnthropic], @[@"openaiApi", TMApiProviderOpenAI]];
    NSMutableArray *wanted = [NSMutableArray array];
    for (NSArray *pair in pairs) if (self.widgetItems[pair[0]]) [wanted addObject:pair];
    if (!wanted.count) { self.apiWidgetFamilies = @[]; return; }
    NSMutableArray *summaries = [NSMutableArray array];
    for (NSDictionary *payload in [self apiAccountPayloadList]) if ([payload[@"hasData"] boolValue]) [summaries addObject:payload];
    NSString *locale = TMLocaleIdentifier();
    NSMutableArray *families = [NSMutableArray array];
    for (NSArray *pair in wanted) {
        id pinned = [self widgetStyleFor:pair[0]][@"accountId"];
        NSDictionary *pick = TMApiWidgetPick(summaries, pair[1], [pinned isKindOfClass:NSString.class] ? pinned : nil);
        if (!pick) continue;  // aucun solde ni budget saisi : tiret
        [families addObject:@{ @"id": pair[0], @"series": @{},
                               @"now": @{ @"fraction": pick[@"fraction"], @"severity": pick[@"severity"] ?: @0,
                                          @"text": TMFormatUSD(MAX(0, [pick[@"remainingUSD"] doubleValue]), locale),
                                          @"template": TMFormatUSD(9999, locale) } }];
    }
    self.apiWidgetFamilies = families;
}

- (void)notifyApiCredit {
    double threshold = 10;
    BOOL enabled = [self alertEnabled:@"apiCredit" threshold:&threshold];
    NSMutableArray *summaries = [NSMutableArray array];
    NSMutableDictionary *labels = [NSMutableDictionary dictionary];
    for (NSDictionary *payload in [self apiAccountPayloadList]) {
        if (![payload[@"hasData"] boolValue]) continue;
        [summaries addObject:payload];
        labels[payload[@"accountId"]] = payload;
    }
    NSDictionary *result = TMApiAlertDecisions([NSUserDefaults.standardUserDefaults dictionaryForKey:@"apiAlertState"],
                                               summaries, threshold, enabled);
    [NSUserDefaults.standardUserDefaults setObject:result[@"state"] forKey:@"apiAlertState"];
    NSString *locale = TMLocaleIdentifier();
    for (NSDictionary *fire in result[@"fire"]) {
        NSDictionary *payload = labels[fire[@"accountId"]];
        NSString *kind = fire[@"kind"];
        NSDictionary *params = @{ @"label": payload[@"label"] ?: @"",
                                  @"v": TMFormatUSD(MAX(0, [payload[@"remainingUSD"] doubleValue]), locale),
                                  @"ref": TMFormatUSD([payload[@"referenceUSD"] doubleValue], locale) };
        [self postNotificationTitle:TMTP([NSString stringWithFormat:@"n.api.%@.title", kind], params)
                               body:TMTP([NSString stringWithFormat:@"n.api.%@.body", kind], params)];
    }
}

#pragma mark Actions des comptes API

- (BOOL)handleApiAction:(NSString *)action body:(NSDictionary *)body {
    if (![action isKindOfClass:NSString.class]) return NO;
    NSString *accountId = [body[@"accountId"] isKindOfClass:NSString.class] ? body[@"accountId"] : @"";
    if ([action isEqualToString:@"addApiAccount"]) {
        NSString *provider = [body[@"provider"] isKindOfClass:NSString.class] ? body[@"provider"] : @"";
        [self addApiAccountForProvider:provider];
        return YES;
    }
    if ([action isEqualToString:@"refreshApi"]) { [self refreshApiAccountsForce:YES]; return YES; }
    if ([action isEqualToString:@"setApiRefreshInterval"]) {
        NSInteger seconds = [body[@"seconds"] integerValue];
        if ([@[@300, @600, @900] containsObject:@(seconds)]) {
            [NSUserDefaults.standardUserDefaults setInteger:seconds forKey:@"apiRefreshIntervalSeconds"];
            [self scheduleApiRefresh];
            [self pushData];
        }
        return YES;
    }
    if ([action isEqualToString:@"setApiWidgetAccount"]) {
        NSString *wid = [body[@"id"] isKindOfClass:NSString.class] ? body[@"id"] : @"";
        if (!TMWidgetIsApi(wid)) return YES;
        NSMutableDictionary *config = [([NSUserDefaults.standardUserDefaults dictionaryForKey:@"menuBarWidgetConfig"] ?: @{}) mutableCopy];
        NSMutableDictionary *one = [([config[wid] isKindOfClass:NSDictionary.class] ? config[wid] : @{}) mutableCopy];
        if (TMApiAccountWithID(self.apiRegistry, accountId)) one[@"accountId"] = accountId;
        else [one removeObjectForKey:@"accountId"];  // « le plus critique »
        config[wid] = one;
        [NSUserDefaults.standardUserDefaults setObject:config forKey:@"menuBarWidgetConfig"];
        [self refreshQuotaWidgetFamilies];
        [self updateMenuBarWidgetsFromMonitor];
        [self pushData];
        return YES;
    }
    NSArray *perAccount = @[@"configureApiKey", @"setApiBalance", @"addApiCredit", @"setApiBudget",
                            @"clearApiMode", @"renameApiAccount", @"removeApiAccount"];
    if (![perAccount containsObject:action]) return NO;
    if (!TMApiAccountWithID(self.apiRegistry, accountId)) return YES;
    if ([action isEqualToString:@"configureApiKey"]) [self configureApiKeyForAccount:accountId];
    if ([action isEqualToString:@"setApiBalance"]) [self promptApiBalanceForAccount:accountId];
    if ([action isEqualToString:@"addApiCredit"]) [self promptApiCreditForAccount:accountId];
    if ([action isEqualToString:@"setApiBudget"]) [self promptApiBudgetForAccount:accountId];
    if ([action isEqualToString:@"clearApiMode"]) {
        self.apiRegistry = TMApiRegistryClearingMode(self.apiRegistry, accountId);
        [self saveApiRegistry];
        [self pushData];
    }
    if ([action isEqualToString:@"renameApiAccount"]) [self renameApiAccount:accountId];
    if ([action isEqualToString:@"removeApiAccount"]) [self confirmRemoveApiAccount:accountId];
    return YES;
}

- (void)addApiAccountForProvider:(NSString *)provider {
    if (![provider isEqualToString:TMApiProviderAnthropic] && ![provider isEqualToString:TMApiProviderOpenAI]) return;
    NSString *accountId = TMNewAccountID();
    NSArray *next = TMApiRegistryAdding(self.apiRegistry, provider, accountId);
    if (!next) {
        NSAlert *alert = [NSAlert new];
        alert.messageText = TMT(@"a.limit.title");
        alert.informativeText = TMTP(@"api.limit.body", @{@"n": @(TMMaxApiAccountsPerProvider)});
        [alert beginSheetModalForWindow:self.window completionHandler:nil];
        return;
    }
    self.apiRegistry = next;
    self.apiKeyCache[accountId] = @"";  // compte neuf : rien à lire au Trousseau
    [self saveApiRegistry];
    [self scheduleApiRefresh];
    [self pushData];
    // Un compte sans clé n'affiche rien : enchaîner sur la saisie, comme pour les abonnements.
    [self configureApiKeyForAccount:accountId];
}

// Saisie de la clé : champ masqué natif, jamais un champ de la page web. La clé passe directement
// du champ au Trousseau ; seul « clé enregistrée » remonte ensuite vers l'interface.
- (void)configureApiKeyForAccount:(NSString *)accountId {
    NSDictionary *account = TMApiAccountWithID(self.apiRegistry, accountId);
    if (!account) return;
    NSString *provider = account[@"provider"];
    BOOL configured = [self apiKeyForAccount:accountId].length > 0;
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT([@"api.key.title." stringByAppendingString:provider]);
    alert.informativeText = TMT([@"api.key.body." stringByAppendingString:provider]);
    [alert addButtonWithTitle:TMT(@"a.save")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    if (configured) [alert addButtonWithTitle:TMT(@"a.erase")];
    NSSecureTextField *field = [NSSecureTextField textFieldWithString:@""];
    field.placeholderString = TMT([@"api.key.placeholder." stringByAppendingString:provider]);
    field.frame = NSMakeRect(0, 0, 420, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response == NSAlertThirdButtonReturn) {
            if (!TMApiKeySave(accountId, @"")) { [self showApiError:TMT(@"api.key.deleteFailed")]; return; }
            self.apiKeyCache[accountId] = @"";
            [self abandonApiFetchForAccount:accountId resetHistory:YES];
            [self setApiStatus:@{ @"error": @"api.err.noKey" } forAccount:accountId];
            [self pushData];
            return;
        }
        if (response != NSAlertFirstButtonReturn) return;
        NSString *key = TMApiKeyCleaned(field.stringValue);
        field.stringValue = @"";
        if (!TMApiKeyHasExpectedShape(provider, key)) {
            [self showApiError:TMT([@"api.key.invalid." stringByAppendingString:provider])];
            return;
        }
        if (!TMApiKeySave(accountId, key)) {
            [self showApiError:TMT(@"api.key.saveFailed")];
            return;
        }
        // Une clé neuve peut viser une autre organisation : relevé en vol abandonné, coûts oubliés,
        // le relevé suivant repart de zéro et valide la clé.
        BOOL replaced = ![self.apiKeyCache[accountId] isEqualToString:key];
        self.apiKeyCache[accountId] = key;
        [self abandonApiFetchForAccount:accountId resetHistory:replaced];
        [self setApiStatus:@{ @"error": NSNull.null, @"attemptAt": @0 } forAccount:accountId];
        [self refreshApiAccount:accountId force:YES];
        [self pushData];
    }];
}

- (void)showApiError:(NSString *)message {
    NSAlert *alert = [NSAlert new];
    alert.messageText = message;
    [alert beginSheetModalForWindow:self.window completionHandler:nil];
}

// Demande un montant en dollars. Le texte saisi n'est pas un secret, mais il est validé ici :
// la page web ne fait qu'ouvrir la boîte de dialogue.
- (void)promptApiAmountTitle:(NSString *)title body:(NSString *)body initial:(NSNumber *)initial
                  completion:(void (^)(double amount))completion {
    NSAlert *alert = [NSAlert new];
    alert.messageText = title;
    alert.informativeText = body;
    [alert addButtonWithTitle:TMT(@"a.save")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    NSString *start = initial ? [NSString stringWithFormat:@"%.2f", initial.doubleValue] : @"";
    NSTextField *field = [NSTextField textFieldWithString:start];
    field.placeholderString = TMT(@"api.amount.placeholder");
    field.frame = NSMakeRect(0, 0, 200, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        double amount = 0;
        if (!TMParseUSDAmount(field.stringValue, &amount)) { [self showApiError:TMT(@"api.amount.invalid")]; return; }
        completion(amount);
    }];
}

- (void)promptApiBalanceForAccount:(NSString *)accountId {
    [self promptApiAmountTitle:TMT(@"api.balance.title") body:TMT(@"api.balance.body") initial:nil
                    completion:^(double amount) {
        // Base provisoire : la dépense du jour en cache, si le dernier relevé date du même jour UTC.
        NSTimeInterval now = NSDate.date.timeIntervalSince1970;
        NSTimeInterval last = [self.apiStatus[accountId][@"updatedAt"] doubleValue];
        double provisional = TMUTCDayStart(last) == TMUTCDayStart(now)
            ? [self.apiDaily[accountId][[NSString stringWithFormat:@"%lld", (long long)TMUTCDayStart(now)]] doubleValue] : 0;
        self.apiRegistry = TMApiRegistrySettingBalance(self.apiRegistry, accountId, amount, now, provisional);
        [self saveApiRegistry];
        // Relevé immédiat : il fixe la dépense déjà comptée aujourd'hui (ligne de base).
        [self setApiStatus:@{ @"attemptAt": @0 } forAccount:accountId];
        [self refreshApiAccount:accountId force:YES];
        [self pushData];
    }];
}

- (void)promptApiCreditForAccount:(NSString *)accountId {
    [self promptApiAmountTitle:TMT(@"api.credit.title") body:TMT(@"api.credit.body") initial:nil
                    completion:^(double amount) {
        self.apiRegistry = TMApiRegistryAddingCredit(self.apiRegistry, accountId, amount);
        [self saveApiRegistry];
        [self notifyApiCredit];
        [self pushData];
    }];
}

- (void)promptApiBudgetForAccount:(NSString *)accountId {
    NSNumber *current = TMApiAccountWithID(self.apiRegistry, accountId)[@"budgetUSD"];
    [self promptApiAmountTitle:TMT(@"api.budget.title") body:TMT(@"api.budget.body") initial:current
                    completion:^(double amount) {
        if (amount <= 0) { [self showApiError:TMT(@"api.amount.invalid")]; return; }
        self.apiRegistry = TMApiRegistrySettingBudget(self.apiRegistry, accountId, amount);
        [self saveApiRegistry];
        [self notifyApiCredit];
        [self pushData];
    }];
}

- (void)renameApiAccount:(NSString *)accountId {
    NSDictionary *account = TMApiAccountWithID(self.apiRegistry, accountId);
    if (!account) return;
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.rename.title");
    alert.informativeText = TMT(@"a.rename.body");
    [alert addButtonWithTitle:TMT(@"a.save")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    NSTextField *field = [NSTextField textFieldWithString:account[@"label"] ?: @""];
    field.frame = NSMakeRect(0, 0, 320, 24);
    alert.accessoryView = field;
    alert.window.initialFirstResponder = field;
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        self.apiRegistry = TMApiRegistrySettingLabel(self.apiRegistry, accountId, field.stringValue ?: @"");
        [self saveApiRegistry];
        [self pushData];
    }];
}

- (void)confirmRemoveApiAccount:(NSString *)accountId {
    NSAlert *alert = [NSAlert new];
    alert.messageText = TMT(@"a.remove.title");
    alert.informativeText = TMT(@"api.remove.body");
    [alert addButtonWithTitle:TMT(@"a.delete")];
    [alert addButtonWithTitle:TMT(@"a.cancel")];
    [alert beginSheetModalForWindow:self.window completionHandler:^(NSModalResponse response) {
        if (response != NSAlertFirstButtonReturn) return;
        // Le compte n'est retiré que si sa clé a bien quitté le Trousseau : sinon elle y resterait,
        // orpheline, sans plus rien dans Status pour l'effacer.
        if (!TMApiKeySave(accountId, @"")) { [self showApiError:TMT(@"api.key.deleteFailed")]; return; }
        [self.apiKeyCache removeObjectForKey:accountId];
        [self abandonApiFetchForAccount:accountId resetHistory:YES];
        self.apiRegistry = TMApiRegistryRemoving(self.apiRegistry, accountId);
        [self saveApiRegistry];
        [self saveApiCosts];
        [self scheduleApiRefresh];
        [self pushData];
    }];
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

// Repair service registration after a signed helper was replaced. Does not start a lid session.
// Only use after confirming the mode is stopped and the system sleep setting is restored.
static int TMRepairLidRegistration(void) {
    if (!TMLidSigningReady()) { fprintf(stderr,"Signature Apple app/service requise avant réenregistrement.\n"); return 1; }
    SMAppService *service=[SMAppService daemonServiceWithPlistName:TMLidServicePlist];
    NSError *error=nil;
    if (service.status!=SMAppServiceStatusNotRegistered && ![service unregisterAndReturnError:&error]) {
        fprintf(stderr,"Désenregistrement impossible : %s\n",error.localizedDescription.UTF8String); return 1;
    }
    if (![service registerAndReturnError:&error]) {
        fprintf(stderr,"Enregistrement impossible : %s\n",error.localizedDescription.UTF8String); return 1;
    }
    printf("Service réenregistré ; statut=%ld. Aucune session capot fermé démarrée.\n",(long)service.status);
    return 0;
}

int main(int argc, const char *argv[]) {
    @autoreleasepool {
        for (int i = 1; i < argc; i++) {
            if (strcmp(argv[i], "--repair-lid-registration") == 0) return TMRepairLidRegistration();
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
