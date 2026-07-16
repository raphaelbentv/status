// Tests de StatusQuota — la logique pure de Status.
//
//   ./scripts/run-tests.sh
//
// Ce qui est couvert ici est ce qui a réellement cassé en production : formats d'API non
// documentés, fenêtres expirées affichées comme courantes, et collages de cookie hétérogènes.
// Volontairement sans framework : un binaire, zéro dépendance, sortie lisible.

#import <Foundation/Foundation.h>
#import "StatusQuota.h"

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

        printf("\n%s%d vérifications, %d échec(s)\033[0m\n\n",
               gFailures ? "\033[31m" : "\033[32m", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
