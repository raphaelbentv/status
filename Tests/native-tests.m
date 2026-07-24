// Tests de StatusQuota — la logique pure de Status.
//
//   ./scripts/run-tests.sh
//
// Ce qui est couvert ici est ce qui a réellement cassé en production : formats d'API non
// documentés, fenêtres expirées affichées comme courantes, et collages de cookie hétérogènes.
// Volontairement sans framework : un binaire, zéro dépendance, sortie lisible.

#import <Foundation/Foundation.h>
#import "StatusQuota.h"
#import "StatusAwake.h"
#import "StatusKeyboardLock.h"
#import "StatusSystemMonitor.h"
#import "StatusWindowManager.h"
#import "StatusDisplays.h"
#import "StatusCost.h"
#import "StatusFx.h"
#import <IOKit/pwr_mgt/IOPMLib.h>
#import <sys/sysctl.h>

static int gFailures = 0;
static int gChecks = 0;

static void Check(BOOL condition, NSString *what) {
    gChecks++;
    if (condition) {
        printf("  \033[32m✓\033[0m %s\n", what.UTF8String);
    } else {
        gFailures++;
        printf("  \033[31m✗ %s\033[0m\n", what.UTF8String);
    }
}

static void CheckEqual(id actual, id expected, NSString *what) {
    BOOL ok = (actual == expected) || [actual isEqual:expected];
    gChecks++;
    if (ok) {
        printf("  \033[32m✓\033[0m %s\n", what.UTF8String);
    } else {
        gFailures++;
        printf("  \033[31m✗ %s\033[0m\n     attendu: %s\n     obtenu : %s\n",
               what.UTF8String, [expected description].UTF8String, [actual description].UTF8String);
    }
}

static void Section(NSString *name) { printf("\n\033[1m%s\033[0m\n", name.UTF8String); }

#pragma mark - Coercition défensive

static void TestCoercion(void) {
    Section(@"TMNumber / TMInteger — champs manquants ou de type inattendu");
    CheckEqual(@(TMNumber(@42.5)), @42.5, @"nombre valide");
    CheckEqual(@(TMNumber(nil)), @0.0, @"nil -> 0");
    CheckEqual(@(TMNumber(@"abc")), @0.0, @"chaîne non numérique -> 0");
    CheckEqual(@(TMNumber(@"12.5")), @12.5, @"chaîne numérique -> valeur");
    CheckEqual(@(TMInteger(@7)), @7, @"entier valide");
    CheckEqual(@(TMInteger([NSNull null])), @0, @"NSNull -> 0");
    CheckEqual(@(TMInteger(@{})), @0, @"dictionnaire -> 0");
}

static void TestISODate(void) {
    Section(@"TMParseISODate — les deux formats servis par claude.ai");
    Check(TMParseISODate(@"2026-07-21T12:59:59.902498+00:00") != nil, @"avec fraction de seconde");
    Check(TMParseISODate(@"2026-07-21T12:59:59+00:00") != nil, @"sans fraction de seconde");
    Check(TMParseISODate(@"pas une date") == nil, @"chaîne invalide -> nil");
    Check(TMParseISODate(nil) == nil, @"nil -> nil");
    Check(TMParseISODate(@"") == nil, @"vide -> nil");
}

#pragma mark - Cookies

static void TestCookieExtraction(void) {
    Section(@"TMExtractCookieHeader — collages hétérogènes");
    NSString *chrome = @"curl 'https://claude.ai/api/organizations/abc/usage' \\\n"
                        "  -H 'accept: application/json' \\\n"
                        "  -H 'cookie: sessionKey=sk-ant-FAKE; lastActiveOrg=abc' \\\n"
                        "  -H 'user-agent: Mozilla/5.0'";
    CheckEqual(TMExtractCookieHeader(chrome), @"sessionKey=sk-ant-FAKE; lastActiveOrg=abc",
               @"« Copier comme cURL » de Chrome");
    CheckEqual(TMExtractCookieHeader(@"curl \"https://claude.ai/x\" -H \"Cookie: sessionKey=sk-D\""),
               @"sessionKey=sk-D", @"guillemets doubles + Cookie capitalisé");
    CheckEqual(TMExtractCookieHeader(@"curl 'https://x' -b 'sessionKey=sk-B; foo=bar'"),
               @"sessionKey=sk-B; foo=bar", @"drapeau -b");
    CheckEqual(TMExtractCookieHeader(@"sessionKey=sk-RAW; other=1"),
               @"sessionKey=sk-RAW; other=1", @"cookie brut collé directement");
    CheckEqual(TMExtractCookieHeader(@"curl 'https://x' -H 'accept: */*'"), @"",
               @"cURL sans cookie -> vide (et non un faux positif)");
    CheckEqual(TMExtractCookieHeader(@"   "), @"", @"entrée vide -> vide");
}

static void TestCookieConversion(void) {
    Section(@"TMCookiesFromHeader — cf_clearance ne doit jamais être ressemé");
    NSArray<NSHTTPCookie *> *cookies = TMCookiesFromHeader(@"sessionKey=abc; cf_clearance=STALE; __cf_bm=X; lastOrg=1");
    NSMutableArray *names = [NSMutableArray array];
    for (NSHTTPCookie *c in cookies) [names addObject:c.name];
    Check([names containsObject:@"sessionKey"], @"sessionKey est conservé");
    Check([names containsObject:@"lastOrg"], @"les cookies applicatifs sont conservés");
    Check(![names containsObject:@"cf_clearance"], @"cf_clearance est écarté (périmé, lié à l'IP/UA)");
    Check(![names containsObject:@"__cf_bm"], @"__cf_bm est écarté");
    CheckEqual(@(cookies.count), @2, @"seuls les 2 cookies utiles subsistent");

    NSArray *malformed = TMCookiesFromHeader(@"; =novalue; noequals; ok=1");
    CheckEqual(@(malformed.count), @1, @"les paires malformées sont ignorées");
}

#pragma mark - Fenêtres

static void TestWindowLabels(void) {
    Section(@"TMQuotaWindowLabel — durées en minutes");
    CheckEqual(TMQuotaWindowLabel(300), @"5 h", @"300 min -> 5 h");
    CheckEqual(TMQuotaWindowLabel(10080), @"Semaine", @"10080 min -> Semaine");
    CheckEqual(TMQuotaWindowLabel(1440), @"24 h", @"1440 min -> 24 h");
    CheckEqual(TMQuotaWindowLabel(0), @"Période", @"0 -> libellé générique");
}

static void TestSnapshotParsing(void) {
    Section(@"TMClaudeWindowsFromSnapshot — status line officielle");
    NSDictionary *snapshot = @{
        @"schema_version": @1, @"provider": @"claude",
        @"rate_limits": @{
            @"five_hour": @{@"used_percentage": @34.0, @"resets_at": @4102444800},
            @"seven_day": @{@"used_percentage": @25.0, @"resets_at": @4102444800}
        }
    };
    NSArray *windows = TMClaudeWindowsFromSnapshot(snapshot);
    CheckEqual(@(windows.count), @2, @"les deux fenêtres sont lues");
    CheckEqual(windows[0][@"windowId"], @"five_hour", @"five_hour vient en premier");
    CheckEqual(windows[0][@"usedPercent"], @34.0, @"pourcentage consommé");
    CheckEqual(windows[0][@"remainingPercent"], @66.0, @"restant = 100 - consommé");

    CheckEqual(@(TMClaudeWindowsFromSnapshot(@{@"schema_version": @99}).count), @0,
               @"schéma inconnu -> vide (pas de crash)");
    CheckEqual(@(TMClaudeWindowsFromSnapshot(nil).count), @0, @"nil -> vide");
    CheckEqual(@(TMClaudeWindowsFromSnapshot(@{@"schema_version": @1, @"provider": @"claude",
                 @"rate_limits": @{@"x": @{@"used_percentage": @10.0}}}).count), @0,
               @"fenêtre sans resets_at -> écartée");
}

static void TestUsagePayloadParsing(void) {
    Section(@"TMClaudeWindowsFromUsagePayload — réponse claude.ai (non documentée)");
    NSDictionary *payload = @{@"limits": @[
        @{@"kind": @"session", @"percent": @5, @"resets_at": @"2099-07-14T23:09:59.902473+00:00"},
        @{@"kind": @"weekly_all", @"percent": @10, @"resets_at": @"2099-07-21T12:59:59.902498+00:00"},
        @{@"kind": @"weekly_scoped", @"percent": @7, @"resets_at": @"2099-07-21T12:59:59.902865+00:00",
          @"scope": @{@"model": @{@"display_name": @"Fable"}}}
    ]};
    NSArray *windows = TMClaudeWindowsFromUsagePayload(payload);
    CheckEqual(@(windows.count), @3, @"les trois jauges sont lues (dont Fable)");
    CheckEqual(windows[0][@"windowId"], @"five_hour", @"session -> five_hour");
    CheckEqual(windows[1][@"windowId"], @"seven_day", @"weekly_all -> seven_day");
    CheckEqual(windows[2][@"label"], @"7 j · Fable", @"weekly_scoped porte le nom du modèle");
    CheckEqual(windows[2][@"usedPercent"], @7.0, @"pourcentage du scoped");

    // Robustesse : si Anthropic ajoute un type, il doit apparaître plutôt que disparaître.
    NSArray *unknown = TMClaudeWindowsFromUsagePayload(@{@"limits": @[
        @{@"kind": @"monthly_new", @"percent": @50, @"resets_at": @"2099-08-01T00:00:00+00:00"}]});
    CheckEqual(@(unknown.count), @1, @"un type inconnu est surfacé, pas ignoré");
    CheckEqual(unknown[0][@"label"], @"monthly new", @"libellé générique dérivé du kind");

    CheckEqual(@(TMClaudeWindowsFromUsagePayload(@{}).count), @0, @"payload vide -> vide");
    CheckEqual(@(TMClaudeWindowsFromUsagePayload(@{@"limits": @[@{@"kind": @"session"}]}).count), @0,
               @"sans resets_at -> écartée");
}

static void TestExpiredWindows(void) {
    Section(@"TMDropExpiredWindows — le bug observé en production");
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    NSArray *windows = @[
        @{@"windowId": @"old", @"resetsAt": @(now - 3600), @"usedPercent": @34.0},
        @{@"windowId": @"live", @"resetsAt": @(now + 3600), @"usedPercent": @25.0}
    ];
    NSArray *kept = TMDropExpiredWindows(windows);
    CheckEqual(@(kept.count), @1, @"une fenêtre dont le reset est passé est écartée");
    CheckEqual(kept[0][@"windowId"], @"live", @"la fenêtre encore valide est conservée");
    CheckEqual(@(TMDropExpiredWindows(@[]).count), @0, @"liste vide -> vide");
}

static void TestWindowClassification(void) {
    Section(@"TMWindowIsSession / TMWindowIsWeekly");
    Check(TMWindowIsSession(@{@"windowId": @"five_hour"}), @"five_hour est une session");
    Check(TMWindowIsSession(@{@"durationMinutes": @300}), @"300 min est une session");
    Check(!TMWindowIsSession(@{@"windowId": @"seven_day"}), @"seven_day n'est pas une session");
    Check(TMWindowIsWeekly(@{@"windowId": @"seven_day"}), @"seven_day est hebdomadaire");
    Check(TMWindowIsWeekly(@{@"windowId": @"seven_day_scoped_fable"}), @"une fenêtre scoped est hebdomadaire");
    Check(!TMWindowIsWeekly(@{@"windowId": @"overage"}), @"overage n'est pas une fenêtre hebdomadaire");

    Section(@"TMMaxUsedPercent — retient la fenêtre la plus contrainte");
    double out = 0;
    BOOL found = TMMaxUsedPercent(@[@[@{@"windowId": @"five_hour", @"usedPercent": @30.0},
                                      @{@"windowId": @"five_hour", @"usedPercent": @70.0}]],
                                  ^BOOL(NSDictionary *w) { return TMWindowIsSession(w); }, &out);
    Check(found, @"une session est trouvée");
    CheckEqual(@(out), @70.0, @"le maximum est retenu (marge la plus faible)");

    out = 0;
    found = TMMaxUsedPercent(@[@[]], ^BOOL(NSDictionary *w) { return TMWindowIsSession(w); }, &out);
    Check(!found, @"aucune fenêtre -> non trouvé (et non 0 %)");
}

#pragma mark - Historique

// Deux limites OpenAI distinctes partagent la même durée de 7 jours. Elles étaient toutes deux
// libellées « Semaine » et dépourvues de windowId : à l'écran on ne pouvait pas les distinguer, et
// dans l'historique elles écrasaient la même clé — la moitié de la donnée était perdue en silence.
static NSDictionary *TMFakeOpenAIResponse(void) {
    return @{
        @"rateLimits": @{
            @"limitId": @"codex", @"limitName": @"Codex",
            @"primary": @{@"windowDurationMins": @10080, @"usedPercent": @84, @"resetsAt": @1000}
        },
        @"rateLimitsByLimitId": @{
            @"gpt5": @{
                @"limitId": @"gpt5", @"limitName": @"GPT-5",
                @"primary": @{@"windowDurationMins": @10080, @"usedPercent": @1, @"resetsAt": @2000}
            }
        }
    };
}

static void TestOpenAIWindowIdentity(void) {
    printf("\n\033[1mIdentité des fenêtres OpenAI\033[0m\n");
    NSDictionary *account = @{@"type": @"chatgpt", @"email": @"x@y.z", @"planType": @"pro"};
    NSArray *windows = TMOpenAIAccountPayload(account, TMFakeOpenAIResponse(), NO, nil)[@"windows"];

    Check(windows.count == 2, @"deux limites distinctes produisent deux fenêtres");
    NSSet *ids = [NSSet setWithArray:[windows valueForKey:@"windowId"]];
    Check(ids.count == 2, @"chaque fenêtre a un windowId unique");
    Check(![ids containsObject:[NSNull null]], @"aucun windowId nul");

    NSSet *labels = [NSSet setWithArray:[windows valueForKey:@"label"]];
    Check(labels.count == 2, @"les libellés distinguent les deux limites");
    Check([labels containsObject:@"Codex · Semaine"], @"le nom de la limite apparaît dans le libellé");
    Check([labels containsObject:@"GPT-5 · Semaine"], @"le nom de la seconde limite aussi");

    // Le libellé porte désormais le nom de la limite, donc la reconnaissance ne peut plus s'y fier.
    // Elle doit tenir sur la durée, sinon la jauge OpenAI disparaît de la barre des menus.
    for (NSDictionary *w in windows) {
        Check(TMInteger(w[@"durationMinutes"]) == 10080, @"la durée reste exploitable");
        Check(TMWindowIsWeekly(w), @"classée hebdo malgré le libellé nommé");
        Check(!TMWindowIsSession(w), @"pas confondue avec une fenêtre de 5 h");
    }
}

static void TestOpenAIHistoryCollision(void) {
    printf("\n\033[1mHistorique OpenAI — collision de clés\033[0m\n");
    setenv("STATUS_SUPPORT_DIR", "/tmp/status-tests-openai", 1);
    [NSFileManager.defaultManager removeItemAtPath:TMHistoryPath() error:nil];

    NSDictionary *account = @{@"type": @"chatgpt", @"email": @"x@y.z", @"planType": @"pro"};
    NSArray *windows = TMOpenAIAccountPayload(account, TMFakeOpenAIResponse(), NO, nil)[@"windows"];
    NSArray *history = TMAppendHistory(@[], windows, 5000);

    NSDictionary *points = history.lastObject[@"p"];
    Check(points.count == 2, @"les deux limites sont historisées séparément");
    NSSet *values = [NSSet setWithArray:points.allValues];
    Check([values containsObject:@84] && [values containsObject:@1], @"84 % et 1 % survivent tous les deux");
    [NSFileManager.defaultManager removeItemAtPath:TMHistoryPath() error:nil];
}

static void TestHistory(void) {
    Section(@"TMAppendHistory — série locale");
    // Isole le test des données réelles. Redéfinir HOME ne suffirait pas (Foundation met le chemin
    // en cache), d'où l'override explicite honoré par TMSupportDirectory.
    NSString *sandbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"status-tests"];
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
    setenv("STATUS_SUPPORT_DIR", sandbox.UTF8String, 1);
    Check([TMSupportDirectory() isEqualToString:sandbox], @"les tests écrivent dans un bac à sable");

    NSArray *claude = @[@{@"windowId": @"five_hour", @"usedPercent": @34.0}];
    NSArray *openai = @[@{@"windowId": @"seven_day", @"usedPercent": @41.0}];

    long long t0 = 1784000000;
    NSArray *h1 = TMAppendHistory(claude, openai, t0);
    CheckEqual(@(h1.count), @1, @"premier point enregistré");
    CheckEqual(h1[0][@"p"][@"claude:five_hour"], @34, @"le point Claude est présent");
    CheckEqual(h1[0][@"p"][@"openai:seven_day"], @41, @"le point OpenAI est présent");

    NSArray *h2 = TMAppendHistory(claude, openai, t0 + 30);
    CheckEqual(@(h2.count), @1, @"un point < 2 min après est fusionné (pas de doublon)");

    NSArray *h3 = TMAppendHistory(claude, openai, t0 + 200);
    CheckEqual(@(h3.count), @2, @"un point > 2 min après est ajouté");

    NSArray *h4 = TMAppendHistory(@[], @[], t0 + 400);
    CheckEqual(@(h4.count), @2, @"sans fenêtre, rien n'est enregistré");

    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
}

static void TestAccountsCache(void) {
    Section(@"TMSaveAccountsCache / TMLoadAccountsCache — volumes persistés au redémarrage");
    NSString *sandbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"status-tests-accounts"];
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
    setenv("STATUS_SUPPORT_DIR", sandbox.UTF8String, 1);

    Check(TMLoadAccountsCache() == nil, @"aucun cache au départ : nil (démarrage vide, comme avant)");

    NSDictionary *accounts = @{
        @"claude": @{ @"windows": @[@{@"windowId": @"seven_day", @"usedPercent": @62.0, @"resetsAt": @4102444800}],
                      @"capturedAt": @1784000000, @"authenticated": @YES },
        @"openai": @{ @"windows": @[], @"connected": @NO }
    };
    TMSaveAccountsCache(accounts);
    NSDictionary *loaded = TMLoadAccountsCache();
    Check(loaded != nil, @"le cache se recharge après écriture");
    CheckEqual(loaded[@"claude"][@"windows"][0][@"usedPercent"], @62, @"les volumes Claude survivent au round-trip");
    CheckEqual(loaded[@"claude"][@"capturedAt"], @1784000000, @"l'horodatage de la dernière mesure est conservé");

    // Robustesse : une entrée non sérialisable n'écrase pas un cache valide par un fichier corrompu.
    TMSaveAccountsCache((NSDictionary *)@"pas un dictionnaire");
    Check(TMLoadAccountsCache() != nil, @"une entrée invalide laisse le cache précédent intact");
    TMSaveAccountsCache(@{});
    // Un dictionnaire vide est ignoré (guard !count) : le dernier cache valide reste.
    CheckEqual(TMLoadAccountsCache()[@"claude"][@"windows"][0][@"usedPercent"], @62, @"dictionnaire vide ignoré : cache valide préservé");

    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
}

// Interroge IOKit plutôt que notre propre état : c'est la seule façon de savoir si l'assertion
// existe vraiment. Filtré sur notre pid — une autre app tenant la même assertion ne doit pas
// rendre ce test faussement vert.
static BOOL TMOurSleepAssertionPresent(void) {
    CFDictionaryRef raw = NULL;
    if (IOPMCopyAssertionsByProcess(&raw) != kIOReturnSuccess || !raw) return NO;
    NSDictionary *byPid = CFBridgingRelease(raw);
    for (NSDictionary *assertion in byPid[@(getpid())]) {
        NSString *type = assertion[(__bridge NSString *)kIOPMAssertionTypeKey];
        if ([type isEqualToString:(__bridge NSString *)kIOPMAssertionTypePreventUserIdleDisplaySleep]) return YES;
    }
    return NO;
}

static void TestAwake(void) {
    printf("\n\033[1mTMAwake\033[0m\n");
    TMAwake *awake = [TMAwake new];
    Check(!awake.isEnabled, @"éteint au départ");
    Check(!TMOurSleepAssertionPresent(), @"aucune assertion au départ");

    awake.enabled = YES;
    Check(awake.isEnabled, @"s'allume");
    Check(TMOurSleepAssertionPresent(), @"IOKit voit notre assertion");

    awake.enabled = YES;  // idempotent : ne doit pas créer une seconde assertion fuyante
    Check(awake.isEnabled, @"rallumer ne change rien");

    awake.enabled = NO;
    Check(!awake.isEnabled, @"s'éteint");
    Check(!TMOurSleepAssertionPresent(), @"IOKit ne voit plus d'assertion");
}

static void TestHoldFraction(void) {
    printf("\n\033[1mTMHoldFraction\033[0m\n");
    Check(TMHoldFraction(0.0, 1.0) == 0.0, @"rien de maintenu = 0");
    Check(TMHoldFraction(0.5, 1.0) == 0.5, @"moitié du temps = 0,5");
    Check(TMHoldFraction(1.0, 1.0) == 1.0, @"temps atteint = 1");
    Check(TMHoldFraction(9.0, 1.0) == 1.0, @"borné à 1 : l'anneau ne déborde pas");
    Check(TMHoldFraction(-3.0, 1.0) == 0.0, @"borné à 0 : une horloge qui recule ne casse rien");
    Check(TMHoldFraction(0.5, 0.0) == 1.0, @"durée nulle : pas de division par zéro");
}

static void TestLockStateMachine(void) {
    printf("\n\033[1mTMLockStateAfterToggle\033[0m\n");
    Check(TMLockStateAfterToggle(TMLockStateUnlocked, YES) == TMLockStateLocked,
          @"permission accordée : verrouille");
    Check(TMLockStateAfterToggle(TMLockStateUnlocked, NO) == TMLockStateBlocked,
          @"permission absente : bloqué, pas de faux verrou");
    Check(TMLockStateAfterToggle(TMLockStateBlocked, YES) == TMLockStateLocked,
          @"permission accordée après coup : verrouille");
    Check(TMLockStateAfterToggle(TMLockStateBlocked, NO) == TMLockStateBlocked,
          @"toujours pas de permission : reste bloqué");
    Check(TMLockStateAfterToggle(TMLockStateLocked, YES) == TMLockStateUnlocked,
          @"verrouillé : déverrouille");
    // Le cas qui compte : la permission est révoquée pendant le verrou. On doit pouvoir sortir.
    Check(TMLockStateAfterToggle(TMLockStateLocked, NO) == TMLockStateUnlocked,
          @"permission révoquée pendant le verrou : on sort quand même");
}

#pragma mark - Moniteur système

static void TestMetricRing(void) {
    Section(@"TMMetricRing — fenêtre glissante");
    TMMetricRing *ring = [[TMMetricRing alloc] initWithCapacity:3];
    CheckEqual(ring.series, @[], @"anneau neuf : série vide");
    [ring push:1]; [ring push:2];
    CheckEqual(ring.series, (@[@1.0, @2.0]), @"avant remplissage : série partielle, ordonnée");
    Check(ring.count == 2, @"count suit les insertions");
    [ring push:3]; [ring push:4];
    CheckEqual(ring.series, (@[@2.0, @3.0, @4.0]), @"plein : écrase le plus ancien, ordre préservé");
    Check(ring.count == 3, @"count plafonne à la capacité");
    [ring push:5]; [ring push:6]; [ring push:7];
    CheckEqual(ring.series, (@[@5.0, @6.0, @7.0]), @"après plusieurs tours : toujours les N derniers");
}

static void TestRatePerSecond(void) {
    Section(@"TMRatePerSecond — compteurs cumulatifs");
    double rate = -1;
    Check(TMRatePerSecond(1000, 3000, 2.0, &rate) && rate == 1000.0, @"cas nominal : (3000-1000)/2s");
    Check(!TMRatePerSecond(3000, 1000, 1.0, &rate), @"compteur qui recule : échantillon écarté");
    Check(!TMRatePerSecond(1000, 2000, 0, &rate), @"intervalle nul : écarté, pas de division par zéro");
    Check(!TMRatePerSecond(1000, 2000, -1.0, &rate), @"intervalle négatif : écarté");
    Check(TMRatePerSecond(500, 500, 1.0, &rate) && rate == 0.0, @"compteur immobile : débit nul, pas une erreur");
}

static void TestCPUPercent(void) {
    Section(@"TMCPUPercentBetweenTicks — ticks vers pourcentage");
    double pct = -1;
    Check(TMCPUPercentBetweenTicks(100, 400, 150, 500, &pct) && pct == 50.0, @"50 actifs sur 100 écoulés = 50%");
    Check(TMCPUPercentBetweenTicks(0, 0, 0, 100, &pct) && pct == 0.0, @"aucun tick actif = 0%");
    Check(TMCPUPercentBetweenTicks(0, 0, 100, 100, &pct) && pct == 100.0, @"tous actifs = 100%");
    Check(!TMCPUPercentBetweenTicks(100, 400, 150, 400, &pct), @"total figé : écarté");
    Check(!TMCPUPercentBetweenTicks(400, 500, 100, 600, &pct), @"compteur actif qui recule : écarté");
    Check(TMCPUPercentBetweenTicks(0, 400, 200, 500, &pct) && pct == 100.0, @"actifs > écoulés (arrondi noyau) : borné à 100");
}

static void TestSystemMonitorSnapshot(void) {
    Section(@"TMSystemMonitor — collecteurs et snapshot");
    __block BOOL gpuAvailable = YES;
    TMSystemMonitor *monitor = [[TMSystemMonitor alloc] initWithCollectors:@{
        @"cpu": ^{ return @{@"total": @25.0}; },
        @"gpu": ^NSDictionary<NSString *, NSNumber *> *{ return gpuAvailable ? @{@"usage": @40.0} : nil; },
    } familyOrder:@[@"cpu", @"gpu"]];

    [monitor sample];
    NSArray *families = [monitor snapshot][@"families"];
    Check([families count] == 2, @"les deux collecteurs répondent : deux familles");
    CheckEqual([families.firstObject objectForKey:@"id"], @"cpu", @"l'ordre du snapshot est familyOrder");
    CheckEqual([families.firstObject valueForKeyPath:@"now.total"], @25.0, @"now expose la dernière valeur");
    CheckEqual([families.firstObject valueForKeyPath:@"series.total"], (@[@25.0]), @"series accumule");

    [monitor sample];
    families = [monitor snapshot][@"families"];
    CheckEqual([families.firstObject valueForKeyPath:@"series.total"], (@[@25.0, @25.0]), @"deux échantillons, deux points");

    gpuAvailable = NO;
    [monitor sample];
    families = [monitor snapshot][@"families"];
    Check([families count] == 1, @"collecteur à nil : la famille sort du snapshot, sans état d'erreur");
    CheckEqual([families.firstObject objectForKey:@"id"], @"cpu", @"les familles restantes ne bougent pas");
    CheckEqual([families.firstObject valueForKeyPath:@"series.total"], (@[@25.0, @25.0, @25.0]),
               @"la panne d'une famille n'interrompt pas l'échantillonnage des autres");

    gpuAvailable = YES;
    [monitor sample];
    families = [monitor snapshot][@"families"];
    Check([families count] == 2, @"le collecteur revit : la famille réapparaît");
    CheckEqual([[families lastObject] valueForKeyPath:@"series.usage"], (@[@40.0, @40.0, @40.0]),
               @"série GPU : les échantillons du trou n'existent pas, pas de zéros inventés");

    Check([NSJSONSerialization isValidJSONObject:[monitor snapshot]], @"le snapshot est sérialisable tel quel");
}

// Construit un historique : `values` échantillonnés toutes les `stepSeconds`, le dernier à `endAt`.
static NSArray *TMHistoryFrom(NSString *key, NSArray<NSNumber *> *values, NSTimeInterval endAt, NSTimeInterval stepSeconds) {
    NSMutableArray *history = [NSMutableArray array];
    NSInteger count = values.count;
    for (NSInteger i = 0; i < count; i++) {
        [history addObject:@{ @"t": @(endAt - (count - 1 - i) * stepSeconds), @"p": @{ key: values[i] } }];
    }
    return history;
}

static void TestForecastExhaustion(void) {
    Section(@"TMForecastExhaustion — prévision d'épuisement");
    const NSTimeInterval now = 1000000, hour = 3600;
    NSTimeInterval at = 0;

    // 10 %/h sur 5 h, à 50 % : il reste 50 points, soit 5 h.
    NSArray *steady = TMHistoryFrom(@"claude:weekly", (@[@0, @10, @20, @30, @40, @50]), now, hour);
    Check(TMForecastExhaustion(steady, @"claude:weekly", now + 100 * hour, &at), @"pente régulière : prévision rendue");
    Check(fabs(at - (now + 5 * hour)) < 60, @"50 % restants à 10 %/h ⇒ épuisé dans ~5 h");

    // Une fenêtre qui tient jusqu'au bout n'a pas besoin d'être annoncée comme menacée.
    Check(!TMForecastExhaustion(steady, @"claude:weekly", now + 2 * hour, &at),
          @"épuisement prévu après le reset : la fenêtre tient, pas de prévision");

    NSArray *flat = TMHistoryFrom(@"k", (@[@40, @40, @40, @40]), now, hour);
    Check(!TMForecastExhaustion(flat, @"k", now + 100 * hour, &at), @"consommation stable : rien à prévoir");
    NSArray *falling = TMHistoryFrom(@"k", (@[@60, @50, @40]), now, hour);
    Check(!TMForecastExhaustion(falling, @"k", now + 100 * hour, &at), @"consommation en baisse : rien à prévoir");

    Check(!TMForecastExhaustion(@[], @"k", now + 100 * hour, &at), @"historique vide");
    NSArray *single = TMHistoryFrom(@"k", @[@30], now, hour);
    Check(!TMForecastExhaustion(single, @"k", now + 100 * hour, &at), @"un seul point : aucune pente");
    NSArray *tooShort = TMHistoryFrom(@"k", (@[@10, @20]), now, 60);  // 1 min d'écart
    Check(!TMForecastExhaustion(tooShort, @"k", now + 100 * hour, &at),
          @"moins de 15 min couvertes : trop court pour extrapoler");

    // Le cas piège : l'historique traverse une réinitialisation. Sans filtrage, la chute
    // 80 → 5 donnerait une pente négative et effacerait une consommation pourtant vive.
    NSArray *acrossReset = TMHistoryFrom(@"k", (@[@60, @70, @80, @5, @15, @25]), now, hour);
    Check(TMForecastExhaustion(acrossReset, @"k", now + 100 * hour, &at),
          @"historique traversant un reset : prévision quand même rendue");
    Check(fabs(at - (now + 7.5 * hour)) < 300, @"seuls les points post-reset comptent : 75 % à 10 %/h ⇒ ~7,5 h");

    NSArray *otherKey = TMHistoryFrom(@"autre", (@[@10, @20, @30]), now, hour);
    Check(!TMForecastExhaustion(otherKey, @"k", now + 100 * hour, &at), @"clé absente de l'historique");

    // Points hétérogènes : le collecteur peut écrire une entrée sans la clé attendue.
    NSArray *withGaps = @[
        @{ @"t": @(now - 4 * hour), @"p": @{ @"k": @20 } },
        @{ @"t": @(now - 3 * hour), @"p": @{ @"autre": @99 } },
        @{ @"t": @(now - 2 * hour), @"p": @{ @"k": @40 } },
        @{ @"t": @(now), @"p": @{ @"k": @80 } },
    ];
    Check(TMForecastExhaustion(withGaps, @"k", now + 100 * hour, &at), @"entrées sans la clé : ignorées, pas fatales");
}

static NSDictionary *TMProc(NSString *name, uint64_t cpuNs, uint64_t rss) {
    return @{ @"name": name, @"cpuTimeNs": @(cpuNs), @"rssBytes": @(rss) };
}
static NSDictionary *TMProcE(NSString *name, uint64_t cpuNs, uint64_t rss, uint64_t energyNJ) {
    return @{ @"name": name, @"cpuTimeNs": @(cpuNs), @"rssBytes": @(rss), @"energyNJ": @(energyNJ) };
}

static void TestTopProcesses(void) {
    Section(@"TMTopProcesses — union top-CPU ∪ top-RAM");
    NSDictionary *previous = @{ @"10": TMProc(@"chrome", 1000000000, 500), @"20": TMProc(@"node", 500000000, 300),
                                @"30": TMProc(@"idle_app", 100000000, 100) };
    NSDictionary *current  = @{ @"10": TMProc(@"chrome", 2000000000, 520), @"20": TMProc(@"node", 1750000000, 310),
                                @"30": TMProc(@"idle_app", 100000000, 100) };
    NSArray *top = TMTopProcesses(previous, current, 2.0, 5);
    Check(top.count == 3, @"trois processus mesurés");
    CheckEqual(top.firstObject[@"name"], @"node", @"tranche CPU en tête : node (62,5 %) devant chrome (50 %)");
    CheckEqual(top.firstObject[@"cpuPercent"], @62.5, @"1,25 s de CPU sur 2 s = 62,5 %");
    CheckEqual(top.firstObject[@"rssBytes"], @310, @"la RSS vient du relevé courant");
    CheckEqual(top.firstObject[@"pid"], @"20", @"le pid accompagne chaque entrée");

    // Le tri par mémoire garde un gros consommateur RAM que le tri CPU seul écarterait.
    NSDictionary *prevMix = @{ @"10": TMProc(@"busy", 1000000000, 100), @"20": TMProc(@"greedy_ram", 100000000, 100) };
    NSDictionary *curMix  = @{ @"10": TMProc(@"busy", 3000000000, 100),      // +2 s CPU, peu de RAM
                              @"20": TMProc(@"greedy_ram", 100000000, 9000),  // 0 % CPU, énorme RAM
                              @"30": TMProc(@"middle", 1100000000, 50) };     // apparu, mais count=1 l'écarte
    NSArray *mix = TMTopProcesses(prevMix, curMix, 2.0, 1);
    NSArray *mixNames = [mix valueForKey:@"name"];
    Check(mix.count == 2, @"count=1 par dimension : union = top-1 CPU + top-1 RAM = 2 process");
    Check([mixNames containsObject:@"busy"], @"le plus gourmand CPU est là");
    Check([mixNames containsObject:@"greedy_ram"], @"le plus gros RAM est là, malgré 0 % CPU");
    Check(![mixNames containsObject:@"middle"], @"ni top CPU ni top RAM : écarté");

    Check(TMTopProcesses(previous, current, 0, 5).count == 0, @"intervalle nul : rien, pas de division");

    // Nouveau changement de sémantique : un process sans delta CPU exploitable est CONSERVÉ avec
    // cpuPercent = 0 (éligible au tri mémoire), au lieu d'être écarté.
    NSDictionary *reborn = @{ @"10": TMProc(@"chrome", 2000000000, 520), @"40": TMProc(@"nouveau", 900000000, 50) };
    NSArray *rebornTop = TMTopProcesses(previous, reborn, 2.0, 5);
    Check([[rebornTop valueForKey:@"name"] containsObject:@"nouveau"], @"pid apparu depuis : conservé (cpu 0), éligible RAM");
    for (NSDictionary *p in rebornTop) if ([p[@"name"] isEqual:@"nouveau"]) CheckEqual(p[@"cpuPercent"], @0.0, @"nouveau : cpuPercent = 0, pas de delta inventé");
    NSDictionary *reused = @{ @"10": TMProc(@"autre_app", 100, 60) };
    NSArray *reusedTop = TMTopProcesses(previous, reused, 2.0, 5);
    Check(reusedTop.count == 1 && [reusedTop.firstObject[@"cpuPercent"] isEqual:@0.0], @"CPU qui recule (pid réutilisé) : cpuPercent forcé à 0, pas de pic négatif");

    NSDictionary *burst = @{ @"10": TMProc(@"video_export", 7000000000, 800) };
    NSArray *burstTop = TMTopProcesses(previous, burst, 2.0, 5);
    CheckEqual(burstTop.firstObject[@"cpuPercent"], @300.0, @"multithread : 300 % légitime, non plafonné");
}

static void TestTopProcessesEnergy(void) {
    Section(@"TMTopProcesses — dimension énergie (ri_energy_nj)");
    // Sans donnée d'énergie, la dimension n'entre pas dans l'union (tri sur des zéros = arbitraire).
    NSDictionary *prevNoE = @{ @"10": TMProc(@"a", 1000000000, 100), @"20": TMProc(@"b", 100000000, 900) };
    NSDictionary *curNoE  = @{ @"10": TMProc(@"a", 3000000000, 100), @"20": TMProc(@"b", 100000000, 900) };
    Check(TMTopProcesses(prevNoE, curNoE, 1.0, 1).count == 2, @"sans énergie : union = CPU ∪ RAM seulement (2)");

    // Avec énergie : un process qui n'est ni top CPU ni top RAM mais brûle de l'énergie entre.
    NSDictionary *prev = @{ @"10": TMProcE(@"cpu_hog", 1000000000, 100, 1000000000),
                            @"20": TMProcE(@"ram_hog", 100000000, 9000, 1000000000),
                            @"30": TMProcE(@"power_hog", 100000000, 100, 1000000000) };
    NSDictionary *cur  = @{ @"10": TMProcE(@"cpu_hog", 3000000000, 100, 1100000000),      // CPU++
                            @"20": TMProcE(@"ram_hog", 100000000, 9000, 1100000000),       // RAM top
                            @"30": TMProcE(@"power_hog", 150000000, 100, 6000000000) };     // +5 J en 1 s = 5 W
    NSArray *top = TMTopProcesses(prev, cur, 1.0, 1);
    NSArray *names = [top valueForKey:@"name"];
    Check(top.count == 3, @"count=1 sur 3 dimensions : union = cpu_hog ∪ ram_hog ∪ power_hog");
    Check([names containsObject:@"power_hog"], @"le plus gros consommateur d'énergie est inclus");
    for (NSDictionary *p in top) if ([p[@"name"] isEqual:@"power_hog"])
        CheckEqual(p[@"energyWatts"], @5.0, @"5 J sur 1 s = 5 W de puissance moyenne");
    for (NSDictionary *p in top) if ([p[@"name"] isEqual:@"cpu_hog"])
        CheckEqual(p[@"energyWatts"], @0.1, @"0,1 J sur 1 s = 0,1 W");
}

static void TestThresholdFire(void) {
    Section(@"TMThresholdShouldFire — hystérésis");
    BOOL above = NO;
    Check(!TMThresholdShouldFire(&above, 70, 90, 85), @"sous le seuil : silence");
    Check(TMThresholdShouldFire(&above, 92, 90, 85), @"franchissement montant : alerte");
    Check(!TMThresholdShouldFire(&above, 95, 90, 85), @"toujours au-dessus : une seule alerte, pas une rafale");
    Check(!TMThresholdShouldFire(&above, 88, 90, 85), @"redescend mais au-dessus du réarmement : silence armé");
    Check(TMThresholdShouldFire(&above, 91, 90, 85) == NO && above, @"remonte sans être réarmé : toujours silencieux");
    TMThresholdShouldFire(&above, 80, 90, 85);
    Check(!above, @"sous le réarmement : désarmé");
    Check(TMThresholdShouldFire(&above, 93, 90, 85), @"nouveau franchissement après réarmement : nouvelle alerte");
    BOOL exact = NO;
    Check(TMThresholdShouldFire(&exact, 90, 90, 85), @"la valeur exacte du seuil compte comme franchie");
}

// Fumée sur les collecteurs réels — même esprit que TestAwake : on interroge la vraie machine,
// pas un mock. On ne vérifie que le contrat (familles plausibles, JSON valide), pas les valeurs.
static void TestSystemMonitorLive(void) {
    Section(@"TMSystemMonitorCreate — collecteurs réels (fumée)");
    TMSystemMonitor *monitor = TMSystemMonitorCreate();
    Check(monitor != nil, @"le moniteur de production se crée");
    [monitor sample];
    usleep(200000);  // les deltas (CPU, réseau, disque) ont besoin de deux points espacés
    [monitor sample];
    NSDictionary *snapshot = [monitor snapshot];
    NSArray *families = snapshot[@"families"];
    NSArray *ids = [families valueForKey:@"id"];
    Check([ids containsObject:@"cpu"], @"le CPU répond après deux échantillons");
    Check([ids containsObject:@"ram"], @"la RAM répond");
    Check([ids containsObject:@"disk"], @"le disque répond");
    Check([NSJSONSerialization isValidJSONObject:snapshot], @"snapshot réel sérialisable");
    printf("  familles présentes : %s\n", [[ids componentsJoinedByString:@", "] UTF8String]);

    NSDictionary *(^familyNow)(NSString *) = ^NSDictionary *(NSString *fid) {
        for (NSDictionary *f in families) if ([f[@"id"] isEqual:fid]) return f[@"now"];
        return nil;
    };

    // coreTypes : sur Apple Silicon, chaîne E/P de longueur = nombre de cœurs. Omis sur une
    // machine sans distinction P/E — on ne teste alors que sa cohérence si présent.
    NSDictionary *cpuNow = familyNow(@"cpu");
    NSString *coreTypes = cpuNow[@"coreTypes"];
    if (coreTypes) {
        int logicalCPU = 0; size_t sz = sizeof(logicalCPU);
        sysctlbyname("hw.logicalcpu", &logicalCPU, &sz, NULL, 0);
        // coreTypes couvre tous les cœurs physiques ; le nombre de clés « coreN » d'un tick donné
        // peut être inférieur (un cœur E sans aucun tick sur l'intervalle n'a pas de delta).
        NSUInteger coreKeys = 0;
        for (NSString *k in cpuNow) if ([k hasPrefix:@"core"] && ![k isEqual:@"coreTypes"]) coreKeys++;
        Check((int)coreTypes.length == logicalCPU, @"coreTypes : un caractère par cœur physique");
        Check(coreTypes.length >= coreKeys, @"coreTypes couvre au moins les cœurs mesurés ce tick");
        Check([[coreTypes stringByTrimmingCharactersInSet:[NSCharacterSet characterSetWithCharactersInString:@"EP"]] length] == 0,
              @"coreTypes : uniquement des E et des P");
        printf("  cœurs : %s\n", coreTypes.UTF8String);
    }

    // GPU : au minimum `usage` ; renderer/tiler/memInUse selon la machine.
    NSDictionary *gpuNow = familyNow(@"gpu");
    if (gpuNow) {
        Check(gpuNow[@"usage"] != nil, @"GPU : Device Utilization présent");
        printf("  gpu : usage=%s renderer=%s tiler=%s\n",
               [gpuNow[@"usage"] description].UTF8String,
               [gpuNow[@"renderer"] ?: @"—" description].UTF8String,
               [gpuNow[@"tiler"] ?: @"—" description].UTF8String);
    }

    // Batterie : présente sur un portable, absente sur un Mac de bureau (famille nil).
    NSDictionary *batt = familyNow(@"battery");
    if (batt) {
        Check(batt[@"percent"] != nil, @"batterie : pourcentage présent");
        NSNumber *pct = batt[@"percent"];
        Check(pct.doubleValue >= 0 && pct.doubleValue <= 100, @"batterie : pourcentage dans [0,100]");
        printf("  batterie : %s%% cycles=%s santé=%s%% cond=%s %sW\n",
               pct.description.UTF8String,
               [batt[@"cycleCount"] ?: @"—" description].UTF8String,
               [batt[@"healthPercent"] ?: @"—" description].UTF8String,
               [batt[@"conditionOK"] boolValue] ? "OK" : "!",
               [batt[@"powerWatts"] ?: @"—" description].UTF8String);
    } else {
        printf("  batterie : absente (Mac de bureau ?)\n");
    }

    // Capteurs : thermalState toujours présent (0-3) ; ventilateurs selon la machine.
    NSDictionary *sensorsNow = familyNow(@"sensors");
    if (sensorsNow) {
        NSNumber *thermal = sensorsNow[@"thermalState"];
        Check(thermal != nil && thermal.intValue >= 0 && thermal.intValue <= 3, @"état thermique dans [0,3]");
        NSMutableArray *fans = [NSMutableArray array];
        for (NSString *k in sensorsNow) if ([k hasPrefix:@"fan"]) [fans addObject:sensorsNow[k]];
        printf("  thermique : état=%s temp=%s ventilateurs=%s\n",
               thermal.description.UTF8String,
               [sensorsNow[@"tempC"] ?: @"—" description].UTF8String,
               fans.count ? [[fans componentsJoinedByString:@"/"] UTF8String] : "aucun");
    }
}

#pragma mark - Écrans (luminosité)

static void TestDisplayBrightnessClamp(void) {
    Section(@"TMClampBrightnessPercent / TMSteppedBrightness — bornes");
    CheckEqual(@(TMClampBrightnessPercent(150)), @100.0, @"au-dessus de 100 -> 100");
    CheckEqual(@(TMClampBrightnessPercent(-10)), @0.0, @"sous 0 -> 0");
    CheckEqual(@(TMClampBrightnessPercent(NAN)), @0.0, @"NaN -> 0, jamais propagé au JSON");
    CheckEqual(@(TMClampBrightnessPercent(42)), @42.0, @"valeur normale inchangée");
    CheckEqual(@(TMSteppedBrightness(50, YES, 6)), @56.0, @"un cran vers le haut");
    CheckEqual(@(TMSteppedBrightness(50, NO, 6)), @44.0, @"un cran vers le bas");
    CheckEqual(@(TMSteppedBrightness(98, YES, 6)), @100.0, @"un cran vers le haut borné à 100");
    CheckEqual(@(TMSteppedBrightness(2, NO, 6)), @0.0, @"un cran vers le bas borné à 0");
}

static void TestDisplayVCPConversion(void) {
    Section(@"TMPercentFromVCPValue / TMVCPValueFromPercent — échelle propre au moniteur");
    CheckEqual(@(TMPercentFromVCPValue(50, 100)), @50, @"échelle 0-100 : valeur directe");
    CheckEqual(@(TMPercentFromVCPValue(32, 64)), @50, @"échelle 0-64 : moitié -> 50 %");
    CheckEqual(@(TMPercentFromVCPValue(10, 0)), @0, @"maximum nul (VCP mal formé) -> 0, pas de division par zéro");
    CheckEqual(@(TMVCPValueFromPercent(50, 64)), @32, @"50 % reconverti vers l'échelle 0-64");
    CheckEqual(@(TMVCPValueFromPercent(100, 64)), @64, @"100 % -> le maximum exact");
    CheckEqual(@(TMVCPValueFromPercent(0, 64)), @0, @"0 % -> 0");
    CheckEqual(@(TMVCPValueFromPercent(150, 64)), @64, @"pourcentage hors bornes -> plafonné au maximum");
}

// Le format de trame DDC/CI (VESA MCCS) est un standard public, mais la convention exacte de
// l'octet de checksum d'une réponse varie selon les sources consultées, et aucun moniteur externe
// n'est branché sur la machine de développement pour la vérifier en conditions réelles (voir
// design). Ce test valide donc la cohérence interne construction/lecture — pas la conformité à un
// vrai moniteur, qui reste à vérifier sur matériel réel.
static void TestDisplayDDCProtocol(void) {
    Section(@"TMDDCGetVCPRequest / TMDDCSetVCPRequest / TMDDCParseVCPReply — cohérence du protocole");
    NSData *getRequest = TMDDCGetVCPRequest(TMDDCBrightnessVCPCode);
    CheckEqual(@(getRequest.length), @5, @"requête Get VCP : 5 octets (source, longueur, opcode, code VCP, checksum)");
    const uint8_t *getBytes = getRequest.bytes;
    CheckEqual(@(getBytes[0]), @(0x51), @"octet source = adresse virtuelle hôte 0x51");
    CheckEqual(@(getBytes[2]), @(0x01), @"opcode Get VCP Feature = 0x01");
    CheckEqual(@(getBytes[3]), @(TMDDCBrightnessVCPCode), @"code VCP transmis = luminosité (0x10)");

    NSData *setRequest = TMDDCSetVCPRequest(TMDDCBrightnessVCPCode, 42);
    CheckEqual(@(setRequest.length), @7, @"requête Set VCP : 7 octets (valeur sur 2 octets en plus)");
    const uint8_t *setBytes = setRequest.bytes;
    CheckEqual(@(setBytes[2]), @(0x03), @"opcode Set VCP Feature = 0x03");
    CheckEqual(@(((setBytes[4] << 8) | setBytes[5])), @42, @"valeur reconstruite depuis MSB/LSB");

    // Trame de réponse synthétique, construite avec la même fonction de checksum que le code de
    // production : valide la cohérence du décodage, pas un octet de référence d'un vrai moniteur.
    uint8_t reply[11] = { 0x6E, 0x88, 0x02, 0x00, TMDDCBrightnessVCPCode, 0x00, 0x00, 100, 0x00, 62, 0x00 };
    NSMutableData *replyData = [NSMutableData dataWithBytes:reply length:sizeof(reply) - 1];
    // Checksum calculé à la main (graine 0x50, cf. TMDDCChecksum) pour rester indépendant de
    // l'implémentation testée.
    uint8_t checksum = 0x50;
    for (NSUInteger i = 0; i < replyData.length; i++) checksum ^= ((const uint8_t *)replyData.bytes)[i];
    [replyData appendBytes:&checksum length:1];
    uint16_t current = 0, maximum = 0;
    Check(TMDDCParseVCPReply(replyData, TMDDCBrightnessVCPCode, &current, &maximum), @"trame valide acceptée");
    CheckEqual(@(current), @62, @"valeur courante extraite");
    CheckEqual(@(maximum), @100, @"maximum extrait");

    NSMutableData *corrupted = [replyData mutableCopy];
    ((uint8_t *)corrupted.mutableBytes)[10] ^= 0xFF;
    Check(!TMDDCParseVCPReply(corrupted, TMDDCBrightnessVCPCode, &current, &maximum), @"checksum invalide -> rejetée");

    NSMutableData *wrongVCP = [replyData mutableCopy];
    ((uint8_t *)wrongVCP.mutableBytes)[4] = 0x12;  // code VCP différent, checksum désormais invalide aussi
    Check(!TMDDCParseVCPReply(wrongVCP, TMDDCBrightnessVCPCode, &current, &maximum), @"code VCP inattendu -> rejetée");

    Check(!TMDDCParseVCPReply([NSData data], TMDDCBrightnessVCPCode, &current, &maximum), @"trame vide -> rejetée, pas de crash");
}

// Fumée sur le vrai matériel — même esprit que TestSystemMonitorLive : l'écran interne doit
// répondre sur toute machine de développement. Aucune assertion sur un écran externe, puisque son
// éventuelle présence dépend de la machine qui exécute les tests.
static void TestDisplayManagerLive(void) {
    Section(@"TMDisplayManager — détection réelle (fumée)");
    TMDisplayManager *manager = [TMDisplayManager new];
    [manager rescan];
    Check(manager.displays.count >= 1, @"au moins un écran détecté (l'interne, sur un portable)");
    TMDisplay *builtin = [manager displayWithIdentifier:@"builtin"];
    if (builtin) {
        Check(builtin.kind == TMDisplayKindBuiltin, @"l'écran interne est classé comme tel");
        printf("  écran interne : disponible=%s brightness=%s\n",
               builtin.available ? "oui" : "non",
               builtin.brightnessPercent ? builtin.brightnessPercent.description.UTF8String : "—");
    } else {
        printf("  aucun écran interne détecté (machine de bureau ?)\n");
    }
    NSArray *snapshot = [manager snapshot];
    Check([NSJSONSerialization isValidJSONObject:snapshot], @"snapshot des écrans sérialisable");
}

#pragma mark - Gestionnaire de fenêtres

static BOOL TMRectClose(CGRect a, CGRect b) {
    return fabs(a.origin.x - b.origin.x) < 0.51 && fabs(a.origin.y - b.origin.y) < 0.51
        && fabs(a.size.width - b.size.width) < 0.51 && fabs(a.size.height - b.size.height) < 0.51;
}

static void CheckRect(CGRect actual, CGRect expected, NSString *what) {
    gChecks++;
    if (TMRectClose(actual, expected)) {
        printf("  \033[32m✓\033[0m %s\n", what.UTF8String);
    } else {
        gFailures++;
        printf("  \033[31m✗ %s\033[0m\n     attendu: %s\n     obtenu : %s\n", what.UTF8String,
               NSStringFromRect(expected).UTF8String, NSStringFromRect(actual).UTF8String);
    }
}

static void TestWindowLayoutsNoGaps(void) {
    Section(@"TMWindowFrameForLayout — dispositions sans marge");
    CGRect zone = CGRectMake(0, 0, 1200, 800);
    TMWindowGaps none = { 0, 0 };
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutLeftHalf, none), CGRectMake(0, 0, 600, 800), @"moitié gauche");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutRightHalf, none), CGRectMake(600, 0, 600, 800), @"moitié droite");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutLeftTwoThirds, none), CGRectMake(0, 0, 800, 800), @"2/3 gauche");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutRightTwoThirds, none), CGRectMake(400, 0, 800, 800), @"2/3 droite");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutLeftThird, none), CGRectMake(0, 0, 400, 800), @"tiers gauche");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutCenterThird, none), CGRectMake(400, 0, 400, 800), @"tiers centre");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutRightThird, none), CGRectMake(800, 0, 400, 800), @"tiers droite");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutLeftThreeQuarters, none), CGRectMake(0, 0, 900, 800), @"3/4 gauche");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutRightThreeQuarters, none), CGRectMake(300, 0, 900, 800), @"3/4 droite");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutMaximize, none), zone, @"plein écran occupe toute la zone");
}

static void TestWindowLayoutsOrigin(void) {
    Section(@"TMWindowFrameForLayout — la zone n'est pas toujours à l'origine");
    // Écran secondaire à gauche du principal, et barre des menus retranchée : origine non nulle,
    // y compris négative. Les cadres doivent suivre la zone, pas l'écran.
    CGRect zone = CGRectMake(-1800, 25, 1800, 1100);
    TMWindowGaps none = { 0, 0 };
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutLeftHalf, none), CGRectMake(-1800, 25, 900, 1100), @"origine négative respectée");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutRightHalf, none), CGRectMake(-900, 25, 900, 1100), @"moitié droite décalée de l'origine");
    CheckRect(TMWindowFrameForLayout(zone, TMLayoutMaximize, none), zone, @"plein écran = la zone exacte");
}

static void TestWindowLayoutsAdjacency(void) {
    Section(@"TMWindowFrameForLayout — pas de bande résiduelle entre voisines");
    // Le piège classique : 1/3 + 2/3 ne fait pas 100 % après arrondis, et il reste une bande d'un
    // point. On vérifie que les paires complémentaires se touchent exactement.
    CGRect zone = CGRectMake(0, 0, 1001, 799);  // largeur volontairement indivisible par 3
    TMWindowGaps none = { 0, 0 };
    CGRect tiers = TMWindowFrameForLayout(zone, TMLayoutLeftThird, none);
    CGRect deuxTiers = TMWindowFrameForLayout(zone, TMLayoutRightTwoThirds, none);
    CheckEqual(@(CGRectGetMaxX(tiers)), @(CGRectGetMinX(deuxTiers)), @"1/3 et 2/3 se touchent exactement");
    CheckEqual(@(CGRectGetMaxX(deuxTiers)), @(CGRectGetMaxX(zone)), @"2/3 droite atteint le bord droit");

    CGRect gauche = TMWindowFrameForLayout(zone, TMLayoutLeftHalf, none);
    CGRect droite = TMWindowFrameForLayout(zone, TMLayoutRightHalf, none);
    CheckEqual(@(CGRectGetMaxX(gauche)), @(CGRectGetMinX(droite)), @"les deux moitiés se touchent malgré la largeur impaire");
    CheckEqual(@(CGRectGetMaxX(droite)), @(CGRectGetMaxX(zone)), @"la moitié droite atteint le bord");

    CGRect quart = TMWindowFrameForLayout(zone, TMLayoutLeftThreeQuarters, none);
    CheckEqual(@(CGRectGetMinX(quart)), @(CGRectGetMinX(zone)), @"3/4 gauche part du bord gauche");
}

static void TestWindowLayoutsGaps(void) {
    Section(@"TMWindowFrameForLayout — marges");
    CGRect zone = CGRectMake(0, 0, 1200, 800);
    TMWindowGaps gaps = { 20, 10 };  // 20 entre fenêtres, 10 aux bords

    CGRect gauche = TMWindowFrameForLayout(zone, TMLayoutLeftHalf, gaps);
    CGRect droite = TMWindowFrameForLayout(zone, TMLayoutRightHalf, gaps);
    CheckEqual(@(CGRectGetMinX(gauche)), @10.0, @"marge de bord appliquée à gauche");
    CheckEqual(@(CGRectGetMinY(gauche)), @10.0, @"marge de bord appliquée en bas");
    CheckEqual(@(CGRectGetMaxX(droite)), @1190.0, @"marge de bord appliquée à droite");
    CheckEqual(@(CGRectGetMinX(droite) - CGRectGetMaxX(gauche)), @20.0,
               @"exactement une marge entre les deux, pas deux demi-marges cumulées en double");

    // Le bord d'écran ne reçoit jamais la marge inter-fenêtres en plus de la sienne.
    CGRect plein = TMWindowFrameForLayout(zone, TMLayoutMaximize, gaps);
    CheckRect(plein, CGRectMake(10, 10, 1180, 780), @"plein écran : marge de bord seule, sur les quatre côtés");

    TMWindowGaps sansBord = { 20, 0 };
    CGRect collee = TMWindowFrameForLayout(zone, TMLayoutLeftHalf, sansBord);
    CheckEqual(@(CGRectGetMinX(collee)), @0.0, @"marge de bord nulle : la fenêtre touche le bord");
    CheckEqual(@(CGRectGetMaxX(collee)), @590.0, @"la demi-marge intérieure s'applique quand même");
}

static void TestWindowLayoutCenter(void) {
    Section(@"TMWindowFrameForLayout — centrer");
    CGRect zone = CGRectMake(100, 50, 1000, 600);
    CGRect centre = TMWindowFrameForLayout(zone, TMLayoutCenter, (TMWindowGaps){0, 0});
    CheckEqual(@(CGRectGetMidX(centre)), @(CGRectGetMidX(zone)), @"centré horizontalement");
    CheckEqual(@(CGRectGetMidY(centre)), @(CGRectGetMidY(zone)), @"centré verticalement");
    Check(CGRectGetWidth(centre) < CGRectGetWidth(zone), @"plus étroit que la zone");
    Check(CGRectContainsRect(zone, centre), @"reste entièrement dans la zone");
}

static void TestWindowLayoutIdentifiers(void) {
    Section(@"TMWindowLayoutFromIdentifier — entrée venue de la webview");
    TMWindowLayout layout;
    Check(TMWindowLayoutFromIdentifier(@"left-half", &layout) && layout == TMLayoutLeftHalf, @"left-half");
    Check(TMWindowLayoutFromIdentifier(@"right-two-thirds", &layout) && layout == TMLayoutRightTwoThirds, @"right-two-thirds");
    Check(TMWindowLayoutFromIdentifier(@"center", &layout) && layout == TMLayoutCenter, @"center");
    Check(!TMWindowLayoutFromIdentifier(@"left-halfff", &layout), @"identifiant inconnu : refusé, pas de déplacement au hasard");
    Check(!TMWindowLayoutFromIdentifier(@"", &layout), @"chaîne vide refusée");
    Check(!TMWindowLayoutFromIdentifier(nil, &layout), @"nil refusé");
}

static void TestWindowMoveToScreen(void) {
    Section(@"TMWindowFrameMovedToScreen — proportions conservées");
    CGRect ecranA = CGRectMake(0, 0, 1000, 800);
    CGRect ecranB = CGRectMake(1000, 0, 2000, 1200);  // plus grand, à droite

    CGRect moitieGauche = CGRectMake(0, 0, 500, 800);
    CGRect deplacee = TMWindowFrameMovedToScreen(moitieGauche, ecranA, ecranB);
    CheckRect(deplacee, CGRectMake(1000, 0, 1000, 1200), @"la moitié gauche reste la moitié gauche");

    CGRect quart = CGRectMake(500, 400, 500, 400);
    CheckRect(TMWindowFrameMovedToScreen(quart, ecranA, ecranB), CGRectMake(2000, 600, 1000, 600),
              @"un quart haut-droite reste un quart haut-droite");

    // Une fenêtre plus grande que l'écran d'arrivée doit y tenir, pas déborder.
    CGRect ecranPetit = CGRectMake(0, 0, 400, 300);
    CGRect bornee = TMWindowFrameMovedToScreen(CGRectMake(0, 0, 1000, 800), ecranA, ecranPetit);
    Check(CGRectContainsRect(ecranPetit, bornee), @"bornée à l'écran d'arrivée, jamais hors champ");
}

static void TestDuoLayouts(void) {
    Section(@"TMDuoLayoutsForSplit — les deux moitiés d'un duo");
    CGRect zone = CGRectMake(0, 0, 1001, 799);  // largeur indivisible : le pire cas d'arrondi
    TMWindowGaps none = { 0, 0 };
    struct { TMDuoSplit split; NSString *nom; double partActive; } cas[] = {
        { TMDuoHalf,            @"50/50",  0.5      },
        { TMDuoActiveTwoThirds, @"2/3",    2.0 / 3  },
        { TMDuoActiveThird,     @"1/3",    1.0 / 3  },
    };
    for (int i = 0; i < 3; i++) {
        TMWindowLayout active, partner;
        TMDuoLayoutsForSplit(cas[i].split, &active, &partner);
        CGRect a = TMWindowFrameForLayout(zone, active, none);
        CGRect b = TMWindowFrameForLayout(zone, partner, none);

        CheckEqual(@(CGRectGetMinX(a)), @(CGRectGetMinX(zone)),
                   ([NSString stringWithFormat:@"%@ : l'active part du bord gauche", cas[i].nom]));
        CheckEqual(@(CGRectGetMaxX(a)), @(CGRectGetMinX(b)),
                   ([NSString stringWithFormat:@"%@ : les deux se touchent exactement", cas[i].nom]));
        CheckEqual(@(CGRectGetMaxX(b)), @(CGRectGetMaxX(zone)),
                   ([NSString stringWithFormat:@"%@ : la partenaire atteint le bord droit", cas[i].nom]));
        Check(fabs(CGRectGetWidth(a) / CGRectGetWidth(zone) - cas[i].partActive) < 0.01,
              ([NSString stringWithFormat:@"%@ : l'active occupe la bonne part", cas[i].nom]));
    }

    TMWindowLayout active, partner;
    TMDuoLayoutsForSplit(TMDuoActiveTwoThirds, &active, &partner);
    Check(active != partner, @"les deux dispositions d'un duo sont distinctes");
}

static void TestDuoIdentifiers(void) {
    Section(@"TMDuoSplitFromIdentifier — entrée venue de la webview");
    TMDuoSplit split;
    Check(TMDuoSplitFromIdentifier(@"duo-half", &split) && split == TMDuoHalf, @"duo-half");
    Check(TMDuoSplitFromIdentifier(@"duo-two-thirds", &split) && split == TMDuoActiveTwoThirds, @"duo-two-thirds");
    Check(TMDuoSplitFromIdentifier(@"duo-third", &split) && split == TMDuoActiveThird, @"duo-third");
    Check(!TMDuoSplitFromIdentifier(@"duo-quart", &split), @"partage inconnu refusé");
    Check(!TMDuoSplitFromIdentifier(nil, &split), @"nil refusé");
}

static void TestStaleAlert(void) {
    Section(@"TMStaleAlertShouldFire — une alerte par épisode de péremption");
    BOOL was = NO;
    Check(!TMStaleAlertShouldFire(&was, NO), @"source fraîche : rien");
    Check(TMStaleAlertShouldFire(&was, YES), @"passe périmée : alerte");
    Check(!TMStaleAlertShouldFire(&was, YES), @"toujours périmée : pas de rafale");
    Check(!TMStaleAlertShouldFire(&was, NO), @"redevient fraîche : rien, mais réarme");
    Check(TMStaleAlertShouldFire(&was, YES), @"nouvelle péremption : réalerte");
}

static void TestWatchdog(void) {
    Section(@"TMWatchdogShouldReload — rechargement après N échecs");
    NSInteger fails = 0;
    Check(!TMWatchdogShouldReload(&fails, NO, 3), @"1er échec : patiente");
    Check(!TMWatchdogShouldReload(&fails, NO, 3), @"2e échec : patiente");
    Check(TMWatchdogShouldReload(&fails, NO, 3), @"3e échec : recharge");
    Check(!TMWatchdogShouldReload(&fails, NO, 3), @"réarmé : le 4e échec repart de zéro");
    Check(!TMWatchdogShouldReload(&fails, NO, 3), @"5e (2e depuis réarmement) : patiente");
    Check(!TMWatchdogShouldReload(&fails, YES, 3), @"un succès remet le compteur à zéro");
    Check(!TMWatchdogShouldReload(&fails, NO, 3), @"après succès : on repart bien de 1");
}

static void TestHistoryCSV(void) {
    Section(@"TMHistoryToCSV — export format long");
    NSArray *history = @[
        @{ @"t": @1700000000, @"p": @{ @"claude:seven_day": @44, @"openai:codex-10080": @30 } },
        @{ @"t": @1700000300, @"p": @{ @"claude:seven_day": @45 } },
    ];
    NSString *csv = TMHistoryToCSV(history);
    NSArray<NSString *> *lines = [csv componentsSeparatedByString:@"\n"];
    CheckEqual(lines.firstObject, @"timestamp_unix,date_iso_utc,fenetre,pourcent", @"en-tête présent");
    Check([csv containsString:@"1700000000,"], @"le timestamp brut est écrit");
    Check([csv containsString:@"2023-11-14T"], @"la date ISO est dérivée du timestamp");
    Check([csv containsString:@",claude:seven_day,44"], @"une ligne par fenêtre");
    Check([csv containsString:@",openai:codex-10080,30"], @"OpenAI exporté aussi");
    Check([csv containsString:@",claude:seven_day,45"], @"le second instant est présent");
    // 1 en-tête + 2 fenêtres au 1er instant + 1 au 2e = 4 lignes (hors ligne vide finale)
    NSInteger nonEmpty = 0; for (NSString *l in lines) if (l.length) nonEmpty++;
    CheckEqual(@(nonEmpty), @4, @"une ligne d'en-tête et trois lignes de données");

    Check([TMHistoryToCSV(@[]) hasPrefix:@"timestamp_unix"], @"historique vide : en-tête seul, pas de crash");
}

static void TestCostCacheSemantics(void) {
    Section(@"TMCostForTokens — les deux sémantiques de cache (LE test)");
    // Claude : compartiments DISJOINTS. input hors cache + cache_read + cache_write 5m + cache_write 1h.
    // L'écriture 1 h se facture 2× l'input (10 pour opus) ; la 5 min 1,25× (6,25). Vérifié sur la
    // page de prix officielle Anthropic (2026).
    TMPrices opus = { .input = 5.0, .output = 25.0, .cacheRead = 0.5, .cacheWrite = 6.25, .cacheWrite1h = 10.0 };
    TMTokens claude = { .input = 1000, .output = 200, .cacheRead = 9000, .cacheWrite = 500, .cacheWrite1h = 300 };
    double c = TMCostForTokens(claude, opus, TMCostProviderClaude);
    // (1000*5 + 200*25 + 9000*0.5 + 500*6.25 + 300*10) / 1e6 = 20625 / 1e6
    Check(fabs(c - 0.020625) < 1e-9, @"Claude : quatre compartiments disjoints, cache 1 h à 2×");

    // Le cache 1 h coûte plus cher que le 5 min à volume égal.
    TMTokens seul5m = { .cacheWrite = 1000 }, seul1h = { .cacheWrite1h = 1000 };
    Check(TMCostForTokens(seul1h, opus, TMCostProviderClaude) > TMCostForTokens(seul5m, opus, TMCostProviderClaude),
          @"1 000 tokens d'écriture 1 h coûtent plus que 1 000 en 5 min");

    // OpenAI : input INCLUT le cache. On facture (input - cached) au plein tarif, cached au rabais.
    TMPrices gpt = { .input = 5.0, .output = 30.0, .cacheRead = 0.5, .cacheWrite = 6.25 };
    TMTokens openai = { .input = 10000, .output = 200, .cacheRead = 9000, .cacheWrite = 0 };
    double o = TMCostForTokens(openai, gpt, TMCostProviderOpenAI);
    // ((10000-9000)*5 + 9000*0.5 + 200*30) / 1e6 = 15500 / 1e6
    Check(fabs(o - 0.0155) < 1e-9, @"OpenAI : (input − cache) au plein tarif, cache au rabais");

    // Le piège : traiter l'input OpenAI comme disjoint surcompterait massivement.
    double faux = TMCostForTokens(openai, gpt, TMCostProviderClaude);  // sémantique Claude sur des tokens OpenAI
    Check(faux > o * 3, @"la mauvaise sémantique surcompterait d'un facteur ~4 — d'où l'importance du test");

    TMTokens vide = {0};
    Check(TMCostForTokens(vide, opus, TMCostProviderClaude) == 0, @"aucun token : coût nul");
}

static void TestPriceTable(void) {
    Section(@"TMPricesForModel — table datée, jamais de prix fabriqué");
    TMPrices p;
    Check(TMPricesForModel(@"claude-opus-4-8", &p) && p.output == 25.0, @"opus 4.8 connu");
    // Le tarif d'écriture cache 1 h vaut le double de l'input (règle Anthropic vérifiée).
    Check(TMPricesForModel(@"claude-opus-4-8", &p) && p.cacheWrite1h == 10.0 && p.cacheWrite == 6.25,
          @"opus : cache 1 h à 2× input (10), 5 min à 1,25× (6,25)");
    Check(TMPricesForModel(@"claude-fable-5", &p) && p.input == 10.0 && p.cacheWrite1h == 20.0, @"fable 5 : input 10, cache 1 h 20");
    Check(TMPricesForModel(@"claude-haiku-4-5", &p) && p.cacheWrite1h == 2.0, @"haiku : cache 1 h 2");
    Check(!TMPricesForModel(@"gpt-5.4", &p), @"modèle sans tarif : refusé, pas de prix inventé");
    Check(!TMPricesForModel(@"", &p), @"chaîne vide refusée");
    Check(!TMPricesForModel(nil, &p), @"nil refusé");
}

static void TestParseClaudeLine(void) {
    Section(@"TMParseClaudeUsageLine — forme réelle, cache 5m/1h séparés");
    // Forme récente : cache_creation détaille ephemeral_5m / ephemeral_1h. Les écritures 1 h
    // dominent l'usage réel (≈70 %) et coûtent 2×, d'où l'importance de les distinguer.
    NSDictionary *line = @{ @"message": @{ @"model": @"claude-fable-5", @"usage": @{
        @"input_tokens": @20368, @"cache_creation_input_tokens": @6654,
        @"cache_read_input_tokens": @23786, @"output_tokens": @1179,
        @"cache_creation": @{ @"ephemeral_5m_input_tokens": @654, @"ephemeral_1h_input_tokens": @6000 } } } };
    TMTokens t; NSString *model = nil;
    Check(TMParseClaudeUsageLine(line, &t, &model), @"ligne chiffrable reconnue");
    Check(t.input == 20368 && t.output == 1179, @"input hors cache et output");
    Check(t.cacheRead == 23786, @"cache read");
    Check(t.cacheWrite == 654 && t.cacheWrite1h == 6000, @"écritures 5 min et 1 h séparées");
    CheckEqual(model, @"claude-fable-5", @"modèle extrait");

    // Forme ancienne, sans détail ephemeral : tout le cache_creation compte comme du 5 min (prudent).
    NSDictionary *old = @{ @"message": @{ @"model": @"claude-opus-4-8", @"usage": @{
        @"input_tokens": @10, @"cache_creation_input_tokens": @500, @"cache_read_input_tokens": @0, @"output_tokens": @5 } } };
    Check(TMParseClaudeUsageLine(old, &t, &model) && t.cacheWrite == 500 && t.cacheWrite1h == 0,
          @"sans détail ephemeral : cache_creation entier en 5 min, 1 h à zéro");
    Check(!TMParseClaudeUsageLine(@{@"type": @"summary"}, &t, &model), @"ligne sans usage : ignorée");
}

static void TestParseCodex(void) {
    Section(@"TMParseCodexTokenCount — output inclut DÉJÀ le reasoning");
    // Vérifié sur logs réels : input_tokens + output_tokens == total_tokens, donc reasoning_output
    // est un sous-ensemble d'output_tokens. L'ajouter le compterait deux fois (sur-facturation).
    NSDictionary *info = @{ @"total_token_usage": @{
        @"input_tokens": @22018, @"cached_input_tokens": @9984, @"cache_write_input_tokens": @0,
        @"output_tokens": @128, @"reasoning_output_tokens": @47, @"total_tokens": @22146 } };
    TMTokens t; NSString *model = nil;
    Check(TMParseCodexTokenCount(info, &t, &model), @"token_count chiffrable reconnu");
    Check(t.input == 22018, @"input total (cache inclus)");
    Check(t.cacheRead == 9984, @"cached_input en sous-ensemble");
    Check(t.output == 128, @"output tel quel : le reasoning y est déjà inclus, pas réadditionné");
    Check(t.input + t.output == 22146, @"input + output == total_tokens, cohérent avec les logs");
    Check(!TMParseCodexTokenCount(@{}, &t, &model), @"info sans total_token_usage : ignoré");
}

// Format des tranches : heure → modèle → {cost?, tokens}. Un modèle sans clé "cost" est non tarifé.
static NSDictionary *SampleBuckets(void) {
    return @{
        @"1000000": @{ @"claude-opus-4-8": @{ @"cost": @1.5, @"tokens": @1000 } },
        @"1003600": @{ @"claude-opus-4-8": @{ @"cost": @2.0, @"tokens": @2000 } },
        @"1007200": @{ @"claude-fable-5":  @{ @"cost": @0.5, @"tokens": @300 },
                       @"modele-inconnu":  @{ @"tokens": @999 } } };  // non tarifé : pas de "cost"
}

static void TestCostSince(void) {
    Section(@"TMCostSince — somme des tranches depuis une fenêtre (nid heure→modèle)");
    NSDictionary *buckets = SampleBuckets();
    Check(fabs(TMCostSince(buckets, 1003600) - 2.5) < 1e-9, @"depuis la 2e tranche : 2.0 + 0.5");
    Check(fabs(TMCostSince(buckets, 0) - 4.0) < 1e-9, @"depuis le début : tout (les non tarifés ne comptent pas)");
    Check(TMCostSince(buckets, 9999999) == 0, @"après la dernière tranche : rien");
    Check(TMCostSince(@{}, 0) == 0, @"vide : zéro");
}

static void TestModelBreakdown(void) {
    Section(@"TMModelBreakdownSince — ventilation par modèle, triée");
    NSDictionary *buckets = SampleBuckets();
    NSArray<NSDictionary *> *all = TMModelBreakdownSince(buckets, 0);
    Check(all.count == 3, @"trois modèles distincts sur la fenêtre complète");
    // Tri par coût décroissant ; le non tarifé (sans coût) en dernier.
    CheckEqual(all[0][@"model"], @"claude-opus-4-8", @"opus en tête (coût le plus élevé)");
    Check(fabs([all[0][@"cost"] doubleValue] - 3.5) < 1e-9, @"coût opus cumulé sur les deux heures");
    Check([all[0][@"tokens"] doubleValue] == 3000, @"tokens opus cumulés");
    CheckEqual(all[1][@"model"], @"claude-fable-5", @"fable ensuite");
    CheckEqual(all[2][@"model"], @"modele-inconnu", @"le non tarifé en dernier");
    Check(all[2][@"cost"] == nil, @"non tarifé : pas de clé cost");
    Check([all[2][@"tokens"] doubleValue] == 999, @"non tarifé : ses tokens sont conservés");

    NSArray<NSDictionary *> *lastHour = TMModelBreakdownSince(buckets, 1007200);
    Check(lastHour.count == 2, @"fenêtre réduite à la dernière heure : fable + inconnu");
    CheckEqual(lastHour[0][@"model"], @"claude-fable-5", @"opus exclu par la fenêtre");
    Check(TMModelBreakdownSince(@{}, 0).count == 0, @"vide : liste vide");
}

static void TestFxRefresh(void) {
    Section(@"TMFxShouldRefresh / TMParseFxResponse — change auto");
    Check(TMFxShouldRefresh(0, 1000000, 72000), @"jamais récupéré : rafraîchir");
    Check(!TMFxShouldRefresh(990000, 1000000, 72000), @"récupéré il y a 10 000 s (< ttl) : garder");
    Check(TMFxShouldRefresh(900000, 1000000, 72000), @"récupéré il y a 100 000 s (> ttl) : rafraîchir");

    double rate = 0; NSString *asOf = nil;
    NSDictionary *ok = @{ @"amount": @1, @"base": @"USD", @"date": @"2026-07-20", @"rates": @{ @"EUR": @0.918 } };
    Check(TMParseFxResponse(ok, &rate, &asOf) && fabs(rate - 0.918) < 1e-9, @"réponse valide : taux extrait");
    CheckEqual(asOf, @"2026-07-20", @"date du relevé extraite");
    Check(!TMParseFxResponse(@{ @"rates": @{ @"GBP": @0.79 } }, &rate, &asOf), @"EUR absent : rejeté");
    Check(!TMParseFxResponse(@{ @"rates": @{ @"EUR": @0 } }, &rate, &asOf), @"taux nul : rejeté");
    Check(!TMParseFxResponse(@{ @"rates": @{ @"EUR": @-1 } }, &rate, &asOf), @"taux négatif : rejeté");
    Check(!TMParseFxResponse((NSDictionary *)@"pas un dict", &rate, &asOf), @"non-dictionnaire : rejeté");
}

int main(void) {
    @autoreleasepool {
        printf("\n\033[1mStatusQuota — tests\033[0m\n");
        TestCoercion();
        TestISODate();
        TestCookieExtraction();
        TestCookieConversion();
        TestWindowLabels();
        TestSnapshotParsing();
        TestUsagePayloadParsing();
        TestExpiredWindows();
        TestWindowClassification();
        TestHistory();
        TestAccountsCache();
        TestOpenAIWindowIdentity();
        TestOpenAIHistoryCollision();
        TestAwake();
        TestHoldFraction();
        TestLockStateMachine();
        TestMetricRing();
        TestRatePerSecond();
        TestCPUPercent();
        TestSystemMonitorSnapshot();
        TestWindowLayoutsNoGaps();
        TestWindowLayoutsOrigin();
        TestWindowLayoutsAdjacency();
        TestWindowLayoutsGaps();
        TestWindowLayoutCenter();
        TestWindowLayoutIdentifiers();
        TestWindowMoveToScreen();
        TestDuoLayouts();
        TestDuoIdentifiers();
        TestCostSince();
        TestModelBreakdown();
        TestFxRefresh();
        TestCostCacheSemantics();
        TestPriceTable();
        TestParseClaudeLine();
        TestParseCodex();
        TestHistoryCSV();
        TestStaleAlert();
        TestWatchdog();
        TestForecastExhaustion();
        TestTopProcesses();
        TestTopProcessesEnergy();
        TestThresholdFire();
        TestSystemMonitorLive();
        TestDisplayBrightnessClamp();
        TestDisplayVCPConversion();
        TestDisplayDDCProtocol();
        TestDisplayManagerLive();

        printf("\n%s%d vérifications, %d échec(s)\033[0m\n\n",
               gFailures ? "\033[31m" : "\033[32m", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
