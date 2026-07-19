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
#import <IOKit/pwr_mgt/IOPMLib.h>

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

static NSDictionary *TMProc(NSString *name, uint64_t cpuNs, uint64_t rss) {
    return @{ @"name": name, @"cpuTimeNs": @(cpuNs), @"rssBytes": @(rss) };
}

static void TestTopProcesses(void) {
    Section(@"TMTopProcesses — deltas de temps CPU par processus");
    NSDictionary *previous = @{ @"10": TMProc(@"chrome", 1000000000, 500), @"20": TMProc(@"node", 500000000, 300),
                                @"30": TMProc(@"idle_app", 100000000, 100) };
    NSDictionary *current  = @{ @"10": TMProc(@"chrome", 2000000000, 520), @"20": TMProc(@"node", 1750000000, 310),
                                @"30": TMProc(@"idle_app", 100000000, 100) };
    NSArray *top = TMTopProcesses(previous, current, 2.0, 5);
    Check(top.count == 3, @"trois processus mesurés");
    CheckEqual(top.firstObject[@"name"], @"node", @"trié par consommation : node (62,5 %) devant chrome (50 %)");
    CheckEqual(top.firstObject[@"cpuPercent"], @62.5, @"1,25 s de CPU sur 2 s = 62,5 %");
    CheckEqual([top.lastObject objectForKey:@"cpuPercent"], @0.0, @"processus immobile : 0 %, présent");
    CheckEqual(top.firstObject[@"rssBytes"], @310, @"la RSS vient du relevé courant");
    CheckEqual(top.firstObject[@"pid"], @"20", @"le pid accompagne chaque entrée");

    Check(TMTopProcesses(previous, current, 2.0, 2).count == 2, @"count tronque après tri");
    Check(TMTopProcesses(previous, current, 0, 5).count == 0, @"intervalle nul : rien, pas de division");

    NSDictionary *reborn = @{ @"10": TMProc(@"chrome", 2000000000, 520), @"40": TMProc(@"nouveau", 900000000, 50) };
    NSArray *rebornTop = TMTopProcesses(previous, reborn, 2.0, 5);
    CheckEqual([rebornTop valueForKey:@"name"], @[@"chrome"], @"pid apparu depuis le dernier relevé : pas de delta, absent");
    NSDictionary *reused = @{ @"10": TMProc(@"autre_app", 100, 60) };
    Check(TMTopProcesses(previous, reused, 2.0, 5).count == 0, @"temps CPU qui recule (pid réutilisé) : écarté");

    NSDictionary *burst = @{ @"10": TMProc(@"video_export", 7000000000, 800) };
    NSArray *burstTop = TMTopProcesses(previous, burst, 2.0, 5);
    CheckEqual(burstTop.firstObject[@"cpuPercent"], @300.0, @"multithread : 300 % légitime, non plafonné");
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
        TestOpenAIWindowIdentity();
        TestOpenAIHistoryCollision();
        TestAwake();
        TestHoldFraction();
        TestLockStateMachine();
        TestMetricRing();
        TestRatePerSecond();
        TestCPUPercent();
        TestSystemMonitorSnapshot();
        TestTopProcesses();
        TestThresholdFire();
        TestSystemMonitorLive();

        printf("\n%s%d vérifications, %d échec(s)\033[0m\n\n",
               gFailures ? "\033[31m" : "\033[32m", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
