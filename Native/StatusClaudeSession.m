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
// Mémoire : l'application web claude.ai pèse jusqu'à 1-2 Go par WebContent quand elle reste
// chargée. Les appels d'API partent donc d'un document minuscule de la même origine
// (robots.txt) ; l'application complète n'est chargée que pour franchir un défi Cloudflare ou
// lire la page Utilisation, puis la session y revient (« park »).
@property BOOL needsFullPage;
@property double lastProbeAt;
@property (nullable) NSDictionary *lastAvailability;
@end

static NSString *const TMClaudeLightURL = @"https://claude.ai/robots.txt";
static NSString *const TMClaudeUsageURL = @"https://claude.ai/settings/usage";

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
        [NSURLRequest requestWithURL:[NSURL URLWithString:self.needsFullPage ? TMClaudeUsageURL : TMClaudeLightURL]]];
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
    [self.webView evaluateJavaScript:@"[document.title, location.pathname]" completionHandler:^(id state, NSError *error) {
        if (!self.loadWaiters.count) return;  // résolu entre-temps
        NSArray *pair = [state isKindOfClass:NSArray.class] && [state count] == 2 ? state : @[@"", @""];
        id title = pair[0];
        BOOL challenging = [title isKindOfClass:NSString.class] && [(NSString *)title containsString:@"Just a moment"];
        // Le document léger (texte brut) n'a pas de titre : son chemin suffit.
        BOOL light = [pair[1] isEqual:@"/robots.txt"];
        BOOL loaded = !challenging && (light || ([title isKindOfClass:NSString.class] && [(NSString *)title length]));
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
    [self fetchJSON:path optional:NO completion:completion];
}

- (void)fetchJSON:(NSString *)path optional:(BOOL)optional completion:(void (^)(id json, NSError *error))completion {
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
                // Depuis le document léger, un échec signale le plus souvent un défi Cloudflare à
                // franchir : une seule nouvelle tentative, depuis l'application complète.
                if (!optional && !self.needsFullPage && !self.loginVisible) {
                    self.needsFullPage = YES; self.loaded = NO;
                    [self fetchJSON:path optional:optional completion:completion];
                    return;
                }
                // Une session périmée nous renvoie à la page de connexion, où le fetch part en 401.
                if (!optional) self.loaded = NO;
                completion(nil, TMSessionError(@"Session Claude indisponible. Vérifiez votre connexion web et réessayez."));
                return;
            }
            NSData *data = [(NSString *)result dataUsingEncoding:NSUTF8StringEncoding];
            id json = [NSJSONSerialization JSONObjectWithData:data options:0 error:nil];
            if (!json) {
                if (!optional) self.loaded = NO;
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
        if (error || ![json isKindOfClass:NSDictionary.class]) { completion(nil, error); return; }
        NSMutableDictionary *usage = [json mutableCopy];
        dispatch_group_t group = dispatch_group_create();
        for (NSString *endpoint in @[@"overage_spend_limit", @"prepaid/credits", @"subscription_details"]) {
            dispatch_group_enter(group);
            NSString *creditPath = [NSString stringWithFormat:@"/api/organizations/%@/%@", orgId, endpoint];
            [self fetchJSON:creditPath optional:YES completion:^(id creditJSON, NSError *creditError) {
                if (!creditError && [creditJSON isKindOfClass:NSDictionary.class]) usage[endpoint] = creditJSON;
                dispatch_group_leave(group);
            }];
        }
        dispatch_group_notify(group, dispatch_get_main_queue(), ^{ completion(usage, nil); });
    }];
}

- (void)checkManualResetAvailabilityForWeeklyUsedPercent:(double)expectedUsed
                                              completion:(void (^)(NSDictionary *availability))completion {
    NSDictionary *unknown = @{@"status": @"unknown"};
    if (!isfinite(expectedUsed) || expectedUsed < 0 || expectedUsed > 100) { [self park]; completion(unknown); return; }
    // Les crédits de reset et leurs expirations bougent rarement : la page Utilisation (l'application
    // complète, lourde) n'est relue qu'une fois par demi-heure ; entre-temps, le dernier état connu.
    double now = NSDate.date.timeIntervalSince1970;
    if (self.lastAvailability && now - self.lastProbeAt < 1800 && !self.loginVisible) {
        [self park]; completion(self.lastAvailability); return;
    }
    // La page est une SPA. Un sondage JSON des quotas ne met pas forcément son DOM à jour ; on
    // recharge la page Usage avant de lire l'offre, sauf si l'utilisateur y navigue lui-même.
    if (!self.loginVisible) { self.loaded = NO; self.needsFullPage = YES; }
    [self ensureLoaded:^(BOOL ok) {
        if (!ok) { [self park]; completion(unknown); return; }
        [self probeManualResetForExpectedUsed:expectedUsed attempts:12 completion:^(NSDictionary *availability) {
            if (![availability[@"status"] isEqual:@"unknown"]) { self.lastAvailability = availability; self.lastProbeAt = NSDate.date.timeIntervalSince1970; }
            [self park];
            completion(availability);
        }];
    }];
}

- (void)probeManualResetForExpectedUsed:(double)expectedUsed attempts:(NSInteger)attempts
                              completion:(void (^)(NSDictionary *availability))completion {
    if (attempts <= 0) { completion(@{@"status": @"unknown"}); return; }
    // La navigation initiale /settings/usage redirige vers /new#settings/usage. Une exécution JS
    // asynchrone lancée pendant cette redirection est annulée : chaque sonde est donc courte et
    // réessayée après navigation, sans jamais interpréter un échec comme « aucun reset ».
    // Lecture de la section « Réinitialisation de la limite » : une ligne par crédit, avec son titre
    // (« Réinitialisation complète ») et sa mention « Expiration : 22 oct. ». Rien n'est cliqué.
    NSString *script = @"if(location.origin!=='https://claude.ai' || "
        "!(location.pathname.startsWith('/settings/usage') || location.hash.startsWith('#settings/usage'))) "
        "return {ready:false}; "
        "const body=(document.body?.innerText||''); "
        "if(!/cette semaine|this week/i.test(body)) return {ready:false}; "
        // Garde de fraîcheur : si la jauge hebdo est lisible, elle doit refléter le relevé JSON.
        "const meters=[...document.querySelectorAll('[role=progressbar],[role=meter],progress')]; "
        "const name=e=>{ const id=e.getAttribute('aria-labelledby'); "
        "return e.getAttribute('aria-label') || (id&&document.getElementById(id)?.textContent) || e.parentElement?.textContent || ''; }; "
        "const meter=meters.find(e=>/^(cette semaine|this week|weekly usage)\\b/i.test(name(e).trim())); "
        "const used=parseFloat(meter?.getAttribute('aria-valuenow') ?? meter?.value ?? meter?.getAttribute('aria-valuetext')); "
        "if(meter && Number.isFinite(used) && Math.abs(used-expectedUsed)>3) return {ready:false}; "
        "const match=/reset\\s+for\\s+free|r[ée]initialiser\\s+gratuitement/i; "
        "const months={janv:0,jan:0,févr:1,fevr:1,feb:1,mars:2,mar:2,avr:3,apr:3,mai:4,may:4,juin:5,jun:5,juil:6,jul:6,août:7,aout:7,aug:7,sept:8,sep:8,oct:9,nov:10,déc:11,dec:11}; "
        "const parseDay=t=>{ const m=t.match(/(\\d{1,2})\\s+([a-zéû]+)\\.?(?:\\s+(\\d{4}))?|([a-z]+)\\.?\\s+(\\d{1,2})(?:,?\\s+(\\d{4}))?/i); if(!m) return null; "
        "const day=+(m[1]||m[5]), key=(m[2]||m[4]||'').toLowerCase(), month=months[key]??months[key.slice(0,4)]??months[key.slice(0,3)]; "
        "if(month==null||!(day>=1&&day<=31)) return null; const now=new Date(); let year=+(m[3]||m[6])||now.getFullYear(); "
        "let d=new Date(year,month,day,23,59,59); if(!(m[3]||m[6]) && d<now-86400000) d=new Date(year+1,month,day,23,59,59); return Math.floor(d/1000); }; "
        "const credits=[]; "
        "for(const b of document.querySelectorAll('button,[role=button]')){ "
        // Un bouton désactivé reste un crédit détenu (claude.ai ne l'active qu'à certains moments) :
        // il est compté, marqué non utilisable pour l'instant.
        "if(b.closest('[aria-hidden=true]') || getComputedStyle(b).display==='none') continue; "
        "if(!match.test((b.textContent||'')+' '+(b.getAttribute('aria-label')||''))) continue; "
        "let row=b.parentElement; for(let n=0;row&&n<4&&!/expir/i.test(row.innerText||'');n++) row=row.parentElement; "
        "const text=((row||b.parentElement)?.innerText||'').replace(/\\s+/g,' ').trim(); "
        "if(text.length>240) { credits.push({usable:!b.disabled}); continue; } "
        "const exp=text.match(/(?:expiration|expire[sd]?|expires on|expire le)\\s*:?\\s*([^·|]{3,30}?)(?=\\s*(?:réinitialiser|reset for|$))/i); "
        "const title=text.split(/expiration|expire/i)[0].replace(match,'').replace(/[\\uE000-\\uF8FF]/g,'').trim().slice(0,60); "
        "const scope=/5\\s*h|five.hour|session/i.test(text)?'session':/complète|full|hebdo|week/i.test(text)?'weekly':'unknown'; "
        "credits.push({title, expiryText:exp?exp[1].trim():'', expiresAt:exp?parseDay(exp[1]):null, scope, usable:!(b.disabled||b.getAttribute('aria-disabled')==='true')}); } "
        "const section=/réinitialisation de la limite|limit reset/i.test(body); "
        "return {ready:true, section, credits};";
    [self.webView callAsyncJavaScript:script arguments:@{@"expectedUsed": @(expectedUsed)} inFrame:nil
                       inContentWorld:WKContentWorld.pageWorld completionHandler:^(id result, NSError *error) {
        if (!error && [result isKindOfClass:NSDictionary.class] && [result[@"ready"] boolValue]) {
            NSArray *raw = [result[@"credits"] isKindOfClass:NSArray.class] ? result[@"credits"] : @[];
            NSMutableArray *credits = [NSMutableArray array];
            for (NSDictionary *credit in raw) {
                if (![credit isKindOfClass:NSDictionary.class]) continue;
                NSMutableDictionary *row = [NSMutableDictionary dictionary];
                if ([credit[@"title"] isKindOfClass:NSString.class] && [credit[@"title"] length]) row[@"title"] = credit[@"title"];
                if ([credit[@"expiresAt"] isKindOfClass:NSNumber.class] && [credit[@"expiresAt"] doubleValue] > 0) row[@"expiresAt"] = @([credit[@"expiresAt"] longLongValue]);
                else if ([credit[@"expiryText"] isKindOfClass:NSString.class] && [credit[@"expiryText"] length]) row[@"expiryText"] = credit[@"expiryText"];
                if ([credit[@"usable"] isKindOfClass:NSNumber.class] && ![credit[@"usable"] boolValue]) row[@"usable"] = @NO;
                [credits addObject:row];
            }
            long long observed = (long long)NSDate.date.timeIntervalSince1970;
            if (credits.count) {
                NSString *scope = [raw.firstObject isKindOfClass:NSDictionary.class] && [@[@"weekly", @"session"] containsObject:raw.firstObject[@"scope"]] ? raw.firstObject[@"scope"] : @"unknown";
                completion(@{@"status": @"available", @"scope": scope, @"count": @(credits.count), @"credits": credits, @"observedAt": @(observed)});
                return;
            }
            // Section lue sans bouton actif : aucun reset, affirmé seulement quand la section existe.
            if ([result[@"section"] boolValue]) { completion(@{@"status": @"none", @"observedAt": @(observed)}); return; }
        }
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.4 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{
            [self probeManualResetForExpectedUsed:expectedUsed attempts:attempts - 1 completion:completion];
        });
    }];
}

- (void)park {
    if (self.loginVisible || !self.webView || self.loadWaiters.count) return;
    if ([self.webView.URL.path isEqual:@"/robots.txt"]) { self.needsFullPage = NO; return; }
    // Naviguer ailleurs ne suffit pas : WebKit garde l'application quittée (cache de pages, tas
    // JavaScript) et le processus reste à 400 Mo+. On libère donc la vue elle-même, ce qui termine
    // son processus ; les cookies vivent dans le magasin persistant du compte, et la prochaine
    // lecture recrée une vue sur le document léger.
    self.needsFullPage = NO; self.loaded = NO;
    [self.webView stopLoading];
    self.webView.navigationDelegate = nil; self.webView.UIDelegate = nil;
    [self.webView removeFromSuperview];
    self.webView = nil;
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
