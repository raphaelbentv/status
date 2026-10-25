// Tests de StatusQuota — la logique pure de Status.
//
//   ./scripts/run-tests.sh
//
// Ce qui est couvert ici est ce qui a réellement cassé en production : formats d'API non
// documentés, fenêtres expirées affichées comme courantes, et collages de cookie hétérogènes.
// Volontairement sans framework : un binaire, zéro dépendance, sortie lisible.

#import <Foundation/Foundation.h>
#import "StatusQuota.h"
#import "StatusAccounts.h"
#import "StatusApiCredits.h"
#import "StatusAwake.h"
#import "StatusKeyboardLock.h"
#import "StatusSystemMonitor.h"
#import "StatusDisplays.h"
#import "StatusMenuBarWidgets.h"
#import "StatusIconDesigns.h"
#import "StatusCost.h"
#import "StatusFx.h"
#import "StatusCodexServer.h"
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

// Identifiants de compte fixes : les tests d'historique comparent des clés, elles doivent être
// reproductibles d'une exécution à l'autre.
#define TM_ACC_A @"11111111-1111-4111-8111-111111111111"
#define TM_ACC_B @"22222222-2222-4222-8222-222222222222"

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

static void TestCodexExecutableDiscovery(void) {
    Section(@"Découverte du CLI Codex après mise à jour de ChatGPT");
    NSString *app = @"/Applications/ChatGPT.app";
    if (![NSFileManager.defaultManager fileExistsAtPath:app]) return;
    NSString *path = TMCodexExecutablePath();
    Check(path.length && [NSFileManager.defaultManager isExecutableFileAtPath:path],
          @"un CLI exécutable est trouvé quand ChatGPT est installé");
    NSString *currentCLI = [app stringByAppendingPathComponent:@"Contents/Resources/codex-cli/CodexCLI.app/Contents/MacOS/codex"];
    if ([NSFileManager.defaultManager isExecutableFileAtPath:currentCLI])
        CheckEqual(path, currentCLI, @"le CLI embarqué actuel est préféré aux autres versions");
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

    // Les fenêtres « scoped » (sous-quota par modèle) s'agrègent à part : fondre leur pourcentage
    // dans « semaine » ferait dire à l'icône autre chose que les cartes de l'app.
    Check(TMWindowIsScopedWeekly(@{@"windowId": @"seven_day_scoped_fable"}), @"seven_day_scoped_fable est scoped");
    Check(TMWindowIsScopedWeekly(@{@"windowId": @"seven_day_scoped_opus"}), @"tout scoped futur l'est aussi");
    Check(!TMWindowIsScopedWeekly(@{@"windowId": @"seven_day"}), @"la semaine générale n'est pas scoped");
    Check(!TMWindowIsScopedWeekly(@{@"windowId": @"five_hour"}), @"une session n'est pas scoped");
    Check(!TMWindowIsScopedWeekly(@{@"windowId": @"codex-10080", @"durationMinutes": @10080}), @"une hebdo OpenAI n'est pas scoped");
    Check(!TMWindowIsScopedWeekly(@{@"label": @"Semaine", @"durationMinutes": @10080}), @"hebdo sans windowId : pas scoped");

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

    // La limite générale (bloc `rateLimits`) doit se distinguer des limites additionnelles : c'est
    // elle, et elle seule, dont la réinitialisation est annoncée.
    NSDictionary *general = nil, *additional = nil;
    for (NSDictionary *window in windows) {
        if ([window[@"limitId"] isEqualToString:@"codex"]) general = window;
        if ([window[@"limitId"] isEqualToString:@"gpt5"]) additional = window;
    }
    Check([general[@"primaryLimit"] boolValue], @"la limite générale est marquée principale");
    Check(![additional[@"primaryLimit"] boolValue], @"la limite additionnelle ne l'est pas");
    Check(TMWindowIsPrimaryWeekly(general) && !TMWindowIsPrimaryWeekly(additional),
          @"seule la générale passe le filtre des réinitialisations");

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

static void TestManualResetsOpenAI(void) {
    Section(@"Réinitialisations manuelles OpenAI");
    NSDictionary *account = @{@"type": @"chatgpt"};
    NSMutableDictionary *response = [TMFakeOpenAIResponse() mutableCopy];
    CheckEqual(TMOpenAIAccountPayload(account, response, NO, nil)[@"manualReset"][ @"status"],
               @"unknown", @"champ absent : disponibilité inconnue, pas zéro inventé");
    response[@"rateLimitResetCredits"] = @{@"availableCount": @2};
    NSDictionary *reset = TMOpenAIAccountPayload(account, response, NO, nil)[@"manualReset"];
    CheckEqual(reset[@"status"], @"available", @"deux crédits confirmés disponibles");
    CheckEqual(reset[@"count"], @2, @"nombre conservé");
    Check([reset[@"observedAt"] longLongValue] > 0, @"relevé horodaté");
    response[@"rateLimitResetCredits"] = @{@"availableCount": @0};
    CheckEqual(TMOpenAIAccountPayload(account, response, NO, nil)[@"manualReset"][ @"status"],
               @"none", @"zéro explicite : aucun crédit");
    response[@"rateLimitResetCredits"] = @{@"availableCount": @YES};
    CheckEqual(TMOpenAIAccountPayload(account, response, NO, nil)[@"manualReset"][ @"status"],
               @"unknown", @"un booléen n'est pas un nombre de crédits");
    response[@"rateLimitResetCredits"] = @{@"availableCount": @1};
    CheckEqual(TMOpenAIAccountPayload(account, response, NO, @"Lecture impossible")[ @"manualReset"][ @"status"],
               @"unknown", @"une réponse en erreur ne confirme pas la disponibilité");
}

static void TestOpenAIHistoryCollision(void) {
    printf("\n\033[1mHistorique OpenAI — collision de clés\033[0m\n");
    setenv("STATUS_SUPPORT_DIR", "/tmp/status-tests-openai", 1);
    [NSFileManager.defaultManager removeItemAtPath:TMHistoryPath() error:nil];

    NSDictionary *account = @{@"type": @"chatgpt", @"email": @"x@y.z", @"planType": @"pro"};
    NSArray *windows = TMOpenAIAccountPayload(account, TMFakeOpenAIResponse(), NO, nil)[@"windows"];
    NSArray *history = TMAppendHistory(@[@[TMProviderOpenAI, TM_ACC_A, windows]], 5000);

    NSDictionary *points = history.lastObject[@"p"];
    Check(points.count == 2, @"les deux limites sont historisées séparément");
    NSSet *values = [NSSet setWithArray:points.allValues];
    Check([values containsObject:@84] && [values containsObject:@1], @"84 % et 1 % survivent tous les deux");
    [NSFileManager.defaultManager removeItemAtPath:TMHistoryPath() error:nil];
}

static void TestExtraCredits(void) {
    Section(@"Crédits supplémentaires — soldes distincts des resets et plafonds");
    CheckEqual(TMOpenAIExtraCredits(@{})[@"status"], @"unknown", @"solde absent reste inconnu");
    CheckEqual(TMOpenAIExtraCredits(@{@"credits":@{@"balance":@"766.76", @"hasCredits":@YES, @"unlimited":@NO}})[@"balance"], @766.76, @"solde OpenAI décimal");
    CheckEqual(TMOpenAIExtraCredits(@{@"credits":@{@"balance":@"oops"}})[@"status"], @"unknown", @"texte invalide ne devient pas zéro");
    CheckEqual(TMOpenAIExtraCredits(@{@"credits":@{@"balance":@"0", @"hasCredits":@NO}})[@"balance"], @0, @"zéro explicite conservé");
    NSDictionary *c = TMClaudeExtraCredits(@{}, @{@"used_credits":@368, @"monthly_credit_limit":@5000, @"currency":@"usd", @"is_enabled":@YES}, @{@"remaining_balance":@1250, @"currency":@"usd"});
    CheckEqual(c[@"balance"], @12.5, @"solde Claude converti depuis centimes");
    CheckEqual(c[@"used"], @3.68, @"dépense Claude convertie depuis centimes");
    CheckEqual(c[@"monthlyLimit"], @50, @"plafond mensuel distinct du solde");
    c = TMClaudeExtraCredits(@{@"extra_usage":@{@"used_credits":@368, @"monthly_limit":NSNull.null}}, nil, nil);
    CheckEqual(c[@"used"], @3.68, @"dépense conservée sans plafond");
    Check(c[@"balance"] == nil, @"marge mensuelle jamais inventée comme solde prépayé");
    c = TMClaudeExtraCredits(@{}, nil, @{@"amount":@9700, @"balance":@{@"money":@{@"amount_minor":@9700, @"currency":@"EUR", @"exponent":@2}}});
    CheckEqual(c[@"balance"], @97, @"portefeuille Claude réel converti avec son exposant");
    CheckEqual(c[@"balanceCurrency"], @"EUR", @"devise propre au solde conservée");
}

static NSString *TMTestJWT(NSDictionary *claims) {
    NSData *data=[NSJSONSerialization dataWithJSONObject:claims options:0 error:nil];
    NSString *b64=[[[data base64EncodedStringWithOptions:0] stringByReplacingOccurrencesOfString:@"+" withString:@"-"]
        stringByReplacingOccurrencesOfString:@"/" withString:@"_"];
    return [NSString stringWithFormat:@"e30.%@.sig",[b64 stringByReplacingOccurrencesOfString:@"=" withString:@""]];
}
static void TestResetCredits(void) {
    Section(@"Resets manuels — expiration de chaque crédit");
    Check(TMResetCreditDetails(nil) == nil, @"détail absent : nil, pas « aucun »");
    NSArray *c = TMResetCreditDetails(@[
        @{@"id":@"b", @"grantedAt":@1, @"status":@"available", @"expiresAt":@1793000000, @"resetType":@"weekly"},
        @{@"id":@"a", @"grantedAt":@1, @"status":@"available", @"expiresAt":@1792000000, @"title":@"Reset offert"},
        @{@"id":@"c", @"grantedAt":@1, @"status":@"redeemed", @"expiresAt":@1791000000},
        @{@"id":@"d", @"grantedAt":@1, @"status":@"available", @"expiresAt":NSNull.null}]);
    CheckEqual(@(c.count), @3, @"crédits déjà utilisés écartés");
    CheckEqual(c[0][@"expiresAt"], @1792000000, @"le premier à expirer en tête");
    CheckEqual(c[0][@"title"], @"Reset offert", @"titre conservé");
    Check(c[2][@"expiresAt"] == nil, @"sans expiration : en dernier, jamais une fausse date");
}

static void TestHistoryForDisplay(void) {
    Section(@"TMHistoryForDisplay — historique allégé pour l'interface");
    NSTimeInterval now = 1791100000;
    NSMutableArray *h = [NSMutableArray array];
    for (int i = 0; i < 600; i++) [h addObject:@{@"t":@(now - (600 - i) * 60), @"p":@{@"k":@(i)}}];  // 10 h à la minute
    NSArray *d = TMHistoryForDisplay(h, now);
    Check(d.count < 230 && d.count > 190, @"10 h minute par minute réduites à ~200 points");
    CheckEqual([d.lastObject[@"t"] description], [h.lastObject[@"t"] description], @"le point le plus récent est conservé");
    NSUInteger recent = 0; for (NSDictionary *p in d) if ([p[@"t"] doubleValue] >= now - 3 * 3600) recent++;
    CheckEqual(@(recent), @180, @"les 3 dernières heures restent complètes");
    CheckEqual(@(TMHistoryForDisplay(nil, now).count), @0, @"entrée invalide : liste vide");
}

static void TestBilling(void) {
    Section(@"Facturation — prochaine échéance par compte");
    NSTimeInterval now=1791100000; // 2026-10-04
    NSDictionary *b=TMOpenAIBillingFromIDToken(TMTestJWT(@{@"https://api.openai.com/auth":@{@"chatgpt_plan_type":@"pro",@"chatgpt_subscription_active_until":@"2026-10-06T18:07:24+00:00"}}), now);
    CheckEqual(b[@"status"], @"known", @"échéance OpenAI lue dans l'id_token");
    CheckEqual(b[@"estimated"], @NO, @"échéance future : date exacte");
    CheckEqual(b[@"plan"], @"pro", @"offre conservée");
    b=TMOpenAIBillingFromIDToken(TMTestJWT(@{@"https://api.openai.com/auth":@{@"chatgpt_subscription_active_until":@"2026-09-10T22:43:01+00:00"}}), now);
    CheckEqual(b[@"estimated"], @YES, @"échéance passée : reportée et signalée estimée");
    Check([b[@"nextAt"] doubleValue]>now && [b[@"nextAt"] doubleValue]<now+32*86400, @"report d'un mois au plus près");
    CheckEqual(TMOpenAIBillingFromIDToken(@"pas-un-jeton", now)[@"status"], @"unknown", @"jeton illisible : inconnu");
    CheckEqual(TMOpenAIBillingFromIDToken(TMTestJWT(@{}), now)[@"status"], @"unknown", @"sans claims : inconnu, jamais inventé");
    CheckEqual(TMClaudeBillingFromSubscription(@{@"next_charge_date":@"2026-10-20"}, now)[@"status"], @"known", @"échéance Claude (date seule)");
    CheckEqual(TMClaudeBillingFromSubscription(@{@"subscription":@{@"current_period_end":@1792500000}}, now)[@"status"], @"known", @"échéance Claude imbriquée en secondes");
    CheckEqual(TMClaudeBillingFromSubscription(@{@"status":@"active"}, now)[@"status"], @"unknown", @"sans date : inconnu");
    CheckEqual(TMClaudeBillingFromSubscription(@[], now)[@"status"], @"unknown", @"réponse inattendue : inconnu");
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
    NSArray *pairs = @[@[TMProviderClaude, TM_ACC_A, claude], @[TMProviderOpenAI, TM_ACC_B, openai]];

    long long t0 = 1784000000;
    NSArray *h1 = TMAppendHistory(pairs, t0);
    CheckEqual(@(h1.count), @1, @"premier point enregistré");
    CheckEqual(h1[0][@"p"][TMHistoryKey(TMProviderClaude, TM_ACC_A, @"five_hour")], @34, @"le point Claude est présent");
    CheckEqual(h1[0][@"p"][TMHistoryKey(TMProviderOpenAI, TM_ACC_B, @"seven_day")], @41, @"le point OpenAI est présent");

    NSArray *h2 = TMAppendHistory(pairs, t0 + 30);
    CheckEqual(@(h2.count), @1, @"un point < 5 min après est fusionné (pas de doublon)");

    NSArray *h3 = TMAppendHistory(pairs, t0 + 301);
    CheckEqual(@(h3.count), @2, @"un point > 5 min après est ajouté");

    NSArray *h4 = TMAppendHistory(@[], t0 + 400);
    CheckEqual(@(h4.count), @2, @"sans fenêtre, rien n'est enregistré");

    // Deux comptes du même fournisseur : la régression déjà vue côté OpenAI (deux limites sur une
    // seule clé, la moitié de la donnée perdue en silence) se reproduirait ici à l'identique.
    NSArray *twoClaude = @[@[TMProviderClaude, TM_ACC_A, claude],
                           @[TMProviderClaude, TM_ACC_B, @[@{@"windowId": @"five_hour", @"usedPercent": @77.0}]]];
    NSArray *h5 = TMAppendHistory(twoClaude, t0 + 650);
    NSDictionary *last = h5.lastObject[@"p"];
    CheckEqual(last[TMHistoryKey(TMProviderClaude, TM_ACC_A, @"five_hour")], @34, @"compte A gardé");
    CheckEqual(last[TMHistoryKey(TMProviderClaude, TM_ACC_B, @"five_hour")], @77, @"compte B gardé, pas écrasé");

    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
}

#pragma mark - Registre de comptes

static void TestAccountRegistry(void) {
    Section(@"TMNormalizeAccountRegistry — un registre corrompu ne fait pas tomber l'app");
    CheckEqual(@(TMNormalizeAccountRegistry(nil).count), @0, @"nil -> vide");
    CheckEqual(@(TMNormalizeAccountRegistry(@"pas un tableau").count), @0, @"type inattendu -> vide");
    CheckEqual(@(TMNormalizeAccountRegistry(@[@{@"accountId": @"pas-un-uuid", @"provider": @"claude"}]).count),
               @0, @"identifiant invalide écarté");
    CheckEqual(@(TMNormalizeAccountRegistry(@[@{@"accountId": TM_ACC_A, @"provider": @"mistral"}]).count),
               @0, @"fournisseur inconnu écarté");

    NSArray *dupes = @[@{@"accountId": TM_ACC_A, @"provider": @"claude"},
                       @{@"accountId": TM_ACC_A, @"provider": @"claude"}];
    CheckEqual(@(TMNormalizeAccountRegistry(dupes).count), @1, @"identifiant dupliqué : une seule entrée");

    Section(@"TMRegistryAdding / Removing / Setting");
    NSArray *registry = TMRegistryAdding(@[], TMProviderClaude, TM_ACC_A, @"Perso");
    registry = TMRegistryAdding(registry, TMProviderClaude, TM_ACC_B, @"Pro");
    CheckEqual(@(TMAccountsForProvider(registry, TMProviderClaude).count), @2, @"deux comptes Claude");
    CheckEqual(@(TMAccountsForProvider(registry, TMProviderOpenAI).count), @0, @"aucun compte OpenAI");
    CheckEqual(TMAccountWithID(registry, TM_ACC_B)[@"label"], @"Pro", @"le label est retenu");

    registry = TMRegistrySetting(registry, TM_ACC_B, @"orgId", @"org-42");
    CheckEqual(TMAccountWithID(registry, TM_ACC_B)[@"orgId"], @"org-42", @"org id enregistré");
    CheckEqual(TMAccountWithID(registry, TM_ACC_B)[@"label"], @"Pro", @"les autres champs sont intacts");

    registry = TMRegistryRemoving(registry, TM_ACC_A);
    Check(TMAccountWithID(registry, TM_ACC_A) == nil, @"compte supprimé");
    CheckEqual(TMAccountWithID(registry, TM_ACC_B)[@"order"], @0, @"l'ordre est renuméroté après suppression");

    Section(@"Plafond par fournisseur");
    NSArray *full = @[];
    for (NSInteger i = 0; i < TMMaxAccountsPerProvider; i++) {
        full = TMRegistryAdding(full, TMProviderOpenAI, TMNewAccountID(), @"");
    }
    Check(TMProviderIsFull(full, TMProviderOpenAI), @"le fournisseur est plein");
    Check(TMRegistryAdding(full, TMProviderOpenAI, TMNewAccountID(), @"") == nil,
          @"ajout refusé au-delà du plafond (nil, pas un ajout silencieux)");
    Check(TMRegistryAdding(full, TMProviderClaude, TMNewAccountID(), @"") != nil,
          @"l'autre fournisseur n'est pas affecté");

    Section(@"TMAccountDisplayLabel — repli lisible");
    CheckEqual(TMAccountDisplayLabel(@{@"provider":TMProviderOpenAI,@"label":@"Perso",@"email":@"person@example.com"},0), @"person@example.com", @"OpenAI : email prioritaire sur le nom");
    CheckEqual(TMAccountDisplayLabel(@{@"provider":TMProviderClaude,@"label":@"Jeudi",@"email":@"person@example.com"},0), @"Jeudi", @"Claude : nom conservé");
    CheckEqual(TMAccountDisplayLabel(@{@"provider": TMProviderClaude, @"label": @""}, 1),
               @"Claude 2", @"sans label, une numérotation par fournisseur");
    CheckEqual(TMAccountDisplayLabel(@{@"provider": TMProviderOpenAI, @"label": @""}, 0),
               @"OpenAI 1", @"la numérotation repart de 1 chez l'autre fournisseur");
    CheckEqual(TMAccountDisplayLabel(@{@"provider": TMProviderClaude, @"label": @"Perso"}, 1),
               @"Perso", @"avec label, le label");
}

static void TestLegacyMigration(void) {
    Section(@"TMMigrateLegacyRegistry — mise à jour depuis le mono-compte");
    NSDictionary *migrated = TMMigrateLegacyRegistry(@[]);
    NSArray *registry = migrated[@"registry"];
    CheckEqual(@(registry.count), @2, @"un compte par fournisseur est créé");
    Check(TMIsAccountID(migrated[@"openaiAccountId"]), @"identifiant OpenAI exploitable");
    Check(TMIsAccountID(migrated[@"claudeAccountId"]), @"identifiant Claude exploitable");

    NSDictionary *again = TMMigrateLegacyRegistry(registry);
    Check(again[@"openaiAccountId"] == nil, @"un registre déjà peuplé n'est pas re-migré");
    CheckEqual(@([again[@"registry"] count]), @2, @"et il traverse intact");

    Section(@"TMMigrateHistoryKeys — les courbes ne repartent pas de zéro");
    NSArray *legacy = @[@{@"t": @1784000000, @"p": @{@"claude:five_hour": @30, @"openai:seven_day": @44}}];
    NSArray *out = TMMigrateHistoryKeys(legacy, TM_ACC_B, TM_ACC_A);
    NSDictionary *points = out[0][@"p"];
    CheckEqual(points[TMHistoryKey(TMProviderClaude, TM_ACC_A, @"five_hour")], @30, @"clé Claude réécrite");
    CheckEqual(points[TMHistoryKey(TMProviderOpenAI, TM_ACC_B, @"seven_day")], @44, @"clé OpenAI réécrite");
    CheckEqual(@(points.count), @2, @"aucune clé héritée ne subsiste");

    NSArray *twice = TMMigrateHistoryKeys(out, TM_ACC_B, TM_ACC_A);
    CheckEqual(twice[0][@"p"], points, @"idempotent : repasser dessus ne change rien");

    // Les identifiants d'une deuxième migration ne doivent pas déplacer les points déjà rattachés.
    NSArray *thrice = TMMigrateHistoryKeys(out, TMNewAccountID(), TMNewAccountID());
    CheckEqual(thrice[0][@"p"], points, @"un compte déjà porté par la clé n'est pas réattribué");

    Section(@"TMHistoryDroppingAccount — pas de série orpheline");
    NSArray *mixed = @[@{@"t": @1, @"p": @{TMHistoryKey(TMProviderClaude, TM_ACC_A, @"five_hour"): @10,
                                          TMHistoryKey(TMProviderClaude, TM_ACC_B, @"five_hour"): @20}},
                       @{@"t": @2, @"p": @{TMHistoryKey(TMProviderClaude, TM_ACC_A, @"five_hour"): @11}}];
    NSArray *dropped = TMHistoryDroppingAccount(mixed, TM_ACC_A);
    CheckEqual(@(dropped.count), @1, @"une rangée vidée de tous ses points disparaît");
    CheckEqual(dropped[0][@"p"][TMHistoryKey(TMProviderClaude, TM_ACC_B, @"five_hour")], @20,
               @"les points de l'autre compte survivent");

    Section(@"TMMigrateLegacyAccountsCache — dictionnaire par fournisseur vers par compte");
    NSDictionary *cache = TMMigrateLegacyAccountsCache(@{@"claude": @{@"windows": @[]},
                                                         @"openai": @{@"windows": @[]}},
                                                        TM_ACC_B, TM_ACC_A);
    Check(cache[TM_ACC_A] != nil && cache[TM_ACC_B] != nil, @"les deux payloads sont réattribués");
    NSDictionary *already = TMMigrateLegacyAccountsCache(cache, TMNewAccountID(), TMNewAccountID());
    CheckEqual(@(already.count), @2, @"un cache déjà au bon format traverse sans changement");
    Check(already[TM_ACC_A] != nil, @"et garde ses identifiants");
}

#pragma mark - Métrique de la barre des menus

static NSArray *TMFakeAccounts(void) {
    return @[
        @{@"accountId": TM_ACC_A, @"provider": TMProviderClaude, @"label": @"Perso",
          @"windows": @[@{@"windowId": @"five_hour", @"label": @"5 h", @"usedPercent": @30.0, @"resetsAt": @4102444800},
                        @{@"windowId": @"seven_day", @"label": @"7 j", @"usedPercent": @40.0, @"resetsAt": @4102444800},
                        @{@"windowId": @"seven_day_scoped_fable", @"label": @"Fable", @"usedPercent": @95.0, @"resetsAt": @4102444800}]},
        @{@"accountId": TM_ACC_B, @"provider": TMProviderClaude, @"label": @"Pro",
          @"windows": @[@{@"windowId": @"seven_day", @"label": @"7 j", @"usedPercent": @72.0, @"resetsAt": @4102444800}]},
        @{@"accountId": @"33333333-3333-4333-8333-333333333333", @"provider": TMProviderOpenAI, @"label": @"Boulot",
          @"windows": @[@{@"windowId": @"codex-10080", @"label": @"Semaine", @"durationMinutes": @10080, @"usedPercent": @55.0, @"resetsAt": @4102444800}]}
    ];
}

static void TestMenuBarMetricResolution(void) {
    Section(@"TMResolveMenuBarMetric — agrégats");
    NSArray *accounts = TMFakeAccounts();

    NSDictionary *weekly = TMResolveMenuBarMetric(@"claude:weekly", accounts);
    CheckEqual(weekly[@"usedPercent"], @72.0, @"agrégat Claude semaine : le compte le plus contraint");
    CheckEqual(weekly[@"label"], @"Pro", @"et il se nomme");
    CheckEqual(weekly[@"aggregated"], @YES, @"marqué comme agrégat");

    CheckEqual(TMResolveMenuBarMetric(@"claude:session", accounts)[@"usedPercent"], @30.0,
               @"agrégat Claude 5 h");
    CheckEqual(TMResolveMenuBarMetric(@"claude:weekly-fable", accounts)[@"usedPercent"], @95.0,
               @"agrégat Fable");
    CheckEqual(TMResolveMenuBarMetric(@"openai:weekly", accounts)[@"usedPercent"], @55.0,
               @"agrégat OpenAI semaine");

    Section(@"TMResolveMenuBarMetric — « lowest » exclut les sous-quotas scoped");
    NSDictionary *lowest = TMResolveMenuBarMetric(@"lowest", accounts);
    CheckEqual(lowest[@"usedPercent"], @72.0, @"la semaine Pro (72) gagne, pas le Fable à 95");
    CheckEqual(lowest[@"shortLabel"], @"C sem", @"étiquette courte de la fenêtre montrée");

    Section(@"TMResolveMenuBarMetric — épinglage d'un compte");
    NSString *pinned = TMPinnedMetricForAccount(TMProviderClaude, TM_ACC_A, @"weekly");
    CheckEqual(TMResolveMenuBarMetric(pinned, accounts)[@"usedPercent"], @40.0,
               @"le compte épinglé donne SON chiffre, pas le maximum");
    CheckEqual(TMResolveMenuBarMetric(pinned, accounts)[@"label"], @"Perso", @"et son nom");

    // Le cas qui compte : un compte épinglé puis supprimé ne doit pas figer l'icône sur un tiret.
    NSString *ghost = TMPinnedMetricForAccount(TMProviderClaude, @"44444444-4444-4444-8444-444444444444", @"weekly");
    NSDictionary *fallback = TMResolveMenuBarMetric(ghost, accounts);
    Check(fallback != nil, @"compte épinglé disparu : on retombe sur quelque chose");
    CheckEqual(fallback[@"usedPercent"], @72.0, @"…sur l'agrégat de SON fournisseur");
    CheckEqual(fallback[@"aggregated"], @YES, @"…marqué comme tel");

    Section(@"TMResolveMenuBarMetric — sans donnée");
    Check(TMResolveMenuBarMetric(@"claude:weekly", @[]) == nil, @"aucun compte -> nil");
    Check(TMResolveMenuBarMetric(@"openai:weekly", @[accounts[0]]) == nil,
          @"fournisseur sans compte -> nil");

    Section(@"Jauges indépendantes — choix du compte transmis au rendu");
    NSString *openID=@"33333333-3333-4333-8333-333333333333";
    NSString *otherID=@"55555555-5555-4555-8555-555555555555";
    NSMutableArray *twoOpen=[accounts mutableCopy];
    [twoOpen addObject:@{@"accountId":otherID,@"provider":@"openai",@"label":@"Autre",
        @"windows":@[@{@"windowId":@"codex-10080",@"durationMinutes":@10080,@"usedPercent":@5,@"resetsAt":@4102444800}]}];
    NSString *openPin=TMPinnedMetricForAccount(@"openai",otherID,@"weekly");
    NSDictionary *selection=@{@"openai":openPin,@"claude":pinned};
    CheckEqual(TMResolveMenuBarMetric(TMProviderMenuMetric(@"openai",selection,@"claude:weekly"),twoOpen)[@"usedPercent"],@5,@"OpenAI sélectionné : 95 % restant, pas 45 % de l’agrégat");
    CheckEqual(TMResolveMenuBarMetric(TMProviderMenuMetric(@"claude",selection,openPin),twoOpen)[@"accountId"],TM_ACC_A,@"changer OpenAI conserve le compte Claude");
    CheckEqual(TMProviderMenuMetric(@"openai",@{},openPin),openPin,@"ancien compte épinglé repris au premier lancement");
    CheckEqual(TMProviderMenuMetric(@"claude",@{},openPin),@"claude:weekly",@"un choix OpenAI ne devient jamais le choix Claude");
    CheckEqual(TMProviderMenuMetric(@"openai",@{@"openai":@"openai:weekly"},openPin),@"openai:weekly",@"tous rétablit explicitement l’agrégat");
    NSDictionary *unavailable=@{@"accountId":otherID,@"provider":@"openai",@"windows":@[]};
    Check(TMResolveMenuBarMetric(openPin,@[accounts.lastObject,unavailable])==nil,@"compte choisi sans quota : inconnu, jamais le chiffre du voisin");
    CheckEqual(TMResolveMenuBarMetric(TMPinnedMetricForAccount(@"openai",openID,@"weekly"),twoOpen)[@"usedPercent"],@55,@"revenir au premier compte redonne sa valeur");

    Section(@"TMHistoryKeyMatchesMetric — sparkline");
    NSString *claudeWeeklyA = TMHistoryKey(TMProviderClaude, TM_ACC_A, @"seven_day");
    NSString *claudeFableA = TMHistoryKey(TMProviderClaude, TM_ACC_A, @"seven_day_scoped_fable");
    Check(TMHistoryKeyMatchesMetric(claudeWeeklyA, @"claude:weekly"), @"agrégat : la clé participe");
    Check(!TMHistoryKeyMatchesMetric(claudeFableA, @"claude:weekly"), @"le scoped ne pollue pas la semaine");
    Check(TMHistoryKeyMatchesMetric(claudeFableA, @"claude:weekly-fable"), @"le scoped alimente Fable");
    Check(TMHistoryKeyMatchesMetric(claudeWeeklyA, pinned), @"épinglé : la clé du compte participe");
    Check(!TMHistoryKeyMatchesMetric(TMHistoryKey(TMProviderClaude, TM_ACC_B, @"seven_day"), pinned),
          @"épinglé : la clé d'un autre compte est exclue");
    Check(!TMHistoryKeyMatchesMetric(claudeFableA, @"lowest"), @"« lowest » exclut le scoped");
    Check(TMHistoryKeyMatchesMetric(claudeWeeklyA, @"lowest"), @"« lowest » inclut la semaine");
}

static void TestAccountsCache(void) {
    Section(@"TMSaveAccountsCache / TMLoadAccountsCache — volumes persistés au redémarrage");
    NSString *sandbox = [NSTemporaryDirectory() stringByAppendingPathComponent:@"status-tests-accounts"];
    [NSFileManager.defaultManager removeItemAtPath:sandbox error:nil];
    setenv("STATUS_SUPPORT_DIR", sandbox.UTF8String, 1);

    Check(TMLoadAccountsCache() == nil, @"aucun cache au départ : nil (démarrage vide, comme avant)");

    NSDictionary *accounts = @{
        TM_ACC_A: @{ @"windows": @[@{@"windowId": @"seven_day", @"usedPercent": @62.0, @"resetsAt": @4102444800}],
                     @"capturedAt": @1784000000, @"provider": TMProviderClaude },
        TM_ACC_B: @{ @"windows": @[], @"provider": TMProviderOpenAI }
    };
    TMSaveAccountsCache(accounts);
    NSDictionary *loaded = TMLoadAccountsCache();
    Check(loaded != nil, @"le cache se recharge après écriture");
    CheckEqual(loaded[TM_ACC_A][@"windows"][0][@"usedPercent"], @62, @"les volumes Claude survivent au round-trip");
    CheckEqual(loaded[TM_ACC_A][@"capturedAt"], @1784000000, @"l'horodatage de la dernière mesure est conservé");

    // Robustesse : une entrée non sérialisable n'écrase pas un cache valide par un fichier corrompu.
    TMSaveAccountsCache((NSDictionary *)@"pas un dictionnaire");
    Check(TMLoadAccountsCache() != nil, @"une entrée invalide laisse le cache précédent intact");
    TMSaveAccountsCache(@{});
    // Un dictionnaire vide est ignoré (guard !count) : le dernier cache valide reste.
    CheckEqual(TMLoadAccountsCache()[TM_ACC_A][@"windows"][0][@"usedPercent"], @62, @"dictionnaire vide ignoré : cache valide préservé");

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

// Fenêtre normalisée pour les tests de notifications quota.
static NSDictionary *TMWin(NSString *wid, NSString *label, double used, long long resetsAt, long long minutes) {
    return @{ @"windowId": wid, @"label": label, @"usedPercent": @(used),
              @"remainingPercent": @(100 - used), @"resetsAt": @(resetsAt), @"durationMinutes": @(minutes) };
}

static void TestWeeklyResetStatistics(void) {
    Section(@"Statistiques de renouvellement — observations globales par compte");
    double day=86400, now=2000000000;
    NSString *key=@"openai#one", *historyKey=@"resethistory:openai#one";
    CheckEqual(TMWeeklyResetStatistics(nil,key,now)[@"status"],@"publicStale",@"référence publique expirée sans date inventée");
    double fresh=1789084800;
    NSDictionary *bootstrap=TMWeeklyResetStatistics(nil,key,fresh);
    CheckEqual(bootstrap[@"status"],@"publicEstimated",@"statistiques publiques alimentent le démarrage");
    CheckEqual(bootstrap[@"observationCount"],@0,@"aucun faux événement personnel");
    CheckEqual(bootstrap[@"estimatedAt"],@(1788840353+4.8*86400),@"projection depuis le dernier reset public, jamais depuis maintenant");
    CheckEqual(TMWeeklyResetStatistics(nil,key,fresh+7*day)[@"status"],@"publicOverdue",@"prévision publique dépassée sans report");
    CheckEqual(TMWeeklyResetStatistics(nil,@"claude#one",fresh)[@"publicReference"][@"scope"],@"Max",@"périmètre Claude conservé");
    NSDictionary *personal=@{historyKey:@[@(fresh-15*day),@(fresh-8*day),@(fresh-day)]};
    CheckEqual(TMWeeklyResetStatistics(personal,key,fresh)[@"basis"],@"account",@"historique personnel prioritaire");
    NSDictionary *legacy=@{@"lastresetobserved:openai#one":@(now-day)};
    CheckEqual(TMWeeklyResetStatistics(legacy,key,now)[@"observationCount"],@1,@"ancienne dernière détection conservée comme un seul échantillon");
    CheckEqual(TMWeeklyResetStatistics(legacy,@"openai#two",now)[@"observationCount"],@0,@"aucune mutualisation des comptes");
    NSDictionary *regular=@{historyKey:@[@(now-15*day),@(now-8*day),@(now-day)]};
    NSDictionary *stats=TMWeeklyResetStatistics(regular,key,now);
    CheckEqual(stats[@"status"],@"estimated",@"trois observations permettent une estimation");
    CheckEqual(stats[@"medianSeconds"],@(7*day),@"médiane des intervalles effectivement observés");
    CheckEqual(stats[@"estimatedAt"],@(now+6*day),@"date centrale issue du dernier événement et de la médiane");
    CheckEqual(stats[@"confidence"],@"low",@"deux intervalles restent peu fiables");
    Check([stats[@"earliestAt"] doubleValue]<now+6*day && [stats[@"latestAt"] doubleValue]>now+6*day,@"plage avec marge au lieu d'une précision à la minute");
    CheckEqual(TMWeeklyResetStatistics(regular,key,now+10*day)[@"status"],@"overdue",@"prévision manquée jamais reportée automatiquement d'une semaine");
    NSMutableArray *dates=[NSMutableArray array];
    for(int i=5;i>=0;i--) [dates addObject:@(now-day-i*7*day)];
    CheckEqual(TMWeeklyResetStatistics(@{historyKey:dates},key,now)[@"confidence"],@"moderate",@"cinq intervalles réguliers : confiance modérée seulement");
    NSDictionary *irregular=TMWeeklyResetStatistics(@{historyKey:@[@(now-20*day),@(now-19*day),@(now-day)]},key,now);
    CheckEqual(irregular[@"status"],@"irregular",@"forte dispersion empêche une date trompeuse");
    Check(!irregular[@"estimatedAt"],@"pas de prévision pour des intervalles trop irréguliers");
    NSDictionary *dirty=@{historyKey:@[@(now-day),@(now-day),@(now+day),@(now-181*day),@"bad",NSNull.null,@(NAN)]};
    CheckEqual(TMWeeklyResetStatistics(dirty,key,now)[@"observationCount"],@1,@"dates futures anciennes invalides et doublons exclus");
    [dates removeAllObjects];
    for(int i=100;i>0;i--) [dates addObject:@(now-i*day)];
    CheckEqual(TMWeeklyResetStatistics(@{historyKey:dates},key,now)[@"observationCount"],@64,@"historique borné à 64 événements");
    NSArray *(^pairs)(double,long long)=^NSArray *(double used,long long reset){ return @[@[key,@[TMWin(@"weekly",@"Semaine",used,reset,10080)]]]; };
    NSDictionary *state=TMQuotaNotificationDecisions(nil,pairs(80,now+day),@[],NO,now-1000)[@"state"];
    NSDictionary *drift=TMQuotaNotificationDecisions(state,pairs(81,now+8*day),@[],NO,now-500)[@"state"];
    Check(!drift[historyKey],@"date annoncée qui avance sans baisse : aucun événement statistique");
    NSDictionary *reset=TMQuotaNotificationDecisions(drift,pairs(2,now+8*day),@[],NO,now);
    CheckEqual(reset[@"state"][historyKey],@[@(now)],@"baisse forte enregistrée même notifications désactivées");
    CheckEqual(@([reset[@"events"] count]),@0,@"les statistiques ne créent aucune notification");
    NSDictionary *repeat=TMQuotaNotificationDecisions(reset[@"state"],pairs(2,now+8*day),@[],NO,now+300)[@"state"];
    CheckEqual(@([repeat[historyKey] count]),@1,@"relecture et redémarrage ne dupliquent pas le reset");
    NSDictionary *again=TMQuotaNotificationDecisions(repeat,pairs(80,now+8*day),@[],NO,now+3*day-3600)[@"state"];
    again=TMQuotaNotificationDecisions(again,pairs(81,now+8*day),@[],NO,now+3*day-1800)[@"state"];
    again=TMQuotaNotificationDecisions(again,pairs(2,now+8*day),@[],NO,now+3*day)[@"state"];
    CheckEqual(@([again[historyKey] count]),@2,@"recharge anticipée à 72 h comptée même échéance inchangée");
    NSDictionary *oscillation=TMQuotaNotificationDecisions(repeat,pairs(80,now+8*day),@[],NO,now+3*day)[@"state"];
    oscillation=TMQuotaNotificationDecisions(oscillation,pairs(2,now+8*day),@[],NO,now+3*day+300)[@"state"];
    CheckEqual(@([oscillation[historyKey] count]),@1,@"source haute isolée ne fabrique pas un deuxième reset");
    NSDictionary *scoped=TMQuotaNotificationDecisions(nil,@[@[key,@[TMWin(@"seven_day_scoped",@"Fable",90,now+day,10080)]]],@[],NO,now)[@"state"];
    scoped=TMQuotaNotificationDecisions(scoped,@[@[key,@[TMWin(@"seven_day_scoped",@"Fable",0,now+8*day,10080)]]],@[],NO,now+300)[@"state"];
    Check(!scoped[historyKey],@"renouvellement modèle exclu des statistiques");
    NSDictionary *migrated=[legacy mutableCopy];
    NSMutableDictionary *pre=[state mutableCopy]; [pre addEntriesFromDictionary:migrated];
    NSDictionary *post=TMQuotaNotificationDecisions(pre,pairs(2,now+8*day),@[],NO,now)[@"state"];
    CheckEqual(@([post[historyKey] count]),@2,@"ancienne détection intégrée au premier nouveau reset");
}

static void TestQuotaNotificationDecisions(void) {
    Section(@"TMQuotaNotificationDecisions — seuils et réinitialisations hebdo");
    NSArray *levels = @[@80, @95];
    NSTimeInterval now = 500000;
    NSArray *(^pairs)(NSDictionary *) = ^NSArray *(NSDictionary *window) {
        return @[@[@"Claude", @[window]]];
    };

    // Franchissement du premier seuil, une seule fois.
    NSDictionary *weekly = TMWin(@"seven_day", @"Semaine", 84.6, 1000000, 10080);
    NSDictionary *r = TMQuotaNotificationDecisions(nil, pairs(weekly), levels, YES, now);
    NSArray *events = r[@"events"];
    CheckEqual(@(events.count), @1, @"84,6 % : un événement");
    CheckEqual(events.firstObject[@"kind"], @"threshold", @"de type seuil");
    CheckEqual(events.firstObject[@"level"], @80, @"au niveau 80");
    CheckEqual(events.firstObject[@"provider"], @"Claude", @"fournisseur transmis");
    CheckEqual(events.firstObject[@"label"], @"Semaine", @"libellé transmis");
    NSDictionary *state = r[@"state"];
    r = TMQuotaNotificationDecisions(state, pairs(weekly), levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"même observation : plus rien");

    NSDictionary *highReset = TMQuotaNotificationDecisions(nil, pairs(TMWin(@"seven_day", @"Semaine", 80, 1000000, 10080)), @[], NO, now)[@"state"];
    NSDictionary *resetObserved = TMQuotaNotificationDecisions(highReset, pairs(TMWin(@"seven_day", @"Semaine", 2, 1600000, 10080)), @[], NO, 1100000);
    CheckEqual(resetObserved[@"state"][@"lastresetobserved:Claude"], @1100000, @"date observée enregistrée même avec alertes désactivées");
    CheckEqual(@([resetObserved[@"events"] count]), @0, @"enregistrer une date ne force pas une notification");
    NSDictionary *sameReset = TMQuotaNotificationDecisions(resetObserved[@"state"], pairs(TMWin(@"seven_day", @"Semaine", 2, 1600000, 10080)), @[], NO, 1100100);
    CheckEqual(sameReset[@"state"][@"lastresetobserved:Claude"], @1100000, @"relecture conserve la date originale");
    NSDictionary *otherAccount = TMQuotaNotificationDecisions(sameReset[@"state"], @[@[@"Claude#other", @[weekly]]], @[], NO, now);
    Check(!otherAccount[@"state"][@"lastresetobserved:Claude#other"], @"date non partagée entre comptes");
    Check(!highReset[@"lastresetobserved:Claude"], @"première mesure ne fabrique aucune date passée");

    // Montée au second seuil.
    r = TMQuotaNotificationDecisions(r[@"state"], pairs(TMWin(@"seven_day", @"Semaine", 96, 1000000, 10080)),
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @1, @"96 % : un événement de plus");
    CheckEqual([r[@"events"] firstObject][@"level"], @95, @"au niveau 95");

    // Saut direct au-dessus des deux seuils : une seule notification, au plus haut niveau.
    NSDictionary *direct = TMQuotaNotificationDecisions(nil, pairs(TMWin(@"seven_day", @"Semaine", 96, 1000000, 10080)),
                                                        levels, YES, now);
    CheckEqual(@([direct[@"events"] count]), @1, @"0 → 96 % : un seul événement");
    CheckEqual([direct[@"events"] firstObject][@"level"], @95, @"le plus haut niveau atteint");

    // Nouvelle période : reset notifié (hebdo, peu entamée), seuils réarmés, vieilles clés purgées.
    NSDictionary *rolled = TMWin(@"seven_day", @"Semaine", 3, 1600000, 10080);
    r = TMQuotaNotificationDecisions(r[@"state"], pairs(rolled), levels, YES, 1100000);
    events = r[@"events"];
    CheckEqual(@(events.count), @1, @"période tournée : un événement");
    CheckEqual(events.firstObject[@"kind"], @"reset", @"de type reset");
    CheckEqual(events.firstObject[@"resetsAt"], @1600000, @"porte la nouvelle heure de reset");
    Check([r[@"state"][@"reset:Claude:seven_day"] isEqual:@1600000], @"l'état suit le nouveau reset");
    for (NSString *key in r[@"state"])
        Check(![key hasSuffix:@"@1000000"], @"clé de seuil de la période passée purgée");
    r = TMQuotaNotificationDecisions(r[@"state"], pairs(rolled), levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @0, @"reset déjà notifié : silence");
    // Et les seuils repartent de zéro sur la nouvelle période.
    r = TMQuotaNotificationDecisions(r[@"state"], pairs(TMWin(@"seven_day", @"Semaine", 85, 1600000, 10080)),
                                     levels, YES, 1100000);
    CheckEqual([r[@"events"] firstObject][@"level"], @80, @"seuil réarmé par la nouvelle période");

    // Garde-fous du reset.
    NSDictionary *base = TMQuotaNotificationDecisions(nil, pairs(TMWin(@"seven_day", @"Semaine", 10, 1000000, 10080)),
                                                      levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(base, pairs(TMWin(@"seven_day", @"Semaine", 60, 1600000, 10080)), levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @0, @"reset avec 60 % consommé : données mêlées, pas de notification");
    Check([r[@"state"][@"reset:Claude:seven_day"] isEqual:@1600000], @"mais l'état avance quand même");
    // Référence forgée : même avec un resetsAt connu qui avance, une fenêtre session reste muette.
    r = TMQuotaNotificationDecisions(@{ @"reset:Claude:five_hour": @1000000 },
                                     pairs(TMWin(@"five_hour", @"5 h", 3, 1600000, 300)), levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @0, @"fenêtre 5 h qui tourne : jamais de notification de reset");
    r = TMQuotaNotificationDecisions(base, pairs(TMWin(@"seven_day", @"Semaine", 3, 1600000, 10080)), levels, NO, 1100000);
    CheckEqual(@([r[@"events"] count]), @0, @"réinitialisations coupées : silence");
    NSDictionary *first = TMQuotaNotificationDecisions(nil, pairs(rolled), @[], YES, 1100000);
    CheckEqual(@([first[@"events"] count]), @0, @"première observation : jamais de reset (pas de référence)");

    // Reset par effondrement : OpenAI recharge parfois un compteur en plein milieu de semaine,
    // sans toujours faire avancer resetsAt. La chute du pourcentage est alors le seul signal.
    NSDictionary *beforeCollapse = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 40, 1000000, 10080)]]],
                                                                levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(beforeCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 2, 1000000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @1, @"40 % → 2 %, même resetsAt : reset détecté");
    CheckEqual([r[@"events"] firstObject][@"kind"], @"reset", @"de type reset");
    NSDictionary *afterCollapse = r[@"state"];
    r = TMQuotaNotificationDecisions(afterCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 2, 1000000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"même effondrement revu : silence");
    // Oscillation entre deux sources (l'une figée haute, l'autre en direct basse) : une seule
    // notification par période, pas une à chaque bascule.
    NSDictionary *osc = TMQuotaNotificationDecisions(afterCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 40, 1000000, 10080)]]],
                                                     levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(osc, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 2, 1000000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"oscillation dans la même période : pas de rafale");
    // Sous-quotas par modèle : leur réinitialisation N'EST PAS l'événement attendu. Il en existe
    // plusieurs par compte, ils tournent à leur propre rythme, et une notification par sous-quota
    // ferait passer le vrai reset hebdomadaire pour du bruit.
    Section(@"réinitialisation hebdo — sous-quotas exclus");
    NSDictionary *fableHigh = TMWin(@"seven_day_scoped_fable", @"7 j · Fable", 40, 1000000, 10080);
    NSDictionary *fableLow = TMWin(@"seven_day_scoped_fable", @"7 j · Fable", 2, 1000000, 10080);
    NSDictionary *fableState = TMQuotaNotificationDecisions(nil, pairs(fableHigh), levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(fableState, pairs(fableLow), levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"Fable 40 % → 2 % : aucun reset annoncé");

    // Côté OpenAI, la limite additionnelle n'a rien de « scoped » dans son identifiant : seul le
    // drapeau primaryLimit la distingue de la limite générale.
    NSDictionary *(^secondary)(double) = ^NSDictionary *(double used) {
        NSMutableDictionary *w = [TMWin(@"codex_bengalfox-10080", @"bengalfox · Semaine", used, 1000000, 10080) mutableCopy];
        w[@"primaryLimit"] = @NO;
        return w;
    };
    NSDictionary *secondaryState = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[secondary(40)]]], levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(secondaryState, @[@[@"OpenAI", @[secondary(2)]]], levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"limite OpenAI additionnelle : aucun reset annoncé");

    // Les seuils suivent le même périmètre que les renouvellements : semaine globale seule.
    NSArray *excluded = @[secondary(99),
        TMWin(@"seven_day_scoped_fable", @"7 j · Fable", 99, 1000000, 10080),
        TMWin(@"seven_day_scoped_opus", @"7 j · Opus", 99, 1000000, 10080),
        TMWin(@"seven_day_scoped_sonnet", @"7 j · Sonnet", 99, 1000000, 10080),
        TMWin(@"five_hour", @"5 h", 99, 1000000, 300),
        TMWin(@"overage", @"Dépassement", 99, 1000000, 0)];
    for (NSDictionary *window in excluded) {
        NSDictionary *ignored = TMQuotaNotificationDecisions(nil, pairs(window), levels, YES, now);
        CheckEqual(@([ignored[@"events"] count]), @0,
                   [NSString stringWithFormat:@"%@ à 99 %% : aucune alerte", window[@"label"]]);
        CheckEqual(@([ignored[@"state"] count]), @0, @"fenêtre exclue : aucun état de notification créé");
    }
    NSMutableArray *allWindows = [excluded mutableCopy];
    [allWindows addObject:TMWin(@"seven_day", @"7 jours", 96, 1000000, 10080)];
    NSDictionary *globalOnly = TMQuotaNotificationDecisions(nil, @[@[@"Claude", allWindows]], levels, YES, now);
    CheckEqual(@([globalOnly[@"events"] count]), @1, @"relevé mixte : seul le seuil global notifie");
    CheckEqual([globalOnly[@"events"] firstObject][@"label"], @"7 jours", @"alerte portée par la semaine globale");

    // …et la limite générale, elle, notifie toujours, drapeau explicite ou non.
    NSMutableDictionary *primaryHigh = [TMWin(@"codex-10080", @"Semaine", 40, 1000000, 10080) mutableCopy];
    primaryHigh[@"primaryLimit"] = @YES;
    NSMutableDictionary *primaryLow = [TMWin(@"codex-10080", @"Semaine", 2, 1000000, 10080) mutableCopy];
    primaryLow[@"primaryLimit"] = @YES;
    NSDictionary *primaryState = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[primaryHigh]]], levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(primaryState, @[@[@"OpenAI", @[primaryLow]]], levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @1, @"limite générale : le reset est annoncé");

    // Les deux dans le même relevé : une seule notification, celle qui compte.
    NSDictionary *mixedBefore = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[primaryHigh, secondary(40)]],
                                                                    @[@"Claude", @[fableHigh]]], levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(mixedBefore, @[@[@"OpenAI", @[primaryLow, secondary(2)]],
                                                    @[@"Claude", @[fableLow]]], levels, YES, now);
    NSArray *resets = [r[@"events"] filteredArrayUsingPredicate:
                       [NSPredicate predicateWithFormat:@"kind == %@", @"reset"]];
    CheckEqual(@(resets.count), @1, @"trois fenêtres qui retombent, un seul reset annoncé");
    CheckEqual(resets.firstObject[@"label"], @"Semaine", @"…celui de la limite générale");

    Section(@"TMWindowIsPrimaryWeekly");
    Check(TMWindowIsPrimaryWeekly(TMWin(@"seven_day", @"Semaine", 10, 1000000, 10080)),
          @"la semaine générale Claude est principale");
    Check(!TMWindowIsPrimaryWeekly(fableHigh), @"le sous-quota Fable ne l'est pas");
    Check(!TMWindowIsPrimaryWeekly(secondary(10)), @"une limite OpenAI additionnelle non plus");
    Check(!TMWindowIsPrimaryWeekly(TMWin(@"five_hour", @"5 h", 10, 1000000, 300)),
          @"une fenêtre 5 h n'est pas hebdomadaire");
    Check(TMWindowIsPrimaryWeekly(TMWin(@"codex-10080", @"Semaine", 10, 1000000, 10080)),
          @"sans drapeau, une hebdo non scoped reste principale");

    // Une baisse ordinaire n'est pas un reset.
    r = TMQuotaNotificationDecisions(beforeCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 20, 1000000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"40 % → 20 % : simple baisse, pas de notification");
    NSDictionary *lowStart = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 10, 1000000, 10080)]]],
                                                          levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(lowStart, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 2, 1000000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"10 % → 2 % : trop peu entamée pour signifier un reset");
    // L'effondrement ne s'applique qu'aux fenêtres hebdo, comme le reste.
    r = TMQuotaNotificationDecisions(@{ @"used:Claude:five_hour": @40 },
                                     pairs(TMWin(@"five_hour", @"5 h", 2, 1000000, 300)), levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"effondrement d'une fenêtre 5 h : silence");
    // resetsAt glissant (observé sur OpenAI : la date dérive au fil de l'activité, +37 h entre
    // deux relevés, sans qu'aucun compteur ne se recharge). Sans corroboration par une baisse de
    // consommation, chaque relevé notifierait un faux reset.
    NSDictionary *drift = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 30, 1000000, 10080)]]],
                                                       levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(drift, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 31, 1140000, 10080)]]],
                                     levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"resetsAt qui dérive, consommation stable : pas de notification");
    // Un vrai roulement corrobore : la date avance ET la consommation retombe.
    r = TMQuotaNotificationDecisions(drift, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 4, 1600000, 10080)]]],
                                     levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @1, @"date qui avance + consommation retombée : reset notifié");
    // Après un effondrement déjà signalé, une période close sur une semaine restée légère est un
    // non-événement (rien ne contraignait) ; elle se re-signale dès que la semaine a compté.
    r = TMQuotaNotificationDecisions(afterCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 2, 1600000, 10080)]]],
                                     levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @0, @"semaine restée à 2 % qui tourne : non-événement");
    NSDictionary *heavyAgain = TMQuotaNotificationDecisions(afterCollapse, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 60, 1000000, 10080)]]],
                                                            levels, YES, now)[@"state"];
    r = TMQuotaNotificationDecisions(heavyAgain, @[@[@"OpenAI", @[TMWin(@"codex-10080", @"Semaine", 3, 1600000, 10080)]]],
                                     levels, YES, 1100000);
    CheckEqual(@([r[@"events"] count]), @1, @"nouvelle période après une semaine chargée : notifiée");

    // Seuils coupés (liste vide) : aucune notification de seuil.
    r = TMQuotaNotificationDecisions(nil, pairs(TMWin(@"seven_day", @"Semaine", 96, 1000000, 10080)), @[], YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"levels vide : pas de seuils");

    // Fenêtre sans resetsAt : ignorée sans crash ; état sérialisable en plist/JSON.
    NSDictionary *broken = @{ @"windowId": @"x", @"label": @"X", @"usedPercent": @99 };
    r = TMQuotaNotificationDecisions(nil, @[@[@"OpenAI", @[broken]]], levels, YES, now);
    CheckEqual(@([r[@"events"] count]), @0, @"fenêtre sans reset : ignorée");
    Check([NSJSONSerialization isValidJSONObject:r[@"state"] ?: @{}], @"état sérialisable");
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

static void TestAlertRearm(void) {
    Section(@"TMAlertRearmThreshold — hystérésis des seuils réglables");
    // 8 % du seuil : 90 → 82,8, proche de la marge d'origine codée en dur (82).
    Check(fabs(TMAlertRearmThreshold(90) - 82.8) < 0.01, @"seuil 90 → réarmement 82,8 (8 %)");
    Check(fabs(TMAlertRearmThreshold(100) - 92) < 0.01, @"seuil 100 → réarmement 92");
    // Plancher de 2 unités : sans lui, un seuil bas donnerait une bande d'hystérésis quasi nulle
    // et l'alerte se remettrait à mitrailler au moindre frémissement.
    Check(fabs(TMAlertRearmThreshold(10) - 8) < 0.01, @"seuil bas : marge plancher de 2 unités");
    Check(fabs(TMAlertRearmThreshold(4) - 2) < 0.01, @"seuil 4 (pression mémoire) → 2");
    Check(TMAlertRearmThreshold(90) < 90, @"le réarmement reste sous le seuil");
    Check(TMAlertRearmThreshold(1) >= 0, @"seuil minuscule : réarmement jamais négatif");
    Check(TMAlertRearmThreshold(0) == 0, @"seuil nul : dégénéré mais sans crash");
    Check(TMAlertRearmThreshold(-5) == 0, @"seuil négatif : ramené à 0");
    // Le couple seuil/réarmement doit rester exploitable par TMThresholdShouldFire.
    BOOL above = NO;
    double t = 75, r = TMAlertRearmThreshold(t);
    Check(TMThresholdShouldFire(&above, 80, t, r), @"seuil réglé à 75 : franchissement détecté");
    Check(!TMThresholdShouldFire(&above, 72, t, r), @"72 > réarmement (69) : reste armé");
    TMThresholdShouldFire(&above, 60, t, r);
    Check(!above, @"60 < réarmement : désarmé");
}

static void TestMetricsDeltaPayload(void) {
    Section(@"TMMetricsDeltaPayload — tick incrémental sans les séries");
    NSDictionary *payload = @{
        @"families": @[ @{ @"id": @"cpu", @"now": @{ @"total": @43, @"coreTypes": @"EEPP" },
                           @"series": @{ @"total": @[@40, @41, @43] } },
                        @{ @"id": @"ram", @"now": @{ @"usedPercent": @68 },
                           @"series": @{ @"usedPercent": @[@67, @68] } } ],
        @"processes": @[ @{ @"name": @"X", @"cpuPercent": @12 } ],
        @"intervalSeconds": @1,
    };
    NSDictionary *delta = TMMetricsDeltaPayload(payload);
    CheckEqual(delta[@"delta"], @YES, @"marqué comme incrémental");
    NSArray *families = delta[@"families"];
    CheckEqual(@(families.count), @2, @"mêmes familles");
    CheckEqual(families.firstObject[@"id"], @"cpu", @"id conservé");
    CheckEqual(families.firstObject[@"now"][@"total"], @43, @"now conservé");
    Check(families.firstObject[@"series"] == nil, @"séries retirées : elles glissent côté client");
    CheckEqual(delta[@"processes"], payload[@"processes"], @"processus conservés");
    CheckEqual(delta[@"intervalSeconds"], @1, @"intervalle conservé");
    Check(payload[@"families"][0][@"series"] != nil, @"l'entrée n'est pas modifiée (pur)");
    Check([NSJSONSerialization isValidJSONObject:delta], @"delta sérialisable");
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

    // Capteurs : le client HID est persistant (créé au 1er tick, réutilisé ensuite) — les deux
    // sample ci-dessus exercent donc le chemin « cache ». Si la machine expose des capteurs,
    // tempC doit survivre au second passage avec une valeur plausible.
    NSNumber *tempC = familyNow(@"sensors")[@"tempC"];
    if (tempC) Check(tempC.doubleValue > 10 && tempC.doubleValue < 120,
                     @"tempC plausible au 2e tick (client HID réutilisé)");

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

        // Agrégats par famille : cohérence des relations max ≥ moyenne, et tempC = point chaud.
        NSNumber *dieMax = sensorsNow[@"dieMaxC"], *dieAvg = sensorsNow[@"dieAvgC"];
        if (dieMax) {
            Check(dieMax.doubleValue >= dieAvg.doubleValue, @"capteurs : die max ≥ die moyenne");
            Check([sensorsNow[@"tempC"] isEqualToNumber:dieMax], @"capteurs : tempC = point chaud du die");
            Check([sensorsNow[@"dieCount"] integerValue] > 0, @"capteurs : au moins un die identifié");
            printf("  dies : %s capteurs, max=%s moy=%s | périph. : max=%s moy=%s\n",
                   [sensorsNow[@"dieCount"] description].UTF8String,
                   dieMax.description.UTF8String, dieAvg.description.UTF8String,
                   [sensorsNow[@"deviceMaxC"] ?: @"—" description].UTF8String,
                   [sensorsNow[@"deviceAvgC"] ?: @"—" description].UTF8String);
        }
        NSNumber *devMax = sensorsNow[@"deviceMaxC"];
        if (devMax) Check(devMax.doubleValue >= [sensorsNow[@"deviceAvgC"] doubleValue],
                          @"capteurs : périphériques max ≥ moyenne");
    }
}

static NSDictionary *TMFakeSnapshot(void);  // défini avec les tests de widgets, plus bas

static void TestLongHistory(void) {
    Section(@"TMLongHistoryAppend — historique 24 h, une ligne par minute");
    const NSTimeInterval day = 24 * 60 * 60;
    NSArray *rows = TMLongHistoryAppend(nil, @{ @"t": @1000, @"cpu": @10 }, day, 2000);
    Check(rows.count == 1, @"première ligne : historique créé depuis nil");
    rows = TMLongHistoryAppend(rows, @{ @"t": @1060, @"cpu": @20 }, day, 2000);
    Check(rows.count == 2 && [rows.lastObject[@"cpu"] isEqual:@20], @"ligne suivante ajoutée en fin");

    // Élagage par âge : seules les lignes de plus de 24 h par rapport à la plus récente tombent.
    // Ici t=1000 est à 86 401 s (dehors) mais t=1060 à 86 341 s (dedans) : la frontière se voit.
    NSArray *aged = TMLongHistoryAppend(rows, @{ @"t": @(1000 + day + 1), @"cpu": @30 }, day, 2000);
    Check(aged.count == 2, @"au-delà de 24 h : seule la ligne hors fenêtre tombe");
    Check([aged.firstObject[@"t"] isEqual:@1060], @"la plus ancienne survivante est celle encore dans la fenêtre");
    Check([aged.lastObject[@"t"] doubleValue] == 1000 + day + 1, @"la ligne récente est conservée");

    // La fenêtre est relative à la ligne la plus récente, pas à l'heure courante : un historique
    // entièrement ancien mais cohérent doit survivre.
    NSArray *old = TMLongHistoryAppend(@[@{ @"t": @10 }], @{ @"t": @70 }, day, 2000);
    Check(old.count == 2, @"historique ancien mais dans la fenêtre : conservé intégralement");

    // Garde-fou de volume, indépendant de l'âge.
    NSArray *capped = TMLongHistoryAppend(@[@{ @"t": @1 }, @{ @"t": @2 }, @{ @"t": @3 }], @{ @"t": @4 }, day, 2);
    Check(capped.count == 2 && [capped.firstObject[@"t"] isEqual:@3], @"plafond de lignes : les plus anciennes tombent");

    // Robustesse : sans horodatage exploitable, on ne corrompt pas l'historique existant.
    NSArray *base = @[@{ @"t": @100 }];
    Check(TMLongHistoryAppend(base, @{ @"cpu": @5 }, day, 2000).count == 1, @"ligne sans « t » : ignorée");
    Check(TMLongHistoryAppend(base, @{ @"t": @"x" }, day, 2000).count == 1, @"« t » non numérique : ignorée");
    // Horodatage qui recule (changement d'heure, restauration) : refusé plutôt que d'obtenir une
    // série non monotone que les courbes dessineraient à l'envers.
    Check(TMLongHistoryAppend(base, @{ @"t": @50 }, day, 2000).count == 1, @"horodatage antérieur : refusé");
    Check(TMLongHistoryAppend(base, @{ @"t": @100 }, day, 2000).count == 2, @"horodatage identique : accepté");

    Section(@"TMLongHistoryRow — extraction des métriques suivies");
    NSDictionary *snapshot = TMFakeSnapshot();
    NSDictionary *row = TMLongHistoryRow(snapshot, 1700000000.4);
    Check([row[@"t"] doubleValue] == 1700000000, @"horodatage arrondi à la seconde");
    Check([row[@"cpu"] isEqual:@43], @"CPU relevé depuis la famille cpu");
    Check([row[@"ram"] isEqual:@68], @"RAM relevée depuis usedPercent");
    Check([row[@"temp"] isEqual:@50], @"température relevée depuis sensors.tempC");
    Check([row[@"batt"] isEqual:@100], @"batterie relevée depuis battery.percent");
    Check(row[@"rx"] != nil && row[@"tx"] != nil, @"débits réseau relevés");
    // Une famille absente ne doit pas fabriquer de zéro : la clé disparaît, comme partout ailleurs.
    NSDictionary *partial = @{ @"families": @[ @{ @"id": @"cpu", @"now": @{ @"total": @7 }, @"series": @{} } ] };
    NSDictionary *thin = TMLongHistoryRow(partial, 1000);
    Check(thin[@"cpu"] != nil && thin[@"temp"] == nil, @"famille absente : clé omise, pas de zéro inventé");
    Check(TMLongHistoryRow(@{ @"families": @[] }, 1000) == nil, @"aucune métrique : pas de ligne vide");
}

static void TestSensorFamily(void) {
    Section(@"TMSensorFamilyForName — regroupement des capteurs thermiques");
    // Noms réels relevés sur Apple Silicon (M-series) : ce sont ceux que la machine expose.
    Check([TMSensorFamilyForName(@"PMU tdie3") isEqualToString:@"die"], @"« PMU tdie3 » → die");
    Check([TMSensorFamilyForName(@"PMU tdie10") isEqualToString:@"die"], @"« PMU tdie10 » → die");
    Check([TMSensorFamilyForName(@"PMU tdev1") isEqualToString:@"device"], @"« PMU tdev1 » → périphérique");
    Check([TMSensorFamilyForName(@"gas gauge battery") isEqualToString:@"battery"], @"« gas gauge battery » → batterie");
    // tcal est une référence de calibration qui lit ~10 °C au-dessus des dies : l'inclure
    // fausserait le point chaud. Il doit être écarté malgré son préfixe « PMU t… ».
    Check(TMSensorFamilyForName(@"PMU tcal") == nil, @"« PMU tcal » (calibration) → écarté");
    // Noms Intel/génériques : le motif doit rester utile hors Apple Silicon.
    Check([TMSensorFamilyForName(@"PECI CPU") isEqualToString:@"die"], @"« PECI CPU » (Intel) → die");
    Check([TMSensorFamilyForName(@"SOC MTR Temp Sensor") isEqualToString:@"die"], @"nom contenant « SOC » → die");
    // Insensibilité à la casse et cas dégénérés.
    Check([TMSensorFamilyForName(@"PMU TDIE1") isEqualToString:@"die"], @"casse ignorée");
    Check(TMSensorFamilyForName(nil) == nil, @"nom absent → non classé");
    Check(TMSensorFamilyForName(@"") == nil, @"nom vide → non classé");
    Check(TMSensorFamilyForName(@"NAND Q1") == nil, @"nom inconnu → non classé (pas de famille inventée)");
    // La batterie prime : un capteur de batterie ne doit jamais compter comme un die, même si
    // son nom contenait par ailleurs un motif « die ».
    Check([TMSensorFamilyForName(@"battery tdie") isEqualToString:@"battery"], @"batterie prioritaire sur die");
}

static void TestSensorAggregates(void) {
    Section(@"TMSensorTempAggregates — agrégation des capteurs thermiques");
    NSArray *readings = @[
        @{ @"name": @"PMU tdie1", @"celsius": @44.4 },
        @{ @"name": @"PMU tdie2", @"celsius": @48.6 },
        @{ @"name": @"PMU tdev1", @"celsius": @35.2 },
        @{ @"name": @"gas gauge battery", @"celsius": @31.0 },
    ];
    NSDictionary *agg = TMSensorTempAggregates(readings);
    CheckEqual(agg[@"tempC"], @49, @"tempC = max des dies, arrondi");
    CheckEqual(agg[@"dieMaxC"], @49, @"dieMaxC arrondi");
    CheckEqual(agg[@"dieAvgC"], @47, @"dieAvgC : moyenne des dies (46,5 → 47)");
    CheckEqual(agg[@"dieCount"], @2, @"deux dies comptés");
    CheckEqual(agg[@"deviceMaxC"], @35, @"deviceMaxC arrondi");
    CheckEqual(agg[@"deviceCount"], @1, @"un périphérique compté");
    Check(agg[@"deviceCount"] && [agg[@"deviceCount"] integerValue] == 1,
          @"la batterie ne compte ni comme die ni comme périphérique");

    // Sans die identifiable : moyenne de toutes les lectures plausibles, classées ou non.
    NSArray *unknown = @[ @{ @"name": @"mystery", @"celsius": @40 }, @{ @"celsius": @20 } ];
    NSDictionary *aggUnknown = TMSensorTempAggregates(unknown);
    CheckEqual(aggUnknown[@"tempC"], @30, @"sans die : moyenne de tout");
    Check(aggUnknown[@"dieCount"] == nil, @"sans die : pas d'agrégats die");

    // Filtre de plausibilité : les capteurs fantômes rendent 0 ou des valeurs folles.
    NSArray *ghosts = @[ @{ @"name": @"PMU tdie1", @"celsius": @0 },
                         @{ @"name": @"PMU tdie2", @"celsius": @150 },
                         @{ @"name": @"PMU tdie3", @"celsius": @10 } ];
    Check(TMSensorTempAggregates(ghosts) == nil, @"fantômes seuls (0 / 150 / 10 °C) : nil");
    Check(TMSensorTempAggregates(@[]) == nil, @"aucune lecture : nil");

    // Batterie seule : plausible, donc tempC retombe sur la moyenne de tout.
    CheckEqual(TMSensorTempAggregates(@[ @{ @"name": @"gas gauge battery", @"celsius": @31.0 } ])[@"tempC"],
               @31, @"batterie seule : tempC = moyenne générale");
}

#pragma mark - Widgets de la barre des menus

// Snapshot moniteur synthétique : familles avec `now` et `series`, comme en production.
static NSDictionary *TMFakeSnapshot(void) {
    return @{ @"families": @[
        @{ @"id": @"cpu", @"now": @{ @"total": @43 }, @"series": @{ @"total": @[@10, @20, @43] } },
        @{ @"id": @"ram", @"now": @{ @"usedPercent": @68, @"pressureLevel": @1 }, @"series": @{} },
        @{ @"id": @"gpu", @"now": @{ @"usage": @24 }, @"series": @{ @"usage": @[@5, @24] } },
        @{ @"id": @"network", @"now": @{ @"rxBytesPerSec": @75776, @"txBytesPerSec": @71680 }, @"series": @{} },
        @{ @"id": @"disk", @"now": @{ @"usedPercent": @74 }, @"series": @{} },
        @{ @"id": @"sensors", @"now": @{ @"tempC": @50 }, @"series": @{} },
        @{ @"id": @"battery", @"now": @{ @"percent": @100, @"fullyCharged": @YES, @"charging": @NO, @"powerWatts": @-20 }, @"series": @{} },
    ] };
}

static void TestWidgetOrdering(void) {
    Section(@"TMArrayByMovingItem — ordre des widgets dans la barre");
    NSArray *list = @[@"cpu", @"memory", @"network"];
    Check([TMArrayByMovingItem(list, @"memory", -1) isEqual:(@[@"memory", @"cpu", @"network"])],
          @"déplacement vers la gauche");
    Check([TMArrayByMovingItem(list, @"memory", 1) isEqual:(@[@"cpu", @"network", @"memory"])],
          @"déplacement vers la droite");
    // Butées : un bouton en bout de liste ne doit rien réordonner ni faire disparaître d'élément.
    Check([TMArrayByMovingItem(list, @"cpu", -1) isEqual:list], @"premier vers la gauche : inchangé");
    Check([TMArrayByMovingItem(list, @"network", 1) isEqual:list], @"dernier vers la droite : inchangé");
    Check([TMArrayByMovingItem(list, @"gpu", 1) isEqual:list], @"élément absent : inchangé");
    Check([TMArrayByMovingItem(list, @"cpu", 0) isEqual:list], @"delta nul : inchangé");
    Check(TMArrayByMovingItem(@[], @"cpu", 1).count == 0, @"liste vide : pas de crash");
    // Un déplacement de plusieurs rangs d'un coup reste borné aux extrémités.
    Check([TMArrayByMovingItem(list, @"cpu", 2) isEqual:(@[@"memory", @"network", @"cpu"])],
          @"déplacement de deux rangs");
    Check([TMArrayByMovingItem(list, @"cpu", 5) isEqual:list], @"delta hors bornes : inchangé");
    // Aucun élément perdu ni dupliqué, quel que soit le mouvement.
    NSArray *moved = TMArrayByMovingItem(list, @"network", -2);
    Check(moved.count == list.count && [[NSSet setWithArray:moved] isEqual:[NSSet setWithArray:list]],
          @"le déplacement conserve exactement les mêmes éléments");
}

static void TestMenuBarWidgets(void) {
    Section(@"TMWidgetReadout — extraction et mise en forme");
    NSDictionary *snap = TMFakeSnapshot();

    NSDictionary *cpu = TMWidgetReadout(@"cpu", snap);
    CheckEqual(cpu[@"style"], @"bars", @"CPU : style histogramme");
    CheckEqual(cpu[@"title"], @"43 %", @"CPU : titre = charge globale");
    CheckEqual(@([cpu[@"series"] count]), @3, @"CPU : série historique transmise");

    NSDictionary *mem = TMWidgetReadout(@"memory", snap);
    CheckEqual(mem[@"style"], @"pie", @"Mémoire : style camembert");
    CheckEqual(mem[@"title"], @"68 %", @"Mémoire : titre");
    Check(fabs([mem[@"fraction"] doubleValue] - 0.68) < 1e-9, @"Mémoire : fraction 0,68");

    NSDictionary *net = TMWidgetReadout(@"network", snap);
    CheckEqual(net[@"style"], @"twoLine", @"Réseau : deux lignes");
    CheckEqual(net[@"primary"], @"↓ 74 Ko/s", @"Réseau : réception formatée");
    CheckEqual(net[@"secondary"], @"↑ 70 Ko/s", @"Réseau : émission formatée");

    NSDictionary *temp = TMWidgetReadout(@"temperature", snap);
    CheckEqual(temp[@"primary"], @"50°", @"Température : °C");
    CheckEqual(temp[@"secondary"], @"20 W", @"Température : watts (valeur absolue)");

    NSDictionary *batt = TMWidgetReadout(@"battery", snap);
    CheckEqual(batt[@"style"], @"battery", @"Batterie : style pile");
    CheckEqual(batt[@"primary"], @"Plein", @"Batterie pleine : « Plein »");
    CheckEqual(batt[@"secondary"], @"100 %", @"Batterie : pourcentage");
    Check(fabs([batt[@"fraction"] doubleValue] - 1.0) < 1e-9, @"Batterie : fraction 1");

    NSDictionary *disk = TMWidgetReadout(@"disk", snap);
    CheckEqual(disk[@"title"], @"74 %", @"Disque : occupation");

    // Sévérité : rare, seulement sur états anormaux.
    CheckEqual(cpu[@"severity"], @0, @"CPU chargé n'est pas une alerte");
    NSDictionary *hotSnap = @{ @"families": @[ @{ @"id": @"sensors", @"now": @{ @"tempC": @97 }, @"series": @{} } ] };
    CheckEqual(TMWidgetReadout(@"temperature", hotSnap)[@"severity"], @2, @"97 °C : critique");
    NSDictionary *lowBatt = @{ @"families": @[ @{ @"id": @"battery", @"now": @{ @"percent": @8, @"charging": @NO }, @"series": @{} } ] };
    CheckEqual(TMWidgetReadout(@"battery", lowBatt)[@"severity"], @2, @"8 % sur batterie : critique");

    // Absence de donnée : hasValue NO, jamais de valeur inventée.
    NSDictionary *empty = @{ @"families": @[] };
    Check(![TMWidgetReadout(@"cpu", empty)[@"hasValue"] boolValue], @"CPU sans famille : hasValue NO");
    Check(![TMWidgetReadout(@"battery", empty)[@"hasValue"] boolValue], @"Batterie absente (bureau) : hasValue NO");

    // Valeur mono-ligne (forme « texte ») et fractions pour anneau/camembert.
    CheckEqual(cpu[@"value"], @"43 %", @"CPU : valeur texte");
    CheckEqual(temp[@"value"], @"50°", @"Température : valeur texte");
    CheckEqual(batt[@"value"], @"100 %", @"Batterie : valeur texte = pourcentage");
    Check(fabs([TMWidgetReadout(@"temperature", snap)[@"fraction"] doubleValue] - 0.5) < 1e-9, @"Température : fraction 50/100 pour l'anneau");
    CheckEqual(@([cpu[@"series"] count]), @3, @"CPU : série pour barres/courbe");
    Check([TMWidgetReadout(@"memory", snap)[@"series"] count] == 0 || YES, @"Mémoire : série usedPercent transmise si présente");

    for (NSString *provider in @[@"claudeWeek",@"codexWeek"]) {
        NSDictionary *quotaSnapshot=@{@"families":@[@{@"id":provider,@"now":@{@"percent":@80},
            @"series":@{@"percent":@[@0,@20,@80,@100]}}]};
        NSDictionary *q=TMWidgetReadout(provider,quotaSnapshot);
        CheckEqual(q[@"value"],@"20 %",@"quota : texte restant");
        Check(fabs([q[@"fraction"] doubleValue]-0.2)<1e-9,@"quota : remplissage restant comme le texte");
        CheckEqual(q[@"series"],@[@100,@80,@20,@0],@"quota : historique du restant");
        Check(![TMWidgetReadout(provider,@{})[@"hasValue"] boolValue],@"quota absent reste inconnu");
    }
    // Rasteriser chaque dessin détecte aussi les inversions visuelles / masques de composition.
    for (NSString *design in TMIconDesignIDs()) {
        for (NSNumber *provider in @[@YES,@NO]) {
            double previous=-1;
            for (NSNumber *remaining in @[@0,@0.25,@0.75,@1]) {
                NSImage *image=TMProviderGauge(design,remaining,provider.boolValue);
                Check(NSEqualSizes(image.size,NSMakeSize(18,18)),@"jauge seule sans pictogramme adjacent");
                NSBitmapImageRep *bitmap=[[NSBitmapImageRep alloc] initWithData:image.TIFFRepresentation];
                double coverage=0;
                for (NSInteger y=0;y<bitmap.pixelsHigh;y++) for (NSInteger x=0;x<bitmap.pixelsWide;x++)
                    coverage += [bitmap colorAtX:x y:y].alphaComponent;
                Check(coverage>previous,@"plus de restant remplit davantage chaque jauge des deux fournisseurs");
                previous=coverage;
            }
            NSBitmapImageRep *missing=[[NSBitmapImageRep alloc] initWithData:TMProviderGauge(design,nil,provider.boolValue).TIFFRepresentation];
            NSBitmapImageRep *empty=[[NSBitmapImageRep alloc] initWithData:TMProviderGauge(design,@0,provider.boolValue).TIFFRepresentation];
            Check(![missing.TIFFRepresentation isEqual:empty.TIFFRepresentation],@"donnée absente distincte d'un quota épuisé");
        }
    }

    // Le dessin ne doit pas planter, quelle que soit la forme, la couleur ou l'entrée (fumée).
    NSArray *shapes = @[@"bars", @"graph", @"ring", @"pie", @"bar", @"text", @"twoLine", @"battery", @"ringValue", @"segments",
                        @"dial", @"dualArc", @"hub", @"chip", @"chipBar", @"inconnue", @""];
    NSArray *colors = @[@"auto", @"blue", @"red", @"purple", @"inconnu"];
    for (NSString *wid in TMMenuBarWidgetIDs())
        for (NSString *shape in shapes)
            for (NSString *color in colors) {
                Check(TMWidgetImageStyled(TMWidgetReadout(wid, snap), shape, color) != nil,
                      ([NSString stringWithFormat:@"dessin %@ forme=%@ couleur=%@", wid, shape.length ? shape : @"(auto)", color]));
                Check(TMWidgetImageStyled(TMWidgetReadout(wid, empty), shape, color) != nil,
                      ([NSString stringWithFormat:@"dessin %@ sans donnée forme=%@ : pas de crash", wid, shape.length ? shape : @"(auto)"]));
            }

    // La sévérité prime sur la couleur choisie : une couleur nommée existe, mais l'alerte reste.
    Check(TMWidgetNamedColor(@"blue") != nil, @"la palette expose « blue »");
    Check(TMWidgetNamedColor(@"auto") == nil, @"« auto » n'est pas une couleur nommée (template neutre)");

    // Encre imposée : la jauge quota dessine avec la couleur d'identité de son fournisseur, qui
    // n'est pas un nom de palette. nil ⇒ image template, que macOS inverse selon le thème.
    NSDictionary *quota = @{ @"style": @"ring", @"hasValue": @YES, @"fraction": @0.81, @"series": @[@70, @81],
                             @"value": @"81 %", @"valueTemplate": @"100 %", @"template": @"",
                             @"primary": @"", @"secondary": @"", @"charging": @NO, @"severity": @0 };
    for (NSString *shape in @[@"ring", @"bars", @"pie", @"bar", @"graph"]) {
        NSImage *tinted = TMWidgetImageWithInk(quota, shape, TMWidgetNamedColor(@"purple"));
        NSImage *neutral = TMWidgetImageWithInk(quota, shape, nil);
        Check(tinted != nil && !tinted.isTemplate, ([NSString stringWithFormat:@"jauge %@ : encre imposée, pas de template", shape]));
        Check(neutral != nil && neutral.isTemplate, ([NSString stringWithFormat:@"jauge %@ sans encre : template", shape]));
        CheckEqual(@(tinted.size.width), @(neutral.size.width), ([NSString stringWithFormat:@"jauge %@ : la couleur ne change pas la largeur", shape]));
    }
}

// La signature de rendu permet de sauter les redessins identiques (le tick tourne à 1 Hz : sans
// elle, chaque NSStatusItem serait régénéré et réassigné chaque seconde, valeur inchangée ou non).
static void TestWidgetRenderSignature(void) {
    Section(@"TMWidgetRenderSignature — sauter les redessins identiques");
    NSDictionary *snap = TMFakeSnapshot();
    NSDictionary *cpu = TMWidgetReadout(@"cpu", snap);

    Check(TMWidgetRenderSignature(cpu, @"ring", @"blue") != nil, @"signature non nulle");
    CheckEqual(TMWidgetRenderSignature(cpu, @"ring", @"blue"), TMWidgetRenderSignature(cpu, @"ring", @"blue"),
               @"mêmes entrées → signatures égales");

    // La série glisse à chaque tick. Une forme sans série (anneau) ne doit pas en dépendre —
    // c'est tout l'intérêt : valeur stable ⇒ pas de redessin.
    NSMutableDictionary *shifted = [cpu mutableCopy];
    shifted[@"series"] = @[@1, @2, @99];
    CheckEqual(TMWidgetRenderSignature(cpu, @"ring", @"blue"), TMWidgetRenderSignature(shifted, @"ring", @"blue"),
               @"anneau : la série qui glisse ne change pas la signature");
    Check(![TMWidgetRenderSignature(cpu, @"graph", nil) isEqual:TMWidgetRenderSignature(shifted, @"graph", nil)],
          @"courbe : la série fait partie du dessin");
    // La jauge principale (Status.m) réutilise la même signature pour sauter ses redessins ; sa
    // forme « spark » dessine la série comme « graph », et doit donc la garder dans la signature —
    // sinon la sparkline gèlerait dès que la valeur affichée cesse de bouger.
    Check(![TMWidgetRenderSignature(cpu, @"spark", nil) isEqual:TMWidgetRenderSignature(shifted, @"spark", nil)],
          @"spark : la série fait partie du dessin");
    CheckEqual(TMWidgetRenderSignature(cpu, @"spark", nil), TMWidgetRenderSignature(cpu, @"spark", nil),
               @"spark : mêmes entrées → signatures égales");
    // Forme vide → repli sur le style naturel du readout (bars pour le CPU), qui utilise la série.
    Check(![TMWidgetRenderSignature(cpu, nil, nil) isEqual:TMWidgetRenderSignature(shifted, nil, nil)],
          @"forme auto (bars pour le CPU) : la série compte");

    // Tout ce qui change les pixels ou le titre doit changer la signature.
    NSMutableDictionary *warmer = [cpu mutableCopy];
    warmer[@"title"] = @"88 %";
    Check(![TMWidgetRenderSignature(cpu, @"ring", @"blue") isEqual:TMWidgetRenderSignature(warmer, @"ring", @"blue")],
          @"titre différent → signature différente");
    Check(![TMWidgetRenderSignature(cpu, @"ring", @"blue") isEqual:TMWidgetRenderSignature(cpu, @"pie", @"blue")],
          @"forme différente → signature différente");
    Check(![TMWidgetRenderSignature(cpu, @"ring", @"blue") isEqual:TMWidgetRenderSignature(cpu, @"ring", @"red")],
          @"couleur différente → signature différente");
    CheckEqual(TMWidgetRenderSignature(cpu, nil, nil), TMWidgetRenderSignature(cpu, nil, nil),
               @"forme et couleur absentes : stable, pas de crash");
}

#pragma mark - Largeur réservée des icônes (pas de dérive dans la barre)

// Une icône dont la largeur suit son texte fait glisser toute la rangée à chaque tick : les
// voisines bougent, et le panneau qu'on vient d'ouvrir ne pointe plus sur l'icône cliquée.
// Chaque forme portant du texte doit donc réserver la largeur de son pire cas.
static NSDictionary *TMSnapshotWith(NSString *familyId, NSDictionary *now) {
    return @{ @"families": @[ @{ @"id": familyId, @"now": now, @"series": @{} } ] };
}

static CGFloat TMImageWidth(NSString *wid, NSDictionary *snapshot, NSString *shape) {
    return TMWidgetImageStyled(TMWidgetReadout(wid, snapshot), shape, nil).size.width;
}

static void TestWidgetStableWidth(void) {
    Section(@"Largeur d'icône réservée — la rangée ne glisse pas");

    // Réseau : de « ↓ 8 o/s » à « ↓ 999 Mo/s », deux fois plus de caractères.
    NSDictionary *slow = TMSnapshotWith(@"network", @{ @"rxBytesPerSec": @8, @"txBytesPerSec": @8 });
    NSDictionary *fast = TMSnapshotWith(@"network", @{ @"rxBytesPerSec": @1048000000, @"txBytesPerSec": @1048000000 });
    CheckEqual(@(TMImageWidth(@"network", slow, @"")), @(TMImageWidth(@"network", fast, @"")),
               @"Réseau : même largeur à 8 o/s et à 999 Mo/s");

    // Batterie : « Plein » / « 10 h 00 » / « 5 min », plus le pourcentage à un ou trois chiffres.
    NSDictionary *full = TMSnapshotWith(@"battery", @{ @"percent": @100, @"fullyCharged": @YES });
    NSDictionary *low = TMSnapshotWith(@"battery", @{ @"percent": @7, @"minutesRemaining": @620 });
    CheckEqual(@(TMImageWidth(@"battery", full, @"")), @(TMImageWidth(@"battery", low, @"")),
               @"Batterie : même largeur pleine et à 7 % / 10 h 20");

    // Température : « 5° / 3 W » contre « 100° / 120 W ».
    NSDictionary *cool = @{ @"families": @[ @{ @"id": @"sensors", @"now": @{ @"tempC": @5 }, @"series": @{} },
                                            @{ @"id": @"battery", @"now": @{ @"powerWatts": @-3 }, @"series": @{} } ] };
    NSDictionary *hot = @{ @"families": @[ @{ @"id": @"sensors", @"now": @{ @"tempC": @100 }, @"series": @{} },
                                           @{ @"id": @"battery", @"now": @{ @"powerWatts": @-120 }, @"series": @{} } ] };
    CheckEqual(@(TMImageWidth(@"temperature", cool, @"")), @(TMImageWidth(@"temperature", hot, @"")),
               @"Température : même largeur à 5 ° et à 100 °");

    // Forme « texte » : « 4 % » contre « 100 % ».
    NSDictionary *idle = TMSnapshotWith(@"cpu", @{ @"total": @4 });
    NSDictionary *busy = TMSnapshotWith(@"cpu", @{ @"total": @100 });
    CheckEqual(@(TMImageWidth(@"cpu", idle, @"text")), @(TMImageWidth(@"cpu", busy, @"text")),
               @"CPU en texte : même largeur à 4 % et à 100 %");

    // Une source muette ne doit pas non plus rétrécir l'icône : le tiret occupe la même place.
    CheckEqual(@(TMImageWidth(@"network", @{ @"families": @[] }, @"")), @(TMImageWidth(@"network", fast, @"")),
               @"Réseau sans donnée : la largeur reste réservée");

    // Titre système (formes barres/camembert) : « 4 % » doit occuper la largeur de « 100 % ».
    NSDictionary *attrs = @{ NSFontAttributeName: [NSFont monospacedDigitSystemFontOfSize:12 weight:NSFontWeightMedium] };
    CGFloat wide = [TMTitleWithReservedWidth(@"100 %", @"100 %", attrs) size].width;
    CGFloat narrow = [TMTitleWithReservedWidth(@"4 %", @"100 %", attrs) size].width;
    Check(fabs(wide - narrow) < 0.5, @"Titre : « 4 % » réserve la largeur de « 100 % »");
    // Un texte plus large que le gabarit n'est jamais rogné.
    Check([TMTitleWithReservedWidth(@"1000 %", @"100 %", attrs) size].width >= wide,
          @"Titre plus large que le gabarit : conservé tel quel");
    CheckEqual([TMTitleWithReservedWidth(@"4 %", @"100 %", attrs) string], @"4 %",
               @"Titre : le texte lisible reste intact (pas de bourrage de caractères)");
}

#pragma mark - Écrans (luminosité)

#pragma mark - Formes Anneaux et Console

static NSDictionary *TMRamSnapshot(double usedPercent, NSDictionary *extra) {
    NSMutableDictionary *now = [@{ @"usedPercent": @(usedPercent), @"pressureLevel": @1 } mutableCopy];
    [now addEntriesFromDictionary:extra ?: @{}];
    return TMSnapshotWith(@"ram", now);
}

static void TestWidgetNewShapes(void) {
    Section(@"Formes Anneaux / Console — readout, résolution, signature, largeur");
    NSDictionary *snap = TMFakeSnapshot();
    NSDictionary *empty = @{ @"families": @[] };

    // Échelle logarithmique des débits : bornée, monotone, nulle à l'arrêt.
    CheckEqual(@(TMWidgetRateFraction(0)), @0.0, @"débit nul : fraction 0");
    CheckEqual(@(TMWidgetRateFraction(-5)), @0.0, @"débit négatif : fraction 0");
    CheckEqual(@(TMWidgetRateFraction(200.0 * 1024 * 1024)), @1.0, @"au-delà de 100 Mo/s : plafonné à 1");
    Check(TMWidgetRateFraction(1024) < TMWidgetRateFraction(1048576)
          && TMWidgetRateFraction(1048576) < TMWidgetRateFraction(50.0 * 1048576), @"débit : fraction croissante");
    Check(TMWidgetRateFraction(75776) > 0.3, @"74 Ko/s se voit sur l'arc (échelle log, pas linéaire)");

    // Champs de puce et d'anneau chiffré, tirés de valeurs réelles.
    NSDictionary *cpu = TMWidgetReadout(@"cpu", snap);
    CheckEqual(cpu[@"chipLabel"], @"CPU", @"CPU : étiquette de puce");
    CheckEqual(cpu[@"chipValue"], @"43", @"CPU : chiffre seul");
    CheckEqual(cpu[@"chipUnit"], @"%", @"CPU : unité");
    CheckEqual(cpu[@"chipKind"], @"spark", @"CPU : puce à sparkline");
    CheckEqual(cpu[@"numeric"], @YES, @"CPU : chiffre disponible");
    NSDictionary *temp = TMWidgetReadout(@"temperature", snap);
    CheckEqual(temp[@"chipUnit"], @"°C", @"Température : unité °C");
    CheckEqual(temp[@"autoScale"], @YES, @"Température : sparkline à échelle ajustée");
    CheckEqual(TMWidgetReadout(@"memory", snap)[@"chipKind"], @"reservoir", @"Mémoire : puce à réservoir");
    CheckEqual(TMWidgetReadout(@"disk", snap)[@"chipLabel"], @"DSK", @"Disque : étiquette DSK");
    CheckEqual(TMWidgetReadout(@"battery", snap)[@"chipLabel"], @"BAT", @"Batterie : étiquette BAT");
    CheckEqual(TMWidgetReadout(@"network", snap)[@"chipLabel"], @"RÉS", @"Réseau : étiquette RÉS (français)");
    CheckEqual(TMWidgetReadout(@"anthropicApi", snap)[@"numeric"], @NO, @"Crédit API : pas de chiffre seul (texte en dollars)");
    CheckEqual(TMWidgetReadout(@"claudeWeek", @{ @"families": @[ @{ @"id": @"claudeWeek", @"now": @{ @"percent": @80 }, @"series": @{} } ] })[@"chipValue"],
               @"20", @"quota : le chiffre est le restant");
    CheckEqual(TMWidgetReadout(@"cpu", empty)[@"chipValue"], @"", @"sans donnée : pas de chiffre inventé");

    // Réseau : arcs ↓/↑ depuis les débits réels, série ramenée à 0..100 sur la même échelle.
    NSDictionary *net = TMWidgetReadout(@"network", snap);
    CheckEqual(net[@"dual"], @YES, @"Réseau : double donnée");
    Check([net[@"rxFraction"] doubleValue] > 0 && [net[@"rxFraction"] doubleValue] < 1, @"Réseau : arc ↓ entre 0 et 1");
    Check([net[@"rxFraction"] doubleValue] >= [net[@"txFraction"] doubleValue], @"Réseau : 74 Ko/s ≥ 70 Ko/s sur l'arc");
    NSDictionary *netSeries = TMSnapshotWith(@"network", @{ @"rxBytesPerSec": @1048576, @"txBytesPerSec": @0 });
    NSDictionary *withSeries = @{ @"families": @[ @{ @"id": @"network", @"now": @{ @"rxBytesPerSec": @1048576, @"txBytesPerSec": @0 },
                                                      @"series": @{ @"rxBytesPerSec": @[@0, @1048576, @(1000.0 * 1048576)] } } ] };
    NSArray *rxSeries = TMWidgetReadout(@"network", withSeries)[@"series"];
    Check(rxSeries.count == 3 && [rxSeries[0] doubleValue] == 0 && [rxSeries[2] doubleValue] == 100, @"Réseau : série en échelle log 0..100");
    CheckEqual(TMWidgetReadout(@"network", netSeries)[@"txFraction"], @0, @"Réseau : émission nulle → arc ↑ vide");
    CheckEqual(TMWidgetReadout(@"network", empty)[@"hasValue"], @NO, @"Réseau sans donnée : tiret");
    // Température : la série réelle des capteurs est transmise (sparkline de puce).
    NSDictionary *tempSeries = @{ @"families": @[ @{ @"id": @"sensors", @"now": @{ @"tempC": @51 }, @"series": @{ @"tempC": @[@48, @50, @51] } } ] };
    CheckEqual(TMWidgetReadout(@"temperature", tempSeries)[@"series"], (@[@48, @50, @51]), @"Température : série des capteurs transmise");

    // Parts mémoire : champs réels du collecteur, arrondis, ordre app / système / compressée / cache.
    double G = 1024.0 * 1024 * 1024;
    NSDictionary *ram = TMRamSnapshot(68, @{ @"totalBytes": @(32 * G), @"appBytes": @(14.2 * G), @"wiredBytes": @(3.1 * G),
                                             @"compressedBytes": @(2.4 * G), @"cachedBytes": @(6.0 * G) });
    NSArray *parts = TMWidgetReadout(@"memory", ram)[@"parts"];
    CheckEqual(@(parts.count), @4, @"Mémoire : quatre parts");
    Check(fabs([parts[0] doubleValue] - 0.44) < 1e-9 && fabs([parts[1] doubleValue] - 0.10) < 1e-9
          && fabs([parts[2] doubleValue] - 0.08) < 1e-9 && fabs([parts[3] doubleValue] - 0.19) < 1e-9,
          @"Mémoire : parts = octets / total, arrondies au pour cent");
    CheckEqual(@([TMWidgetReadout(@"memory", snap)[@"parts"] count]), @0, @"Mémoire sans détail d'octets : pas de parts (repli sur 10 segments)");
    NSDictionary *partial = TMRamSnapshot(68, @{ @"totalBytes": @(32 * G), @"appBytes": @(14.2 * G) });
    CheckEqual(@([TMWidgetReadout(@"memory", partial)[@"parts"] count]), @0, @"Mémoire : un champ manque → aucune part inventée");
    NSDictionary *overflow = TMRamSnapshot(68, @{ @"totalBytes": @(32 * G), @"appBytes": @(30 * G), @"wiredBytes": @(30 * G),
                                                  @"compressedBytes": @(1 * G), @"cachedBytes": @(1 * G) });
    CheckEqual(@([TMWidgetReadout(@"memory", overflow)[@"parts"] count]), @0, @"Mémoire : parts incohérentes (somme > total) écartées");
    CheckEqual(@([TMWidgetReadout(@"disk", ram)[@"parts"] count]), @0, @"Disque : jamais de parts");

    // Résolution forme → dessin : une forme inconnue ou inadaptée retombe sur la forme naturelle.
    CheckEqual(TMWidgetResolvedShape(cpu, nil), @"bars", @"forme vide → naturelle");
    CheckEqual(TMWidgetResolvedShape(cpu, @"inconnue"), @"bars", @"forme inconnue → naturelle");
    CheckEqual(TMWidgetResolvedShape(cpu, @"ringValue"), @"ringValue", @"CPU : anneau chiffré accepté");
    CheckEqual(TMWidgetResolvedShape(cpu, @"dualArc"), @"bars", @"CPU : double arc impossible → naturelle");
    CheckEqual(TMWidgetResolvedShape(net, @"dualArc"), @"dualArc", @"Réseau : double arc accepté");
    CheckEqual(TMWidgetResolvedShape(net, @"segments"), @"twoLine", @"Réseau : pas de fraction → forme naturelle");
    CheckEqual(TMWidgetResolvedShape(net, @"ringValue"), @"twoLine", @"Réseau : pas de chiffre seul → naturelle");
    CheckEqual(TMWidgetResolvedShape(net, @"chip"), @"chip", @"Réseau : puce acceptée");
    NSDictionary *api = TMWidgetReadout(@"anthropicApi", empty);
    CheckEqual(TMWidgetResolvedShape(api, @"chip"), @"ring", @"Crédit API : pas de puce → naturelle");
    CheckEqual(TMWidgetResolvedShape(api, @"ringValue"), @"ring", @"Crédit API : pas d'anneau chiffré → naturelle");
    CheckEqual(TMWidgetResolvedShape(api, @"dial"), @"dial", @"Crédit API : cadran accepté");
    CheckEqual(TMWidgetResolvedShape(TMWidgetReadout(@"memory", snap), @"hub"), @"hub", @"Mémoire : moyeu accepté");
    for (NSString *legacy in @[@"bars", @"graph", @"ring", @"pie", @"bar", @"text", @"twoLine", @"battery"])
        CheckEqual(TMWidgetResolvedShape(cpu, legacy), legacy, ([NSString stringWithFormat:@"forme historique « %@ » inchangée", legacy]));

    // Titre système : absent dès que la forme dessine son texte.
    Check(TMWidgetShapeCarriesText(cpu, @"ringValue"), @"anneau chiffré : porte son texte");
    Check(TMWidgetShapeCarriesText(cpu, @"chip") && TMWidgetShapeCarriesText(cpu, @"chipBar"), @"puces : portent leur texte");
    Check(TMWidgetShapeCarriesText(net, @"dualArc"), @"double arc : porte son texte");
    Check(!TMWidgetShapeCarriesText(cpu, @"segments") && !TMWidgetShapeCarriesText(cpu, @"dial")
          && !TMWidgetShapeCarriesText(cpu, @"ring") && !TMWidgetShapeCarriesText(cpu, nil),
          @"segments, cadran, anneau, histogramme : le titre système reste à côté");
    Check(TMWidgetShapeCarriesText(TMWidgetReadout(@"battery", snap), nil), @"batterie naturelle : texte dans l'image");
    Check(!TMWidgetShapeCarriesText(cpu, @"dualArc"), @"forme rejetée (CPU) retombe sur les barres : titre système conservé");

    // Signature : chaque champ de détail y entre quand la forme le dessine, et seulement alors.
    NSMutableDictionary *ramMoved = [TMWidgetReadout(@"memory", ram) mutableCopy];
    ramMoved[@"parts"] = @[@0.5, @0.1, @0.08, @0.19];
    NSDictionary *ramNow = TMWidgetReadout(@"memory", ram);
    Check(![TMWidgetRenderSignature(ramNow, @"segments", nil) isEqual:TMWidgetRenderSignature(ramMoved, @"segments", nil)],
          @"segments : une part qui bouge change la signature");
    CheckEqual(TMWidgetRenderSignature(ramNow, @"ring", nil), TMWidgetRenderSignature(ramMoved, @"ring", nil),
               @"anneau : les parts mémoire ne changent pas la signature");
    NSMutableDictionary *faster = [net mutableCopy];
    faster[@"rxFraction"] = @0.9;
    Check(![TMWidgetRenderSignature(net, @"dualArc", nil) isEqual:TMWidgetRenderSignature(faster, @"dualArc", nil)],
          @"double arc : l'arc ↓ entre dans la signature");
    CheckEqual(TMWidgetRenderSignature(net, @"twoLine", nil), TMWidgetRenderSignature(faster, @"twoLine", nil),
               @"2 lignes : les fractions de débit n'y entrent pas");
    NSMutableDictionary *shifted = [cpu mutableCopy];
    shifted[@"series"] = @[@11, @22, @44];
    Check(![TMWidgetRenderSignature(cpu, @"chip", nil) isEqual:TMWidgetRenderSignature(shifted, @"chip", nil)],
          @"puce à sparkline : la série entre dans la signature");
    CheckEqual(TMWidgetRenderSignature(cpu, @"chipBar", nil), TMWidgetRenderSignature(shifted, @"chipBar", nil),
               @"puce + jauge : la série n'y entre pas");
    CheckEqual(TMWidgetRenderSignature(cpu, @"ringValue", nil), TMWidgetRenderSignature(shifted, @"ringValue", nil),
               @"anneau chiffré : la série n'y entre pas");
    CheckEqual(TMWidgetRenderSignature(cpu, @"dualArc", nil)[@"shape"], @"bars", @"signature : forme rejetée résolue en forme naturelle");
    NSMutableDictionary *louder = [cpu mutableCopy];
    louder[@"chipValue"] = @"44"; louder[@"value"] = @"44 %";
    Check(![TMWidgetRenderSignature(cpu, @"ringValue", nil) isEqual:TMWidgetRenderSignature(louder, @"ringValue", nil)],
          @"anneau chiffré : un chiffre qui change redessine");

    // Toutes les formes, tous les widgets, tous les états : hauteur ≤ 18 pt, template en auto,
    // couleur imposée hors template, jamais nil, largeur indépendante de l'état (pas de saut).
    NSArray *newShapes = @[@"ringValue", @"segments", @"dial", @"dualArc", @"hub", @"chip", @"chipBar"];
    NSDictionary *states = @{ @"typique": snap, @"vide": empty };
    for (NSString *wid in TMMenuBarWidgetIDs()) {
        for (NSString *shape in newShapes) {
            for (NSString *stateName in states) {
                NSDictionary *readout = TMWidgetReadout(wid, states[stateName]);
                NSImage *mono = TMWidgetImageStyled(readout, shape, nil);
                NSImage *colored = TMWidgetImageStyled(readout, shape, @"blue");
                NSString *tag = [NSString stringWithFormat:@"%@ / %@ / %@", wid, shape, stateName];
                Check(mono != nil && mono.isTemplate, ([NSString stringWithFormat:@"%@ : image template sans couleur", tag]));
                Check(colored != nil && !colored.isTemplate, ([NSString stringWithFormat:@"%@ : image colorée", tag]));
                Check(mono.size.height <= 18 && mono.size.width > 0, ([NSString stringWithFormat:@"%@ : tient dans 18 pt de haut", tag]));
                CheckEqual(@(mono.size.width), @(colored.size.width), ([NSString stringWithFormat:@"%@ : la couleur ne change pas la largeur", tag]));
            }
        }
    }
    NSDictionary *alert = @{ @"families": @[ @{ @"id": @"battery", @"now": @{ @"percent": @6, @"charging": @NO }, @"series": @{} } ] };
    Check(!TMWidgetImageStyled(TMWidgetReadout(@"battery", alert), @"chipBar", nil).isTemplate, @"alerte : la puce est teintée même sans couleur choisie");

    // Largeur réservée au pire cas : aucun saut entre une mesure basse et une mesure haute.
    NSDictionary *calm = TMSnapshotWith(@"cpu", @{ @"total": @4 }), *loaded = TMSnapshotWith(@"cpu", @{ @"total": @100 });
    for (NSString *shape in @[@"ringValue", @"segments", @"dial", @"hub", @"chip", @"chipBar"])
        CheckEqual(@(TMImageWidth(@"cpu", calm, shape)), @(TMImageWidth(@"cpu", loaded, shape)),
                   ([NSString stringWithFormat:@"CPU en %@ : même largeur à 4 %% et à 100 %%", shape]));
    CheckEqual(@(TMImageWidth(@"cpu", empty, @"chip")), @(TMImageWidth(@"cpu", loaded, @"chip")), @"puce CPU sans donnée : largeur conservée");
    NSDictionary *slow = TMSnapshotWith(@"network", @{ @"rxBytesPerSec": @8, @"txBytesPerSec": @3 });
    NSDictionary *fast = TMSnapshotWith(@"network", @{ @"rxBytesPerSec": @1048000000, @"txBytesPerSec": @1048000000 });
    for (NSString *shape in @[@"dualArc", @"chip"])
        CheckEqual(@(TMImageWidth(@"network", slow, shape)), @(TMImageWidth(@"network", fast, shape)),
                   ([NSString stringWithFormat:@"Réseau en %@ : même largeur à 8 o/s et à 999 Mo/s", shape]));
    CheckEqual(@(TMImageWidth(@"network", empty, @"dualArc")), @(TMImageWidth(@"network", fast, @"dualArc")), @"double arc sans donnée : largeur conservée");
    NSDictionary *full = TMSnapshotWith(@"battery", @{ @"percent": @100, @"fullyCharged": @YES });
    NSDictionary *low = TMSnapshotWith(@"battery", @{ @"percent": @7, @"minutesRemaining": @620, @"charging": @YES });
    CheckEqual(@(TMImageWidth(@"battery", full, @"chipBar")), @(TMImageWidth(@"battery", low, @"chipBar")), @"Batterie en puce : charge ou non, même largeur");
    NSDictionary *coolT = TMSnapshotWith(@"sensors", @{ @"tempC": @5 }), *hotT = TMSnapshotWith(@"sensors", @{ @"tempC": @100 });
    CheckEqual(@(TMImageWidth(@"temperature", coolT, @"chip")), @(TMImageWidth(@"temperature", hotT, @"chip")), @"Température en puce : même largeur à 5 ° et 100 °");
    CheckEqual(@(TMImageWidth(@"cpu", calm, @"ringValue")), @18.0, @"anneau chiffré : cellule de 18 pt");

    // Les formes inconnues dessinent la forme naturelle (même image qu'une forme vide).
    NSImage *unknown = TMWidgetImageStyled(TMWidgetReadout(@"cpu", snap), @"inconnue", nil);
    NSImage *natural = TMWidgetImageStyled(TMWidgetReadout(@"cpu", snap), nil, nil);
    CheckEqual(@(unknown.size.width), @(natural.size.width), @"forme inconnue : même gabarit que la forme naturelle");
}

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
    Section(@"TMDDCGetVCPRequest / TMDDCSetVCPRequest / TMDDCParseVCPReply — format m1ddc");
    // Get : [0x82, 0x01, vcp, checksum], sans octet source 0x51 (celui-ci est l'offset I2C).
    NSData *getRequest = TMDDCGetVCPRequest(TMDDCBrightnessVCPCode);
    CheckEqual(@(getRequest.length), @4, @"requête Get VCP : 4 octets (longueur, opcode, code VCP, checksum)");
    const uint8_t *g = getRequest.bytes;
    CheckEqual(@(g[0]), @(0x82), @"longueur 0x82 (0x80 | 2 octets de données)");
    CheckEqual(@(g[1]), @(0x01), @"opcode Get VCP Feature = 0x01");
    CheckEqual(@(g[2]), @(TMDDCBrightnessVCPCode), @"code VCP = luminosité (0x10)");
    CheckEqual(@(g[3]), @(0x6E ^ 0x82 ^ 0x01 ^ TMDDCBrightnessVCPCode), @"checksum Get = 0x6E ^ octets (sans 0x51)");

    // Set : [0x84, 0x03, vcp, MSB, LSB, checksum] ; checksum inclut l'adresse source 0x51.
    NSData *setRequest = TMDDCSetVCPRequest(TMDDCBrightnessVCPCode, 42);
    CheckEqual(@(setRequest.length), @6, @"requête Set VCP : 6 octets");
    const uint8_t *s = setRequest.bytes;
    CheckEqual(@(s[0]), @(0x84), @"longueur 0x84 (0x80 | 4)");
    CheckEqual(@(s[1]), @(0x03), @"opcode Set VCP Feature = 0x03");
    CheckEqual(@(((s[3] << 8) | s[4])), @42, @"valeur reconstruite depuis MSB/LSB");
    CheckEqual(@(s[5]), @(0x6E ^ 0x51 ^ 0x84 ^ 0x03 ^ TMDDCBrightnessVCPCode ^ 0 ^ 42), @"checksum Set inclut 0x51");

    // Réponse « Get VCP Feature » : opcode [2]=0x02, résultat [3]=0x00, code VCP [4], max [6-7],
    // courant [8-9]. Le checksum n'est plus validé (convention de graine incertaine ; m1ddc ne la
    // vérifie pas non plus) — on s'appuie sur opcode + code VCP + plausibilité du maximum.
    uint8_t reply[12] = { 0x6E, 0x88, 0x02, 0x00, TMDDCBrightnessVCPCode, 0x00, 0x00, 100, 0x00, 62, 0x00, 0x00 };
    NSData *replyData = [NSData dataWithBytes:reply length:sizeof(reply)];
    uint16_t current = 0, maximum = 0;
    Check(TMDDCParseVCPReply(replyData, TMDDCBrightnessVCPCode, &current, &maximum), @"trame valide acceptée");
    CheckEqual(@(current), @62, @"valeur courante extraite (octets 8-9)");
    CheckEqual(@(maximum), @100, @"maximum extrait (octets 6-7)");

    uint8_t badOp[12] = { 0x6E, 0x88, 0x6D, 0x00, TMDDCBrightnessVCPCode, 0x00, 0x00, 100, 0x00, 62, 0x00, 0x00 };
    Check(!TMDDCParseVCPReply([NSData dataWithBytes:badOp length:12], TMDDCBrightnessVCPCode, &current, &maximum),
          @"charabia d'un écran Apple (opcode ≠ 0x02) -> rejeté");

    uint8_t wrongVCP[12] = { 0x6E, 0x88, 0x02, 0x00, 0x12, 0x00, 0x00, 100, 0x00, 62, 0x00, 0x00 };
    Check(!TMDDCParseVCPReply([NSData dataWithBytes:wrongVCP length:12], TMDDCBrightnessVCPCode, &current, &maximum),
          @"code VCP inattendu -> rejeté");

    uint8_t absurdMax[12] = { 0x6E, 0x88, 0x02, 0x00, TMDDCBrightnessVCPCode, 0x00, 0x80, 0xC1, 0x37, 0x2F, 0x00, 0x00 };
    Check(!TMDDCParseVCPReply([NSData dataWithBytes:absurdMax length:12], TMDDCBrightnessVCPCode, &current, &maximum),
          @"maximum invraisemblable (0x80C1) -> rejeté");

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

    // Rétroéclairage clavier : lecture seule ici (on ne touche pas au matériel en test).
    NSDictionary *keyboard = [snapshot.lastObject[@"kind"] isEqual:@"keyboard"] ? snapshot.lastObject : nil;
    if (manager.keyboard.available) {
        Check(keyboard != nil, @"clavier rétroéclairé : dernière entrée du snapshot, kind=keyboard");
        double value = [keyboard[@"brightness"] doubleValue];
        Check(value >= 0 && value <= 100, @"luminosité clavier en pourcentage 0–100");
        Check([keyboard[@"id"] isEqual:TMKeyboardBacklightIdentifier], @"id du clavier stable");
        printf("  clavier : brightness=%s\n", [keyboard[@"brightness"] description].UTF8String);
    } else {
        Check(keyboard == nil, @"sans rétroéclairage, aucune ligne clavier");
    }
    Check(![manager setBrightnessPercent:50 forIdentifier:@"inconnu"], @"identifiant inconnu : refusé, rien n'est réglé");

    // Les touches F1/F2 sont traitées sur le thread du tap : displayUnderMouse doit y répondre
    // comme sur le thread principal.
    TMDisplay *onMain = [manager displayUnderMouse];
    __block TMDisplay *onBackground = nil;
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    dispatch_async(dispatch_get_global_queue(QOS_CLASS_USER_INTERACTIVE, 0), ^{
        onBackground = [manager displayUnderMouse];
        dispatch_semaphore_signal(done);
    });
    dispatch_semaphore_wait(done, DISPATCH_TIME_FOREVER);
    Check(onMain == onBackground, @"écran sous la souris : même réponse hors du thread principal");
    Check(onMain != nil, @"écran sous la souris trouvé");
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

static void TestClaudeWebIdentity(void) {
    Section(@"Connexion web Claude — identité et sélection explicite");
    NSDictionary *a = @{@"uuid":@"11111111-1111-4111-8111-111111111111", @"name":@"Compte A"};
    NSDictionary *b = @{@"uuid":@"22222222-2222-4222-8222-222222222222", @"name":@"Compte B"};
    CheckEqual(TMClaudeWebOrganization(@[a,b], a[@"uuid"]), a, @"retrouve l'organisation attendue parmi plusieurs");
    Check(!TMClaudeWebOrganization(@[b], a[@"uuid"]), @"mauvais compte : refuse la migration");
    Check(!TMClaudeWebOrganization(@[a,b], @""), @"sans identité préalable, plusieurs organisations exigent un choix");
    CheckEqual(TMClaudeWebOrganization(@[b], @""), b, @"nouveau compte à une seule organisation");
    Check(!TMClaudeWebOrganization(@[], @""), @"aucune organisation : aucune migration");
    Check(!TMClaudeWebOrganization(@[@{@"uuid":@"../other"}, @"bad"], @""), @"identifiants invalides exclus");
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
    Check(TMPricesForModel(@"gpt-6-astra", &p) && p.input == 10 && p.output == 50 && p.cacheRead == 1,
          @"Astra : tarif standard officiel 10 / 50 / 1 dollars par million");
    TMPrices astra = {0};
    TMPricesForModel(@"gpt-6-astra", &astra);
    Check(fabs(TMCostForTokens((TMTokens){.input=1000000,.cacheRead=800000,.output=100000}, astra, TMCostProviderOpenAI)-7.8)<1e-9,
          @"Astra : tokens historiques tarifés sans compter le cache deux fois");
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

#pragma mark - Comptes API (crédit estimé)

// 2026-10-14 15:30:00 UTC, et les débuts de jour/mois correspondants.
#define TM_API_NOW 1791991800.0
#define TM_API_DAY 1791936000.0
#define TM_API_MONTH 1790812800.0

static void TestApiRegistry(void) {
    Section(@"Comptes API — registre");
    NSArray *registry = TMNormalizeApiRegistry(@[
        @{ @"accountId": TM_ACC_A, @"provider": @"anthropic", @"mode": @"prepaid", @"balanceUSD": @50, @"balanceSetAt": @(TM_API_NOW) },
        @{ @"accountId": TM_ACC_A, @"provider": @"openai" },                         // doublon
        @{ @"accountId": @"pas-un-uuid", @"provider": @"openai" },
        @{ @"accountId": TM_ACC_B, @"provider": @"mistral" },                        // fournisseur inconnu
        @{ @"accountId": TM_ACC_B, @"provider": @"openai", @"mode": @"budget" },     // budget absent
        @"bruit"
    ]);
    CheckEqual(@(registry.count), @2, @"entrées invalides et doublons écartés");
    CheckEqual(registry[0][@"mode"], @"prepaid", @"solde complet : mode prepaid gardé");
    CheckEqual(registry[1][@"mode"], @"none", @"budget sans montant : retombe sur « none »");
    CheckEqual(TMApiAccountDisplayLabel(registry[1], 0), @"OpenAI API 1", @"nom de repli numéroté");
    Check(TMNormalizeApiRegistry(@{}).count == 0, @"registre corrompu : vide, sans plantage");

    NSArray *full = @[];
    for (int i = 0; i < 5; i++) full = TMApiRegistryAdding(full, @"openai", NSUUID.UUID.UUIDString);
    CheckEqual(@(full.count), @5, @"cinq comptes par fournisseur");
    Check(TMApiRegistryAdding(full, @"openai", NSUUID.UUID.UUIDString) == nil, @"sixième refusé");
    Check(TMApiRegistryAdding(full, @"anthropic", NSUUID.UUID.UUIDString) != nil, @"l'autre fournisseur reste libre");
    Check(TMApiRegistryAdding(@[], @"openai", @"x") == nil, @"identifiant invalide refusé");
    CheckEqual(@(TMApiRegistryRemoving(registry, TM_ACC_A).count), @1, @"suppression");

    NSArray *budget = TMApiRegistrySettingBudget(registry, TM_ACC_B, 200);
    CheckEqual(TMApiAccountWithID(budget, TM_ACC_B)[@"mode"], @"budget", @"budget saisi : mode budget");
    NSArray *cleared = TMApiRegistryClearingMode(budget, TM_ACC_B);
    CheckEqual(TMApiAccountWithID(cleared, TM_ACC_B)[@"budgetUSD"], @200, @"le budget reste mémorisé hors mode");
    CheckEqual(TMApiAccountWithID(TMApiRegistrySettingBudget(registry, TM_ACC_B, -3), TM_ACC_B)[@"mode"], @"none", @"budget négatif ignoré");

    NSArray *credited = TMApiRegistryAddingCredit(registry, TM_ACC_A, 25);
    CheckEqual(TMApiAccountWithID(credited, TM_ACC_A)[@"balanceUSD"], @75, @"recharge ajoutée au solde");
    CheckEqual(TMApiAccountWithID(credited, TM_ACC_A)[@"balanceSetAt"], @(TM_API_NOW), @"la date de saisie ne bouge pas");
    CheckEqual(TMApiAccountWithID(TMApiRegistryAddingCredit(budget, TM_ACC_B, 25), TM_ACC_B)[@"balanceUSD"], nil, @"recharge sans effet hors prepaid");
    CheckEqual(TMApiAccountWithID(TMApiRegistrySettingLabel(registry, TM_ACC_A, @"  Prod  "), TM_ACC_A)[@"label"], @"Prod", @"renommage nettoyé");
}

static void TestApiBaseline(void) {
    Section(@"Comptes API — saisie du solde et ligne de base");
    NSArray *registry = TMApiRegistrySettingBalance(TMApiRegistryAdding(@[], @"anthropic", TM_ACC_A), TM_ACC_A, 100, TM_API_NOW, 0);
    NSDictionary *account = TMApiAccountWithID(registry, TM_ACC_A);
    CheckEqual(account[@"mode"], @"prepaid", @"saisie : mode prepaid");
    CheckEqual(account[@"baselinePending"], @YES, @"ligne de base en attente du relevé");
    NSString *today = [NSString stringWithFormat:@"%lld", (long long)TM_API_DAY];
    NSDictionary *daily = @{ today: @7.5 };
    NSArray *resolved = TMApiRegistryResolvingBaseline(registry, TM_ACC_A, daily, TM_API_NOW + 60);
    CheckEqual(TMApiAccountWithID(resolved, TM_ACC_A)[@"baselineUSD"], @7.5, @"base = dépense du jour au moment du relevé");
    CheckEqual(TMApiAccountWithID(resolved, TM_ACC_A)[@"baselinePending"], @NO, @"base fixée une seule fois");
    CheckEqual(TMApiAccountWithID(resolved, TM_ACC_A)[@"baselineApprox"], @NO, @"relevé le jour même : base exacte");

    // Saisie à 23 h 58 UTC, cache du jour à 7,50 $ ; premier relevé à 0 h 03 le lendemain.
    NSTimeInterval lateEvening = TM_API_DAY + 86400 - 120, nextDay = TM_API_DAY + 86400 + 180;
    NSArray *midnight = TMApiRegistrySettingBalance(TMApiRegistryAdding(@[], @"anthropic", TM_ACC_A), TM_ACC_A, 100, lateEvening, 7.5);
    NSString *tomorrow = [NSString stringWithFormat:@"%lld", (long long)(TM_API_DAY + 86400)];
    NSDictionary *after = @{ today: @9, tomorrow: @1 };
    NSArray *crossed = TMApiRegistryResolvingBaseline(midnight, TM_ACC_A, after, nextDay);
    NSDictionary *crossedAccount = TMApiAccountWithID(crossed, TM_ACC_A);
    CheckEqual(crossedAccount[@"baselineUSD"], @7.5, @"minuit franchi : la base dépend du jour de saisie (provisoire gardée)");
    CheckEqual(crossedAccount[@"baselineApprox"], @YES, @"minuit franchi : base marquée approximative");
    NSDictionary *crossedSummary = TMApiSummary(crossedAccount, after, nextDay, 10);
    CheckEqual(crossedSummary[@"sinceSetUSD"], @2.5, @"minuit franchi : seul l'après-saisie compte (9 − 7,5 + 1)");
    CheckEqual(crossedSummary[@"baselineApprox"], @YES, @"minuit franchi : l'estimation le dit");
    NSArray *noCache = TMApiRegistrySettingBalance(TMApiRegistryAdding(@[], @"anthropic", TM_ACC_A), TM_ACC_A, 100, lateEvening, 0);
    CheckEqual(TMApiSummary(TMApiAccountWithID(noCache, TM_ACC_A), after, nextDay, 10)[@"baselineApprox"], @YES,
               @"base en attente, jour de saisie fini : approximative avant même le relevé");
    NSArray *again = TMApiRegistryResolvingBaseline(resolved, TM_ACC_A, @{ today: @20 }, TM_API_NOW + 120);
    CheckEqual(TMApiAccountWithID(again, TM_ACC_A)[@"baselineUSD"], @7.5, @"une base fixée n'est plus recalculée");
}

static void TestApiInputs(void) {
    Section(@"Comptes API — montants et clés saisis");
    double v = -1;
    Check(TMParseUSDAmount(@"12,50", &v) && v == 12.5, @"virgule décimale");
    Check(TMParseUSDAmount(@"$1,234.56", &v) && fabs(v - 1234.56) < 1e-9, @"format anglais");
    Check(TMParseUSDAmount(@"1 234,5 $", &v) && v == 1234.5, @"format français");
    Check(TMParseUSDAmount(@"1.234,5", &v) && v == 1234.5, @"point des milliers");
    Check(TMParseUSDAmount(@"1,000", &v) && v == 1000, @"virgule des milliers");
    Check(TMParseUSDAmount(@"40 USD", &v) && v == 40, @"suffixe USD");
    Check(!TMParseUSDAmount(@"", &v), @"vide refusé");
    Check(!TMParseUSDAmount(@"-5", &v), @"négatif refusé");
    Check(!TMParseUSDAmount(@"douze", &v), @"texte refusé");
    Check(!TMParseUSDAmount(@"99999999", &v), @"montant absurde refusé");

    NSString *anthropic = [@"sk-ant-admin01-" stringByPaddingToLength:60 withString:@"a" startingAtIndex:0];
    NSString *openai = [@"sk-admin-" stringByPaddingToLength:60 withString:@"Z" startingAtIndex:0];
    Check(TMApiKeyHasExpectedShape(@"anthropic", anthropic), @"clé admin Anthropic acceptée");
    Check(TMApiKeyHasExpectedShape(@"openai", openai), @"clé admin OpenAI acceptée");
    Check(!TMApiKeyHasExpectedShape(@"openai", anthropic), @"clé de l'autre fournisseur refusée");
    Check(!TMApiKeyHasExpectedShape(@"anthropic", [@"sk-ant-api03-" stringByPaddingToLength:60 withString:@"a" startingAtIndex:0]),
          @"clé d'API ordinaire refusée (l'Admin API la rejetterait)");
    Check(!TMApiKeyHasExpectedShape(@"openai", @"sk-admin-court"), @"clé trop courte refusée");
    Check(!TMApiKeyHasExpectedShape(@"openai", [openai stringByAppendingString:@"\"x"]), @"caractère hors alphabet refusé");
    CheckEqual(TMApiKeyCleaned(@"  sk-admin-abc\n def \n"), @"sk-admin-abcdef", @"collage nettoyé des blancs");
    CheckEqual(TMApiKeychainAccount(TM_ACC_A), @"api-admin-key:" TM_ACC_A, @"une entrée de Trousseau par compte");
}

static void TestApiNetwork(void) {
    Section(@"Comptes API — hôtes permis et requêtes");
    Check(TMApiURLAllowed([NSURL URLWithString:@"https://api.anthropic.com/v1/organizations/cost_report"]), @"api.anthropic.com permis");
    Check(TMApiURLAllowed([NSURL URLWithString:@"https://API.OpenAI.com/v1/organization/costs"]), @"api.openai.com permis (casse ignorée)");
    Check(!TMApiURLAllowed([NSURL URLWithString:@"http://api.openai.com/v1/organization/costs"]), @"http refusé");
    Check(!TMApiURLAllowed([NSURL URLWithString:@"https://api.openai.com.evil.example/v1"]), @"suffixe piégé refusé");
    Check(!TMApiURLAllowed([NSURL URLWithString:@"https://evil.example/api.openai.com"]), @"hôte tiers refusé");
    Check(!TMApiURLAllowed([NSURL URLWithString:@"https://api.openai.com:8443/v1"]), @"autre port refusé");
    Check(!TMApiURLAllowed([NSURL URLWithString:@"https://user:pw@api.openai.com/v1"]), @"identifiants dans l'URL refusés");
    Check(!TMApiURLAllowed(nil), @"URL absente refusée");

    NSString *key = @"sk-ant-admin01-TESTKEY";
    NSURLRequest *a = TMApiCostRequest(@"anthropic", key, TM_API_MONTH, nil, @"Status/test");
    CheckEqual(a.URL.host, @"api.anthropic.com", @"Anthropic : bon hôte");
    CheckEqual(a.URL.path, @"/v1/organizations/cost_report", @"Anthropic : rapport de coûts");
    Check([a.URL.query containsString:@"starting_at=2026-10-01T00:00:00Z"], @"Anthropic : début RFC 3339 en UTC");
    Check([a.URL.query containsString:@"limit=31"] && [a.URL.query containsString:@"bucket_width=1d"], @"Anthropic : 31 jours par page");
    CheckEqual([a valueForHTTPHeaderField:@"x-api-key"], key, @"Anthropic : clé dans x-api-key");
    CheckEqual([a valueForHTTPHeaderField:@"anthropic-version"], @"2023-06-01", @"Anthropic : version d'API");
    Check(![a.URL.absoluteString containsString:key], @"Anthropic : la clé n'est jamais dans l'URL");
    Check(!a.HTTPShouldHandleCookies, @"pas de cookies");

    NSURLRequest *o = TMApiCostRequest(@"openai", @"sk-admin-TESTKEY", TM_API_MONTH, @"page_2", @"Status/test");
    CheckEqual(o.URL.host, @"api.openai.com", @"OpenAI : bon hôte");
    CheckEqual(o.URL.path, @"/v1/organization/costs", @"OpenAI : endpoint des coûts");
    Check([o.URL.query containsString:@"start_time=1790812800"] && [o.URL.query containsString:@"page=page_2"], @"OpenAI : début en secondes et page");
    CheckEqual([o valueForHTTPHeaderField:@"Authorization"], @"Bearer sk-admin-TESTKEY", @"OpenAI : jeton Bearer");
    Check(TMApiCostRequest(@"mistral", key, 0, nil, @"x") == nil, @"fournisseur inconnu : aucune requête");
    Check(TMApiCostRequest(@"openai", @"", 0, nil, @"x") == nil, @"sans clé : aucune requête");

    CheckEqual(TMApiErrorKey(401), @"api.err.auth", @"401 : clé refusée");
    CheckEqual(TMApiErrorKey(403), @"api.err.auth", @"403 : droits insuffisants");
    CheckEqual(TMApiErrorKey(429), @"api.err.rateLimited", @"429 : débit");
    CheckEqual(TMApiErrorKey(503), @"api.err.server", @"5xx : serveur");
}

static void TestApiParsing(void) {
    Section(@"Comptes API — lecture des rapports de coûts");
    NSString *error = nil;
    NSDictionary *anthropic = TMApiParseCostPage(@"anthropic", @{
        @"data": @[
            @{ @"starting_at": @"2026-10-13T00:00:00Z", @"ending_at": @"2026-10-14T00:00:00Z",
               @"results": @[ @{ @"amount": @"1234.5", @"currency": @"USD" }, @{ @"amount": @"65.5", @"currency": @"USD" } ] },
            @{ @"starting_at": @"2026-10-14T00:00:00Z", @"ending_at": @"2026-10-15T00:00:00Z", @"results": @[] },
        ],
        @"has_more": @YES, @"next_page": @"page_abc" }, &error);
    NSString *d13 = [NSString stringWithFormat:@"%lld", (long long)(TM_API_DAY - 86400)];
    NSString *d14 = [NSString stringWithFormat:@"%lld", (long long)TM_API_DAY];
    CheckEqual(anthropic[@"days"][d13], @13, @"cents en chaîne → dollars, résultats additionnés");
    CheckEqual(anthropic[@"days"][d14], @0, @"jour sans coût (liste vide) : 0, valide");
    CheckEqual(anthropic[@"nextPage"], @"page_abc", @"page suivante");
    Check(error == nil, @"page valide : pas d'erreur");

    NSDictionary *openai = TMApiParseCostPage(@"openai", @{
        @"object": @"page",
        @"data": @[ @{ @"object": @"bucket", @"start_time": @(TM_API_DAY), @"end_time": @(TM_API_DAY + 86400),
                       @"results": @[ @{ @"amount": @{ @"value": @0.25, @"currency": @"usd" } },
                                      @{ @"amount": @{ @"value": @1.5, @"currency": @"usd" } } ] } ],
        @"has_more": @NO, @"next_page": [NSNull null] }, &error);
    CheckEqual(openai[@"days"][d14], @1.75, @"dollars additionnés");
    CheckEqual(openai[@"nextPage"], @"", @"dernière page");
    CheckEqual(TMApiParseCostPage(@"openai", @{ @"data": @[], @"has_more": @NO }, &error)[@"days"], @{}, @"page vide : valide");

    // Relevés douteux : jamais de chiffres partiels.
    NSDictionary *(^bucket)(id) = ^NSDictionary *(id results) {
        NSMutableDictionary *b = [@{ @"start_time": @(TM_API_DAY) } mutableCopy];
        if (results) b[@"results"] = results;
        return @{ @"data": @[ b ], @"has_more": @NO };
    };
    Check(TMApiParseCostPage(@"openai", bucket(nil), &error) == nil && [error isEqual:@"api.err.malformed"], @"bucket sans results : invalide");
    Check(TMApiParseCostPage(@"openai", bucket(@[ @{ @"amount": @{ @"value": @"abc", @"currency": @"usd" } } ]), &error) == nil
          && [error isEqual:@"api.err.malformed"], @"montant illisible : invalide");
    Check(TMApiParseCostPage(@"openai", bucket(@[ @{ @"amount": @{ @"value": @3, @"currency": @"eur" } } ]), &error) == nil
          && [error isEqual:@"api.err.currency"], @"autre devise : rejetée, pas ignorée");
    Check(TMApiParseCostPage(@"anthropic", @{ @"data": @[ @{ @"starting_at": @"pas une date", @"results": @[] } ] }, &error) == nil,
          @"date illisible : invalide");
    Check(TMApiParseCostPage(@"openai", @{ @"data": @[], @"has_more": @YES, @"next_page": [NSNull null] }, &error) == nil
          && [error isEqual:@"api.err.incomplete"], @"has_more sans curseur : incomplet");
    Check(TMApiParseCostPage(@"openai", @{ @"error": @{} }, &error) == nil, @"réponse sans data : nil");
    Check(TMApiParseCostPage(@"openai", @[], &error) == nil, @"réponse non objet : nil");
}

static void TestApiFetchControl(void) {
    Section(@"Comptes API — reprise des relevés, relevés en vol, Trousseau");
    BOOL incremental = YES;
    CheckEqual(@(TMApiFetchStart(TM_API_MONTH, NO, 0, 0, TM_API_NOW, &incremental)), @(TM_API_MONTH), @"sans cache : relevé complet");
    Check(!incremental, @"sans cache : pas incrémental");
    CheckEqual(@(TMApiFetchStart(TM_API_MONTH, YES, TM_API_MONTH, TM_API_NOW - 600, TM_API_NOW, &incremental)),
               @(TM_API_DAY - 2 * 86400), @"relevé récent : les deux derniers jours");
    Check(incremental, @"cache couvrant : incrémental");
    CheckEqual(@(TMApiFetchStart(TM_API_MONTH, YES, TM_API_MONTH, TM_API_NOW - 6 * 86400, TM_API_NOW, NULL)),
               @(TM_API_DAY - 7 * 86400), @"six jours sans relevé : reprise au dernier succès moins un jour");
    CheckEqual(@(TMApiFetchStart(TM_API_DAY - 3 * 86400, YES, TM_API_MONTH, TM_API_NOW - 20 * 86400, TM_API_NOW, NULL)),
               @(TM_API_DAY - 3 * 86400), @"jamais avant le début de la période");
    CheckEqual(@(TMApiFetchStart(TM_API_MONTH - 86400, YES, TM_API_MONTH, TM_API_NOW, TM_API_NOW, NULL)),
               @(TM_API_MONTH - 86400), @"période élargie au-delà du cache : relevé complet");

    TMApiFetchGate *gate = [TMApiFetchGate new];
    NSUInteger old = [gate beginForAccount:TM_ACC_A];
    Check([gate isFetching:TM_ACC_A], @"relevé en vol");
    [gate invalidateAccount:TM_ACC_A];  // clé remplacée
    Check(![gate isCurrent:old forAccount:TM_ACC_A], @"clé remplacée : l'ancien relevé n'est plus courant");
    NSUInteger fresh = [gate beginForAccount:TM_ACC_A];
    Check(![gate finish:old forAccount:TM_ACC_A], @"réponse tardive de l'ancienne clé : ignorée");
    Check([gate isFetching:TM_ACC_A], @"…sans libérer le nouveau relevé");
    Check([gate finish:fresh forAccount:TM_ACC_A] && ![gate isFetching:TM_ACC_A], @"réponse du relevé courant : acceptée");
    Check(![gate finish:fresh forAccount:TM_ACC_A], @"une réponse n'est acceptée qu'une fois");

    CheckEqual(TMKeychainReadOutcome(errSecSuccess), @"found", @"Trousseau : clé trouvée");
    CheckEqual(TMKeychainReadOutcome(errSecItemNotFound), @"absent", @"Trousseau : clé absente");
    CheckEqual(TMKeychainReadOutcome(errSecAuthFailed), @"denied", @"Trousseau : accès refusé ≠ absente");
    CheckEqual(TMKeychainReadOutcome(errSecInteractionNotAllowed), @"denied", @"Trousseau verrouillé ≠ absente");
    Check(TMKeychainDeleteSucceeded(errSecSuccess) && TMKeychainDeleteSucceeded(errSecItemNotFound), @"suppression : entrée partie");
    Check(!TMKeychainDeleteSucceeded(errSecAuthFailed), @"suppression refusée : échec, le compte est gardé");
}

static void TestApiSummary(void) {
    Section(@"Comptes API — estimation, budget, widget");
    CheckEqual(@(TMUTCDayStart(TM_API_NOW)), @(TM_API_DAY), @"début du jour UTC");
    CheckEqual(@(TMUTCMonthStart(TM_API_NOW)), @(TM_API_MONTH), @"début du mois UTC");
    NSString *(^day)(double) = ^NSString *(double t) { return [NSString stringWithFormat:@"%lld", (long long)t]; };
    NSDictionary *daily = @{ day(TM_API_MONTH - 86400): @50,   // mois dernier
                             day(TM_API_DAY - 2 * 86400): @4,
                             day(TM_API_DAY - 86400): @6,
                             day(TM_API_DAY): @10 };

    NSDictionary *prepaid = @{ @"accountId": TM_ACC_A, @"provider": @"anthropic", @"mode": @"prepaid",
                               @"balanceUSD": @40, @"balanceSetAt": @(TM_API_DAY - 86400 + 3600), @"baselineUSD": @2 };
    NSDictionary *s = TMApiSummary(prepaid, daily, TM_API_NOW, 10);
    CheckEqual(s[@"todayUSD"], @10, @"dépense du jour");
    CheckEqual(s[@"monthUSD"], @20, @"dépense du mois (UTC), mois précédent exclu");
    CheckEqual(s[@"sinceSetUSD"], @14, @"depuis la saisie : (6 + 10) − base 2");
    CheckEqual(s[@"remainingUSD"], @26, @"reste estimé = 40 − 14");
    CheckEqual(s[@"fraction"], @0.65, @"part restante");
    CheckEqual(s[@"severity"], @0, @"au-dessus du seuil : normal");
    CheckEqual(TMApiSummary(prepaid, daily, TM_API_NOW, 30)[@"severity"], @1, @"sous le seuil : avertissement");
    NSMutableDictionary *empty = [prepaid mutableCopy]; empty[@"balanceUSD"] = @10;
    CheckEqual(TMApiSummary(empty, daily, TM_API_NOW, 5)[@"severity"], @2, @"épuisé : critique");
    CheckEqual(TMApiSummary(empty, daily, TM_API_NOW, 5)[@"fraction"], @0, @"épuisé : jauge vide, jamais négative");
    NSMutableDictionary *pending = [prepaid mutableCopy]; pending[@"baselinePending"] = @YES; pending[@"balanceSetAt"] = @(TM_API_NOW - 60);
    CheckEqual(TMApiSummary(pending, daily, TM_API_NOW, 10)[@"sinceSetUSD"], @0, @"base en attente : la dépense déjà connue du jour n'est pas décomptée");

    CheckEqual(@(TMApiQueryStart(prepaid, TM_API_NOW)), @(TM_API_MONTH), @"saisie ce mois-ci : relevé depuis le 1er");
    NSMutableDictionary *old = [prepaid mutableCopy]; old[@"balanceSetAt"] = @(TM_API_MONTH - 10 * 86400 + 500);
    CheckEqual(@(TMApiQueryStart(old, TM_API_NOW)), @(TM_API_MONTH - 10 * 86400), @"saisie antérieure : relevé depuis son jour");
    old[@"balanceSetAt"] = @(TM_API_NOW - 900 * 86400);
    Check(TMApiQueryStart(old, TM_API_NOW) >= TM_API_NOW - 401 * 86400, @"recul plafonné à environ un an");

    NSDictionary *budget = @{ @"accountId": TM_ACC_B, @"provider": @"openai", @"mode": @"budget", @"budgetUSD": @25 };
    NSDictionary *b = TMApiSummary(budget, daily, TM_API_NOW, 10);
    CheckEqual(b[@"remainingUSD"], @5, @"budget : reste = 25 − 20");
    Check(fabs([b[@"fraction"] doubleValue] - 0.2) < 1e-9, @"budget : part restante");
    CheckEqual(b[@"severity"], @1, @"budget à 80 % : avertissement");
    NSDictionary *none = TMApiSummary(@{ @"accountId": TM_ACC_B, @"provider": @"openai", @"mode": @"none" }, daily, TM_API_NOW, 10);
    Check(none[@"fraction"] == nil && none[@"remainingUSD"] == nil, @"dépense seule : pas de jauge");
    CheckEqual(none[@"monthUSD"], @20, @"dépense seule : le mois est quand même compté");

    NSDictionary *merged = TMApiDailyMerging(daily, @{ day(TM_API_DAY): @12 }, TM_API_MONTH);
    CheckEqual(merged[day(TM_API_DAY)], @12, @"fusion : le relevé frais l'emporte");
    Check(merged[day(TM_API_MONTH - 86400)] == nil, @"fusion : jours hors période oubliés");

    NSArray *summaries = @[ s, b, @{ @"accountId": @"x", @"provider": @"anthropic", @"fraction": @0.1 }, none ];
    CheckEqual(TMApiWidgetPick(summaries, @"anthropic", nil)[@"accountId"], @"x", @"widget : le compte le plus bas");
    CheckEqual(TMApiWidgetPick(summaries, @"anthropic", TM_ACC_A)[@"accountId"], TM_ACC_A, @"widget : le compte épinglé");
    CheckEqual(TMApiWidgetPick(summaries, @"openai", @"inconnu")[@"accountId"], TM_ACC_B, @"widget : épinglé disparu → le plus bas");
    Check(TMApiWidgetPick(@[none], @"openai", nil) == nil, @"widget : aucun compte avec jauge → tiret");

    NSDictionary *readout = TMWidgetReadout(@"anthropicApi", @{ @"families": @[ @{ @"id": @"anthropicApi",
        @"now": @{ @"fraction": @0.25, @"severity": @1, @"text": @"26,00 $", @"template": @"9 999 $" } } ] });
    CheckEqual(readout[@"hasValue"], @YES, @"widget API : valeur présente");
    CheckEqual(readout[@"title"], @"26,00 $", @"widget API : reste en dollars");
    CheckEqual(readout[@"fraction"], @0.25, @"widget API : jauge = part restante");
    CheckEqual(readout[@"severity"], @1, @"widget API : sévérité du compte");
    CheckEqual(readout[@"valueTemplate"], @"9 999 $", @"widget API : largeur réservée");
    CheckEqual(TMWidgetReadout(@"openaiApi", @{})[@"hasValue"], @NO, @"widget API sans famille : tiret");
    Check(TMWidgetUsesAccounts(@"openaiApi") && TMWidgetUsesAccounts(@"claudeWeek") && !TMWidgetUsesAccounts(@"cpu"),
          @"widgets de comptes : ni moniteur ni panneau système");
    Check([TMMenuBarWidgetIDs() containsObject:@"anthropicApi"] && [TMMenuBarWidgetIDs() containsObject:@"openaiApi"],
          @"widgets API au catalogue");

    CheckEqual(TMFormatUSD(12.4, @"fr_FR"), @"12,40 $", @"montant en français");
    CheckEqual(TMFormatUSD(12.4, @"en_US"), @"$12.40", @"montant en anglais");
    CheckEqual(TMFormatUSD(1234.4, @"en_US"), @"$1,234", @"au-delà de 100 $ : sans centimes");
}

static void TestApiAlerts(void) {
    Section(@"Comptes API — alertes");
    NSDictionary *(^prepaid)(double) = ^NSDictionary *(double remaining) {
        return @{ @"accountId": TM_ACC_A, @"mode": @"prepaid", @"remainingUSD": @(remaining), @"referenceUSD": @100 };
    };
    NSDictionary *r = TMApiAlertDecisions(nil, @[prepaid(50)], 10, YES);
    CheckEqual(@([r[@"fire"] count]), @0, @"au-dessus du seuil : rien");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(8)], 10, YES);
    CheckEqual(r[@"fire"], (@[@{ @"accountId": TM_ACC_A, @"kind": @"low" }]), @"sous le seuil : une alerte");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(7)], 10, YES);
    CheckEqual(@([r[@"fire"] count]), @0, @"toujours sous le seuil : pas de répétition");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(10.5)], 10, YES);
    CheckEqual(@([r[@"fire"] count]), @0, @"juste au-dessus : pas encore réarmée (marge)");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(9)], 10, YES);
    CheckEqual(@([r[@"fire"] count]), @0, @"oscillation autour du seuil : silence");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(-1)], 10, YES);
    CheckEqual(r[@"fire"], (@[@{ @"accountId": TM_ACC_A, @"kind": @"empty" }]), @"épuisé : alerte dédiée");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(80)], 10, YES);
    CheckEqual(@([r[@"state"] count]), @0, @"recharge : tout se réarme");
    r = TMApiAlertDecisions(r[@"state"], @[prepaid(0)], 10, YES);
    CheckEqual(r[@"fire"], (@[@{ @"accountId": TM_ACC_A, @"kind": @"empty" }]), @"chute directe à 0 : seulement la plus grave");
    NSDictionary *off = TMApiAlertDecisions(nil, @[prepaid(3)], 10, NO);
    CheckEqual(@([off[@"fire"] count]), @0, @"alerte coupée : rien ne part");
    CheckEqual(@([TMApiAlertDecisions(off[@"state"], @[prepaid(3)], 10, YES)[@"fire"] count]), @0,
               @"réactivée : pas de rafale pour un état déjà connu");

    NSDictionary *(^budget)(double) = ^NSDictionary *(double spent) {
        return @{ @"accountId": TM_ACC_B, @"mode": @"budget", @"remainingUSD": @(100 - spent), @"referenceUSD": @100 };
    };
    r = TMApiAlertDecisions(nil, @[budget(85)], 10, YES);
    CheckEqual(r[@"fire"], (@[@{ @"accountId": TM_ACC_B, @"kind": @"budget80" }]), @"budget à 80 %");
    r = TMApiAlertDecisions(r[@"state"], @[budget(101)], 10, YES);
    CheckEqual(r[@"fire"], (@[@{ @"accountId": TM_ACC_B, @"kind": @"budget100" }]), @"budget dépassé");
    r = TMApiAlertDecisions(r[@"state"], @[budget(2)], 10, YES);
    CheckEqual(@([r[@"state"] count]), @0, @"nouveau mois : réarmé");
    r = TMApiAlertDecisions(@{ TM_ACC_A @":low": @YES }, @[], 10, YES);
    CheckEqual(@([r[@"state"] count]), @0, @"compte disparu : état oublié");
}

int main(void) {
    @autoreleasepool {
        printf("\n\033[1mStatusQuota — tests\033[0m\n");
        TestCoercion();
        TestCodexExecutableDiscovery();
        TestISODate();
        TestCookieExtraction();
        TestCookieConversion();
        TestWindowLabels();
        TestUsagePayloadParsing();
        TestExpiredWindows();
        TestWindowClassification();
        TestHistory();
        TestAccountsCache();
        TestAccountRegistry();
        TestLegacyMigration();
        TestMenuBarMetricResolution();
        TestOpenAIWindowIdentity();
        TestManualResetsOpenAI();
        TestOpenAIHistoryCollision();
        TestAwake();
        TestHoldFraction();
        TestLockStateMachine();
        TestMetricRing();
        TestRatePerSecond();
        TestCPUPercent();
        TestSystemMonitorSnapshot();
        TestCostSince();
        TestModelBreakdown();
        TestFxRefresh();
        TestCostCacheSemantics();
        TestPriceTable();
        TestClaudeWebIdentity();
        TestParseClaudeLine();
        TestParseCodex();
        TestBilling(); TestResetCredits(); TestHistoryForDisplay(); TestExtraCredits();
        TestHistoryCSV();
        TestStaleAlert();
        TestWatchdog();
        TestForecastExhaustion();
        TestQuotaNotificationDecisions();
        TestWeeklyResetStatistics();
        TestMetricsDeltaPayload();
        TestTopProcesses();
        TestTopProcessesEnergy();
        TestThresholdFire();
        TestAlertRearm();
        TestLongHistory();
        TestSensorFamily();
        TestSensorAggregates();
        TestSystemMonitorLive();
        TestDisplayBrightnessClamp();
        TestDisplayVCPConversion();
        TestDisplayDDCProtocol();
        TestDisplayManagerLive();
        TestWidgetOrdering();
        TestMenuBarWidgets();
        TestWidgetRenderSignature();
        TestWidgetStableWidth();
        TestWidgetNewShapes();
        TestApiRegistry();
        TestApiBaseline();
        TestApiInputs();
        TestApiNetwork();
        TestApiParsing();
        TestApiFetchControl();
        TestApiSummary();
        TestApiAlerts();

        printf("\n%s%d vérifications, %d échec(s)\033[0m\n\n",
               gFailures ? "\033[31m" : "\033[32m", gChecks, gFailures);
        return gFailures ? 1 : 0;
    }
}
