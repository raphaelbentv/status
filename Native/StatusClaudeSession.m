#import "StatusClaudeSession.h"
#import "StatusQuota.h"

static NSError *TMSessionError(NSString *message) {
    return [NSError errorWithDomain:@"Status.ClaudeSession" code:1
                           userInfo:@{NSLocalizedDescriptionKey: message}];
}

@interface TMClaudeSession ()
@property (copy) NSString *accountId;
@property WKWebView *webView;
@property BOOL loaded;
@property NSWindow *loginWindow;
@property NSTextField *loginMessage;
@property NSButton *loginButton;
@property (copy) void (^loginCompletion)(NSArray *organizations);
// File d'attente plutôt qu'un seul bloc : deux lectures peuvent partir en même temps (les
// quotas et le nom d'organisation, par exemple). Rejeter la seconde parce qu'un chargement est
// en vol lui faisait remonter « session illisible » — un faux négatif, affiché à l'utilisateur
// comme un cookie à recoller.
@property NSMutableArray<void (^)(BOOL ok)> *loadWaiters;
@property (copy, nullable) NSString *seededCookie;
@end

@implementation TMClaudeSession

- (instancetype)initWithAccountID:(NSString *)accountId {
    if ((self = [super init])) {
        _accountId = [accountId copy];
        _loadWaiters = [NSMutableArray array];
    }
    return self;
}

- (WKWebView *)ensureWebView {
    if (self.webView) return self.webView;
    WKWebViewConfiguration *configuration = [WKWebViewConfiguration new];
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:self.accountId];
    // Magasin persistant ET isolé : le compte garde sa session d'un lancement à l'autre sans
    // partager ses cookies avec les autres comptes. Un identifiant illisible retombe sur un
    // magasin éphémère plutôt que sur le magasin par défaut, qui serait partagé — mieux vaut
    // reperdre la session à chaque lancement que mélanger deux comptes.
    configuration.websiteDataStore = identifier
        ? [WKWebsiteDataStore dataStoreForIdentifier:identifier]
        : [WKWebsiteDataStore nonPersistentDataStore];
    self.webView = [[WKWebView alloc] initWithFrame:NSMakeRect(0, 0, 1024, 768)
                                      configuration:configuration];
    self.webView.navigationDelegate = self;
    self.webView.UIDelegate = self;
    return self.webView;
}

- (BOOL)loginVisible { return self.loginWindow.isVisible; }

- (void)showLoginForLabel:(NSString *)label completion:(void (^)(NSArray *))completion {
    if (self.loginWindow) { [self.loginWindow makeKeyAndOrderFront:nil]; return; }
    self.loginCompletion = completion;
    self.loginWindow = [[NSWindow alloc] initWithContentRect:NSMakeRect(0, 0, 1000, 760)
        styleMask:NSWindowStyleMaskTitled | NSWindowStyleMaskClosable | NSWindowStyleMaskResizable
        backing:NSBackingStoreBuffered defer:NO];
    self.loginWindow.releasedWhenClosed = NO;
    self.loginWindow.delegate = self;
    self.loginWindow.title = [NSString stringWithFormat:@"Connexion Claude · %@", label];
    self.loginWindow.minSize = NSMakeSize(720, 560);
    NSView *content = self.loginWindow.contentView;
    NSView *bar = [[NSView alloc] initWithFrame:NSMakeRect(0, 706, 1000, 54)];
    bar.autoresizingMask = NSViewWidthSizable | NSViewMinYMargin;
    self.loginMessage = [NSTextField labelWithString:@"Connectez ce compte à Claude, puis cliquez sur Valider la connexion."];
    self.loginMessage.frame = NSMakeRect(16, 10, 750, 34);
    self.loginMessage.autoresizingMask = NSViewWidthSizable;
    self.loginMessage.maximumNumberOfLines = 2;
    self.loginButton = [NSButton buttonWithTitle:@"Valider la connexion" target:self action:@selector(validateWebLogin:)];
    self.loginButton.frame = NSMakeRect(788, 12, 196, 30);
    self.loginButton.autoresizingMask = NSViewMinXMargin;
    [bar addSubview:self.loginMessage]; [bar addSubview:self.loginButton];
    WKWebView *web = [self ensureWebView];
    web.frame = NSMakeRect(0, 0, 1000, 706);
    web.autoresizingMask = NSViewWidthSizable | NSViewHeightSizable;
    [content addSubview:web]; [content addSubview:bar];
    self.loaded = NO;
    [web loadRequest:[NSURLRequest requestWithURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]]];
    [self.loginWindow center]; [self.loginWindow makeKeyAndOrderFront:nil];
    [NSApp activateIgnoringOtherApps:YES];
}

- (void)validateWebLogin:(id)sender {
    self.loginButton.enabled = NO;
    self.loginMessage.stringValue = @"Vérification de la session et de ses quotas…";
    [self fetchOrganizations:^(NSArray *organizations, NSError *error) {
        if (!self.loginWindow) return;
        if (error || !organizations.count) { [self showLoginMessage:error.localizedDescription ?: @"Terminez la connexion à Claude."]; return; }
        if (self.loginCompletion) self.loginCompletion(organizations);
    }];
}
- (void)showLoginMessage:(NSString *)message {
    self.loginMessage.stringValue = message;
    self.loginButton.enabled = YES;
}
- (void)finishLogin { [self.loginWindow close]; }
- (void)windowWillClose:(NSNotification *)notification {
    [self.webView removeFromSuperview];
    self.loginWindow.delegate = nil;
    self.loginWindow = nil; self.loginMessage = nil; self.loginButton = nil;
    self.loginCompletion = nil;
}
- (WKWebView *)webView:(WKWebView *)webView createWebViewWithConfiguration:(WKWebViewConfiguration *)configuration
    forNavigationAction:(WKNavigationAction *)action windowFeatures:(WKWindowFeatures *)features {
    if (!action.targetFrame && self.loginVisible) [webView loadRequest:action.request];
    return nil;
}

- (void)seedCookieHeader:(NSString *)header completion:(void (^)(void))completion {
    WKHTTPCookieStore *store = [self ensureWebView].configuration.websiteDataStore.httpCookieStore;
    NSArray<NSHTTPCookie *> *cookies = TMCookiesFromHeader(header);
    if (!cookies.count) { if (completion) completion(); return; }
    __block NSUInteger remaining = cookies.count;
    for (NSHTTPCookie *cookie in cookies) {
        [store setCookie:cookie completionHandler:^{
            if (--remaining == 0) {
                self.loaded = NO;  // force un rechargement pour que la nouvelle session prenne
                if (completion) completion();
            }
        }];
    }
}

- (void)seedCookieIfNeeded:(NSString *)header {
    if (!header.length || [self.seededCookie isEqualToString:header]) { [self ensureWebView]; return; }
    self.seededCookie = header;
    [self seedCookieHeader:header completion:nil];
}

- (void)hardReloadWithCookieHeader:(NSString *)header completion:(void (^)(void))completion {
    if (!header.length) { if (completion) completion(); return; }
    self.loaded = NO;
    // Abandonne un chargement en cours éventuellement bloqué : ses appelants sont relâchés en
    // échec plutôt que laissés en attente pour toujours.
    [self finishLoad:NO];
    self.seededCookie = header;
    [self seedCookieHeader:header completion:completion];
}

- (void)ensureLoaded:(void (^)(BOOL ok))completion {
    if (self.loaded) { completion(YES); return; }
    [self.loadWaiters addObject:[completion copy]];
    if (self.loadWaiters.count > 1) return;  // un chargement est déjà en vol : on s'y accroche
    [[self ensureWebView] loadRequest:
        [NSURLRequest requestWithURL:[NSURL URLWithString:@"https://claude.ai/settings/usage"]]];
    // Cloudflare interpose parfois un défi qui se résout par une redirection JavaScript que WebKit
    // ne signale pas toujours comme une nouvelle navigation : se fier au seul didFinishNavigation
    // laissait l'app bloquée après un redémarrage, quand la réputation IP force un défi persistant.
    // On sonde donc le titre activement, jusqu'à sortir de l'interstitiel ou expirer.
    [self pollReadyWithDeadline:[NSDate dateWithTimeIntervalSinceNow:25]];
}

// Résout tous les appelants en attente, une seule fois.
- (void)finishLoad:(BOOL)ok {
    NSArray<void (^)(BOOL)> *waiters = [self.loadWaiters copy];
    [self.loadWaiters removeAllObjects];
    for (void (^waiter)(BOOL) in waiters) waiter(ok);
}

- (void)pollReadyWithDeadline:(NSDate *)deadline {
    if (!self.loadWaiters.count) return;  // déjà résolu par didFinishNavigation ou une sonde antérieure
    if ([deadline timeIntervalSinceNow] <= 0) {
        [self finishLoad:NO];
        return;
    }
    [self.webView evaluateJavaScript:@"document.title" completionHandler:^(id title, NSError *error) {
        if (!self.loadWaiters.count) return;  // résolu entre-temps
        BOOL challenging = [title isKindOfClass:NSString.class] && [(NSString *)title containsString:@"Just a moment"];
        BOOL loaded = [title isKindOfClass:NSString.class] && [(NSString *)title length] && !challenging;
        if (loaded) {
            self.loaded = YES;
            [self finishLoad:YES];
            return;
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(1 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self pollReadyWithDeadline:deadline];
        });
    }];
}

// Exécute un GET JSON dans le contexte de la page, seul endroit d'où les cookies de session sont
// envoyés et où le défi Cloudflare a déjà été franchi.
- (void)fetchJSON:(NSString *)path completion:(void (^)(id json, NSError *error))completion {
    [self ensureLoaded:^(BOOL ok) {
        if (!ok) {
            completion(nil, TMSessionError(@"Impossible de charger Claude. Ouvrez la connexion web du compte."));
            return;
        }
        if (![self.webView.URL.scheme isEqual:@"https"] || ![self.webView.URL.host isEqual:@"claude.ai"]) {
            completion(nil, TMSessionError(@"Terminez la connexion sur claude.ai avant de valider.")); return;
        }
        NSString *script = @"const ctl = new AbortController(); const timer = setTimeout(()=>ctl.abort(),15000); "
            "try { const r = await fetch(path, {credentials:'include',cache:'no-store',signal:ctl.signal, "
            "headers:{'Accept':'application/json'}}); if (!r.ok) throw new Error('HTTP ' + r.status); "
            "return await r.text(); } finally { clearTimeout(timer); }";
        [self.webView callAsyncJavaScript:script
                                arguments:@{@"path": path}
                                  inFrame:nil
                           inContentWorld:WKContentWorld.pageWorld
                        completionHandler:^(id result, NSError *error) {
            if (error || ![result isKindOfClass:NSString.class]) {
                // Une session périmée nous renvoie à la page de connexion, où le fetch part en 401.
                self.loaded = NO;
                completion(nil, TMSessionError(@"Session Claude indisponible. Vérifiez votre connexion web et réessayez."));
                return;
            }
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json) {
                self.loaded = NO;
                completion(nil, TMSessionError(@"Réponse claude.ai illisible (challenge Cloudflare ?)."));
                return;
            }
            completion(json, nil);
        }];
    }];
}

- (void)fetchUsage:(NSString *)orgId completion:(void (^)(NSDictionary *json, NSError *error))completion {
    NSString *path = [NSString stringWithFormat:@"/api/organizations/%@/usage", orgId];
    [self fetchJSON:path completion:^(id json, NSError *error) {
        completion([json isKindOfClass:NSDictionary.class] ? json : nil, error);
    }];
}

- (void)fetchOrganizations:(void (^)(NSArray *organizations, NSError *error))completion {
    [self fetchJSON:@"/api/organizations" completion:^(id json, NSError *error) {
        if (error) { completion(nil, error); return; }
        if (![json isKindOfClass:NSArray.class]) {
            completion(nil, TMSessionError(@"claude.ai n’a pas renvoyé la liste des organisations."));
            return;
        }
        NSMutableArray *organizations = [NSMutableArray array];
        for (id entry in (NSArray *)json) {
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSString *uuid = entry[@"uuid"], *name = entry[@"name"];
            if (![uuid isKindOfClass:NSString.class] || !uuid.length) continue;
            [organizations addObject:@{ @"uuid": uuid,
                                        @"name": [name isKindOfClass:NSString.class] ? name : uuid }];
        }
        if (!organizations.count) {
            completion(nil, TMSessionError(@"Cette session ne donne accès à aucune organisation Claude."));
            return;
        }
        completion(organizations, nil);
    }];
}

- (void)destroy {
    [self finishLogin];
    self.webView.UIDelegate = nil;
    self.webView.navigationDelegate = nil;
    self.webView = nil;
    self.loaded = NO;
    [self finishLoad:NO];
    self.seededCookie = nil;
    NSUUID *identifier = [[NSUUID alloc] initWithUUIDString:self.accountId];
    if (identifier) [WKWebsiteDataStore removeDataStoreForIdentifier:identifier completionHandler:^(NSError *error) { (void)error; }];
}

#pragma mark - WKNavigationDelegate

- (void)webView:(WKWebView *)webView didFinishNavigation:(WKNavigation *)navigation {
    // La page de défi Cloudflare finit elle aussi de charger, puis redirige vers la vraie page :
    // le chargement n'est exploitable qu'une fois sorti de l'interstitiel.
    [webView evaluateJavaScript:@"document.title" completionHandler:^(id title, NSError *error) {
        BOOL challenging = [title isKindOfClass:NSString.class] && [(NSString *)title containsString:@"Just a moment"];
        if (challenging) return;  // un autre didFinishNavigation arrivera une fois le défi résolu
        self.loaded = YES;
        [self finishLoad:YES];
    }];
}

@end
