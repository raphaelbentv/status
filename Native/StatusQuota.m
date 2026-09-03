// Implémentation de StatusQuota — voir StatusQuota.h pour le contrat et le pourquoi.
//
// Extrait de Status.m : ces fonctions ne touchent ni l'UI, ni le réseau, ni l'état applicatif, et
// sont couvertes par Tests/native-tests.m.

#import "StatusQuota.h"
#import "StatusAccounts.h"

// Accepts either a bare Cookie header value or a whole "Copy as cURL" paste, so the user never has
// to isolate the header by hand. Only the Cookie/-b value is kept; everything else is discarded.
NSString *TMExtractCookieHeader(NSString *input) {
    NSString *value = [input stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (!value.length) return @"";
    if (![value hasPrefix:@"curl"] && [value rangeOfString:@"-H "].location == NSNotFound
        && [value rangeOfString:@"-b "].location == NSNotFound) {
        return value;
    }
    // Matches -H 'Cookie: …' / -H "Cookie: …" / -b '…' / --cookie '…', quote style either way.
    NSString *pattern = @"(?:-H|--header)\\s+(['\"])\\s*[Cc]ookie:\\s*(.*?)\\1|(?:-b|--cookie)\\s+(['\"])(.*?)\\3";
    NSRegularExpression *regex = [NSRegularExpression regularExpressionWithPattern:pattern options:0 error:nil];
    NSTextCheckingResult *match = [regex firstMatchInString:value options:0 range:NSMakeRange(0, value.length)];
    if (!match) return @"";
    for (NSNumber *group in @[@2, @4]) {
        NSRange range = [match rangeAtIndex:group.unsignedIntegerValue];
        if (range.location != NSNotFound) {
            return [[value substringWithRange:range] stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        }
    }
    return @"";
}

double TMNumber(id value) {
    if ([value respondsToSelector:@selector(doubleValue)]) return [value doubleValue];
    return 0;
}

long long TMInteger(id value) {
    if ([value respondsToSelector:@selector(longLongValue)]) return [value longLongValue];
    return 0;
}

NSString *TMQuotaWindowLabel(long long minutes) {
    if (minutes == 300) return @"5 h";
    if (minutes == 10080) return @"Semaine";
    if (minutes == 1440) return @"24 h";
    if (minutes > 0 && minutes % 10080 == 0) return [NSString stringWithFormat:@"%lld sem.", minutes / 10080];
    if (minutes > 0 && minutes % 1440 == 0) return [NSString stringWithFormat:@"%lld j", minutes / 1440];
    if (minutes > 0 && minutes % 60 == 0) return [NSString stringWithFormat:@"%lld h", minutes / 60];
    if (minutes > 0) return [NSString stringWithFormat:@"%lld min", minutes];
    return @"Période";
}

NSDictionary *TMDisconnectedOpenAIAccount(NSString *error) {
    return @{
        @"connected": @NO, @"connecting": @NO, @"email": @"", @"plan": @"",
        @"windows": @[], @"availableCredits": @0, @"source": @"Codex app-server",
        @"error": error ?: @""
    };
}

NSDictionary *TMOpenAIAccountPayload(NSDictionary *account, NSDictionary *rateResponse, BOOL connecting, NSString *error) {
    BOOL connected = [account[@"type"] isEqualToString:@"chatgpt"];
    NSMutableArray *windows = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableArray *snapshots = [NSMutableArray array];
    NSDictionary *root = [rateResponse[@"rateLimits"] isKindOfClass:NSDictionary.class] ? rateResponse[@"rateLimits"] : nil;
    if (root) [snapshots addObject:root];
    NSDictionary *byID = [rateResponse[@"rateLimitsByLimitId"] isKindOfClass:NSDictionary.class] ? rateResponse[@"rateLimitsByLimitId"] : nil;
    for (NSDictionary *snapshot in byID.allValues) {
        if (![snapshot isKindOfClass:NSDictionary.class]) continue;
        NSString *limitID = [snapshot[@"limitId"] isKindOfClass:NSString.class] ? snapshot[@"limitId"] : @"";
        if (limitID.length && [limitID isEqualToString:root[@"limitId"]]) continue;
        [snapshots addObject:snapshot];
    }
    for (NSDictionary *snapshot in snapshots) {
        NSString *limitName = [snapshot[@"limitName"] isKindOfClass:NSString.class] ? snapshot[@"limitName"] : @"";
        NSString *limitID = [snapshot[@"limitId"] isKindOfClass:NSString.class] ? snapshot[@"limitId"] : @"codex";
        for (NSString *slot in @[@"primary", @"secondary"]) {
            NSDictionary *window = [snapshot[slot] isKindOfClass:NSDictionary.class] ? snapshot[slot] : nil;
            if (!window) continue;
            long long duration = TMInteger(window[@"windowDurationMins"]);
            NSString *dedupe = [NSString stringWithFormat:@"%@-%lld", limitID, duration];
            if ([seen containsObject:dedupe]) continue;
            [seen addObject:dedupe];
            NSInteger used = MAX(0, MIN(100, (NSInteger)TMInteger(window[@"usedPercent"])));
            // OpenAI expose plusieurs limites qui partagent la même durée : sans le nom, deux
            // fenêtres de 7 jours s'affichaient toutes deux « Semaine », indiscernables à l'écran.
            NSString *label = limitName.length
                ? [NSString stringWithFormat:@"%@ · %@", limitName, TMQuotaWindowLabel(duration)]
                : TMQuotaWindowLabel(duration);
            [windows addObject:@{
                // windowId identifie la limite, pas la durée. Sans lui, TMAppendHistory retombait
                // sur le libellé et les deux limites écrasaient la même clé : la moitié de la
                // donnée OpenAI disparaissait en silence à chaque relevé.
                @"windowId": dedupe,
                @"label": label, @"usedPercent": @(used), @"remainingPercent": @(100 - used),
                @"resetsAt": @(TMInteger(window[@"resetsAt"])), @"durationMinutes": @(duration),
                @"limitName": limitName, @"limitId": limitID
            }];
        }
    }
    NSDictionary *creditSummary = [rateResponse[@"rateLimitResetCredits"] isKindOfClass:NSDictionary.class] ? rateResponse[@"rateLimitResetCredits"] : nil;
    NSInteger credits = TMInteger(creditSummary[@"availableCount"]);
    return @{
        @"connected": @(connected), @"connecting": @(connecting),
        @"email": connected && [account[@"email"] isKindOfClass:NSString.class] ? account[@"email"] : @"",
        @"plan": connected && [account[@"planType"] isKindOfClass:NSString.class] ? account[@"planType"] : @"",
        @"windows": windows, @"availableCredits": @(credits), @"source": @"Codex app-server",
        @"error": error ?: @""
    };
}

NSDictionary *TMEmptyClaudeAccount(void) {
    return @{
        @"cliAvailable": @NO, @"authenticated": @NO, @"authChecking": @NO,
        @"trackingInstalled": @NO, @"trackingConfigured": @NO, @"snapshotPresent": @NO,
        @"windows": @[], @"capturedAt": @0, @"subscriptionType": @"", @"fableConfigured": @NO,
        @"liveSource": @NO, @"error": @""
    };
}

NSString *TMClaudeWindowLabel(NSString *name) {
    NSDictionary *labels = @{
        @"five_hour": @"5 h", @"seven_day": @"7 jours", @"seven_day_opus": @"7 j · Opus",
        @"seven_day_sonnet": @"7 j · Sonnet", @"seven_day_fable": @"7 j · Fable", @"overage": @"Dépassement"
    };
    NSString *label = labels[name];
    if (label) return label;
    return [[name stringByReplacingOccurrencesOfString:@"_" withString:@" "] capitalizedStringWithLocale:[NSLocale localeWithLocaleIdentifier:@"fr_FR"]];
}

NSDate *TMParseISODate(NSString *value) {
    if (![value isKindOfClass:NSString.class] || !value.length) return nil;
    static NSISO8601DateFormatter *withFraction, *plain;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        withFraction = [NSISO8601DateFormatter new];
        withFraction.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        plain = [NSISO8601DateFormatter new];
        plain.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    });
    return [withFraction dateFromString:value] ?: [plain dateFromString:value];
}

// Unofficial source: parses claude.ai's internal /api/organizations/{org}/usage response.
// Undocumented, so every field is treated as optional and unknown kinds are surfaced generically
// rather than dropped. Unlike the statusLine snapshot (which only refreshes when a terminal
// `claude` session answers), this returns every window live on each poll.
NSArray *TMClaudeWindowsFromUsagePayload(NSDictionary *payload) {
    NSArray *limits = [payload[@"limits"] isKindOfClass:NSArray.class] ? payload[@"limits"] : nil;
    if (!limits) return @[];
    NSMutableArray *windows = [NSMutableArray array];
    for (NSDictionary *entry in limits) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDate *resetsDate = TMParseISODate(entry[@"resets_at"]);
        if (!resetsDate) continue;
        NSString *kind = [entry[@"kind"] isKindOfClass:NSString.class] ? entry[@"kind"] : @"";
        NSDictionary *scope = [entry[@"scope"] isKindOfClass:NSDictionary.class] ? entry[@"scope"] : nil;
        NSDictionary *model = [scope[@"model"] isKindOfClass:NSDictionary.class] ? scope[@"model"] : nil;
        NSString *modelName = [model[@"display_name"] isKindOfClass:NSString.class] ? model[@"display_name"] : @"";

        NSString *label, *windowId;
        if ([kind isEqualToString:@"session"]) {
            label = @"5 h";
            windowId = @"five_hour";
        } else if ([kind isEqualToString:@"weekly_all"]) {
            label = @"7 jours";
            windowId = @"seven_day";
        } else if ([kind isEqualToString:@"weekly_scoped"]) {
            label = modelName.length ? [NSString stringWithFormat:@"7 j · %@", modelName] : @"7 j · modèle";
            windowId = [NSString stringWithFormat:@"seven_day_scoped_%@", modelName.length ? modelName.lowercaseString : @"unknown"];
        } else {
            if (!kind.length) continue;
            label = [kind stringByReplacingOccurrencesOfString:@"_" withString:@" "];
            windowId = kind;
        }

        double used = MAX(0, MIN(100, TMNumber(entry[@"percent"])));
        [windows addObject:@{
            @"label": label, @"windowId": windowId,
            @"usedPercent": @(used), @"remainingPercent": @(100.0 - used), @"resetsAt": @((long long)resetsDate.timeIntervalSince1970)
        }];
    }
    return windows;
}

// A window whose reset time has passed carries no usable number: the quota has since rolled over
// by an unknown amount. Drop it rather than show a stale percentage as if it were current.
NSArray *TMDropExpiredWindows(NSArray *windows) {
    long long now = (long long)NSDate.date.timeIntervalSince1970;
    NSMutableArray *result = [NSMutableArray array];
    for (NSDictionary *window in windows) {
        if (TMInteger(window[@"resetsAt"]) > now) [result addObject:window];
    }
    return result;
}

NSString *TMSupportDirectory(void) {
    // STATUS_SUPPORT_DIR laisse les tests écrire ailleurs que dans les données réelles de
    // l'utilisateur. Redéfinir HOME ne suffit pas : Foundation met le chemin en cache.
    // Même convention que STATUS_CLAUDE_STATE_DIR côté bridge Python.
    NSString *override = NSProcessInfo.processInfo.environment[@"STATUS_SUPPORT_DIR"];
    NSString *dir;
    if (override.length) {
        dir = override.stringByExpandingTildeInPath;
    } else {
        NSString *base = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
        dir = [base stringByAppendingPathComponent:@"Status"];
    }
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return dir;
}

NSString *TMHistoryPath(void) {
    return [TMSupportDirectory() stringByAppendingPathComponent:@"quota-history.json"];
}

NSString *TMAccountsCachePath(void) {
    return [TMSupportDirectory() stringByAppendingPathComponent:@"accounts-cache.json"];
}

// Ne conserve que ce qui est réellement sérialisable : un payload de compte peut porter, selon les
// chemins, des valeurs non-JSON (NSNull passe, mais on se protège). En cas de doute, on n'écrit
// rien plutôt qu'un fichier corrompu — le pire cas reste l'ancien comportement (démarrage vide).
void TMSaveAccountsCache(NSDictionary *accounts) {
    if (![accounts isKindOfClass:NSDictionary.class] || !accounts.count) return;
    if (![NSJSONSerialization isValidJSONObject:accounts]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:accounts options:0 error:nil];
    if (data) [data writeToFile:TMAccountsCachePath() atomically:YES];
}

NSDictionary *TMLoadAccountsCache(void) {
    NSData *data = [NSData dataWithContentsOfFile:TMAccountsCachePath()];
    NSDictionary *cache = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [cache isKindOfClass:NSDictionary.class] ? cache : nil;
}

NSString *TMMetricsHistoryPath(void) {
    return [TMSupportDirectory() stringByAppendingPathComponent:@"metrics-history.json"];
}

void TMSaveMetricsHistory(NSArray *rows) {
    if (![rows isKindOfClass:NSArray.class]) return;
    if (![NSJSONSerialization isValidJSONObject:rows]) return;
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    if (data) [data writeToFile:TMMetricsHistoryPath() atomically:YES];
}

NSArray *TMLoadMetricsHistory(void) {
    NSData *data = [NSData dataWithContentsOfFile:TMMetricsHistoryPath()];
    NSArray *rows = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [rows isKindOfClass:NSArray.class] ? rows : @[];
}

const NSTimeInterval TMForecastMinimumSpan = 900;

BOOL TMStaleAlertShouldFire(BOOL *wasStale, BOOL isStale) {
    BOOL fire = isStale && !*wasStale;  // uniquement le front montant
    *wasStale = isStale;
    return fire;
}

BOOL TMWatchdogShouldReload(NSInteger *failures, BOOL success, NSInteger threshold) {
    if (success) { *failures = 0; return NO; }
    (*failures)++;
    if (*failures >= threshold) { *failures = 0; return YES; }  // réarme pour ne pas boucler
    return NO;
}
  // 15 min : sous ce seuil, la pente est du bruit

BOOL TMForecastExhaustion(NSArray *history, NSString *key, NSTimeInterval resetsAt, NSTimeInterval *outAt) {
    if (!key.length) return NO;

    // 1. Ne garder que les points portant la clé — le collecteur écrit une entrée par cycle,
    //    pas forcément avec toutes les fenêtres (un fournisseur peut être déconnecté).
    NSMutableArray<NSArray<NSNumber *> *> *points = [NSMutableArray array];  // [t, valeur]
    for (NSDictionary *row in history) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *values = row[@"p"];
        if (![values isKindOfClass:NSDictionary.class]) continue;
        NSNumber *value = values[key];
        if (![value isKindOfClass:NSNumber.class]) continue;
        [points addObject:@[@(TMNumber(row[@"t"])), value]];
    }

    // 2. Repartir de la dernière réinitialisation. Une fenêtre qui se recharge fait chuter le
    //    pourcentage ; conserver l'avant donnerait une pente négative alors que la consommation
    //    peut être vive depuis. Le seuil évite de confondre une chute avec le bruit de mesure.
    NSUInteger start = 0;
    for (NSUInteger i = 1; i < points.count; i++) {
        double previous = points[i - 1][1].doubleValue, current = points[i][1].doubleValue;
        if (current < previous - 5) start = i;
    }
    if (points.count - start < 2) return NO;

    NSTimeInterval firstTime = points[start][0].doubleValue;
    NSTimeInterval lastTime = points.lastObject[0].doubleValue;
    double lastValue = points.lastObject[1].doubleValue;
    if (lastTime - firstTime < TMForecastMinimumSpan) return NO;

    // 3. Moindres carrés sur les points retenus. Une régression plutôt que le simple écart entre
    //    le premier et le dernier : un pic isolé ne doit pas décider de la prévision.
    NSUInteger n = points.count - start;
    double sumT = 0, sumV = 0, sumTV = 0, sumTT = 0;
    for (NSUInteger i = start; i < points.count; i++) {
        double t = points[i][0].doubleValue - firstTime, v = points[i][1].doubleValue;
        sumT += t; sumV += v; sumTV += t * v; sumTT += t * t;
    }
    double denominator = n * sumTT - sumT * sumT;
    if (denominator <= 0) return NO;
    double slope = (n * sumTV - sumT * sumV) / denominator;  // pourcent par seconde
    if (slope <= 0) return NO;                               // stable ou en baisse : rien à annoncer

    NSTimeInterval exhaustAt = lastTime + (100.0 - lastValue) / slope;
    if (resetsAt > 0 && exhaustAt >= resetsAt) return NO;    // tiendra jusqu'au reset
    if (outAt) *outAt = exhaustAt;
    return YES;
}

NSString *TMHistoryToCSV(NSArray *history) {
    NSMutableString *csv = [NSMutableString stringWithString:@"timestamp_unix,date_iso_utc,fenetre,pourcent\n"];
    static NSDateFormatter *iso;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        iso = [NSDateFormatter new];
        iso.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss'Z'";
        iso.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
        iso.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"];
    });
    NSArray *sorted = [history sortedArrayUsingComparator:^(NSDictionary *a, NSDictionary *b) {
        return [@(TMInteger(a[@"t"])) compare:@(TMInteger(b[@"t"]))];
    }];
    for (NSDictionary *row in sorted) {
        if (![row isKindOfClass:NSDictionary.class]) continue;
        long long t = TMInteger(row[@"t"]);
        NSString *date = [iso stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
        NSDictionary *points = [row[@"p"] isKindOfClass:NSDictionary.class] ? row[@"p"] : @{};
        // Clés triées pour un export déterministe d'un lancement à l'autre.
        for (NSString *key in [points.allKeys sortedArrayUsingSelector:@selector(compare:)]) {
            [csv appendFormat:@"%lld,%@,%@,%ld\n", t, date, key, (long)TMNumber(points[key])];
        }
    }
    return csv;
}

NSArray *TMLoadHistory(void) {
    NSData *data = [NSData dataWithContentsOfFile:TMHistoryPath()];
    NSArray *history = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [history isKindOfClass:NSArray.class] ? history : @[];
}

#pragma mark - Clés d'historique par compte

NSString *TMHistoryKey(NSString *provider, NSString *accountId, NSString *windowId) {
    if (!provider.length || !windowId.length) return @"";
    if (!accountId.length) return [NSString stringWithFormat:@"%@:%@", provider, windowId];
    return [NSString stringWithFormat:@"%@:%@:%@", provider, accountId, windowId];
}

NSString *TMHistoryKeyProvider(NSString *key) {
    NSRange colon = [key rangeOfString:@":"];
    return colon.location == NSNotFound ? @"" : [key substringToIndex:colon.location];
}

NSString *TMHistoryKeyAccountID(NSString *key) {
    NSArray *parts = [key componentsSeparatedByString:@":"];
    if (parts.count < 3) return @"";
    return TMIsAccountID(parts[1]) ? parts[1] : @"";
}

NSString *TMHistoryKeyWindowID(NSString *key) {
    NSArray *parts = [key componentsSeparatedByString:@":"];
    if (parts.count < 2) return @"";
    NSUInteger start = (parts.count >= 3 && TMIsAccountID(parts[1])) ? 2 : 1;
    NSArray *tail = [parts subarrayWithRange:NSMakeRange(start, parts.count - start)];
    return [tail componentsJoinedByString:@":"];
}

NSArray *TMMigrateHistoryKeys(NSArray *history, NSString *openaiAccountId, NSString *claudeAccountId) {
    if (![history isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id rawRow in history) {
        if (![rawRow isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = rawRow;
        NSDictionary *points = [row[@"p"] isKindOfClass:NSDictionary.class] ? row[@"p"] : @{};
        NSMutableDictionary *migrated = [NSMutableDictionary dictionary];
        for (NSString *key in points) {
            if (![key isKindOfClass:NSString.class]) continue;
            // Une clé déjà migrée porte un UUID en deuxième segment : la forme suffit à la
            // reconnaître, donc repasser sur un historique migré ne change rien.
            if (TMHistoryKeyAccountID(key).length) { migrated[key] = points[key]; continue; }
            NSString *provider = TMHistoryKeyProvider(key);
            NSString *accountId = [provider isEqualToString:TMProviderOpenAI] ? openaiAccountId
                                : [provider isEqualToString:TMProviderClaude] ? claudeAccountId : nil;
            if (!accountId.length) { migrated[key] = points[key]; continue; }
            migrated[TMHistoryKey(provider, accountId, TMHistoryKeyWindowID(key))] = points[key];
        }
        NSMutableDictionary *nextRow = [row mutableCopy];
        nextRow[@"p"] = migrated;
        [out addObject:nextRow];
    }
    return out;
}

NSArray *TMHistoryDroppingAccount(NSArray *history, NSString *accountId) {
    if (![history isKindOfClass:NSArray.class] || !accountId.length) return history ?: @[];
    NSMutableArray *out = [NSMutableArray array];
    for (id rawRow in history) {
        if (![rawRow isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *row = rawRow;
        NSDictionary *points = [row[@"p"] isKindOfClass:NSDictionary.class] ? row[@"p"] : @{};
        NSMutableDictionary *kept = [NSMutableDictionary dictionary];
        for (NSString *key in points) {
            if ([TMHistoryKeyAccountID(key) isEqualToString:accountId]) continue;
            kept[key] = points[key];
        }
        // Une rangée vidée de tous ses points ne dit plus rien : la garder ferait un trou dans les
        // courbes des autres comptes, qui y liraient un instant sans mesure.
        if (!kept.count) continue;
        NSMutableDictionary *nextRow = [row mutableCopy];
        nextRow[@"p"] = kept;
        [out addObject:nextRow];
    }
    return out;
}

#pragma mark - Métrique de la barre des menus

BOOL TMWindowMatchesKind(NSDictionary *window, NSString *kind) {
    if ([kind isEqualToString:@"session"]) return TMWindowIsSession(window);
    if ([kind isEqualToString:@"weekly"]) return TMWindowIsWeekly(window) && !TMWindowIsScopedWeekly(window);
    if ([kind isEqualToString:@"weekly-fable"]) return TMWindowIsScopedWeekly(window);
    return NO;
}

NSString *TMPinnedMetricForAccount(NSString *provider, NSString *accountId, NSString *kind) {
    return [NSString stringWithFormat:@"acct:%@:%@:%@", provider, accountId, kind];
}

// Étiquette courte affichée à côté de l'icône quand la fenêtre montrée peut changer toute seule.
static NSString *TMShortLabelForKind(NSString *provider, NSString *kind) {
    if ([provider isEqualToString:TMProviderOpenAI]) return @"AI sem";
    if ([kind isEqualToString:@"session"]) return @"C 5h";
    if ([kind isEqualToString:@"weekly-fable"]) return @"C Fable";
    return @"C sem";
}

// Meilleur (= plus consommé) candidat parmi les comptes retenus par `filter`, pour un genre donné.
static NSDictionary *TMBestForKind(NSArray *accounts, NSString *kind,
                                   BOOL (^filter)(NSDictionary *account)) {
    NSDictionary *best = nil;
    double bestValue = -1;
    for (NSDictionary *account in accounts) {
        if (![account isKindOfClass:NSDictionary.class]) continue;
        if (filter && !filter(account)) continue;
        NSArray *windows = [account[@"windows"] isKindOfClass:NSArray.class] ? account[@"windows"] : @[];
        for (NSDictionary *window in windows) {
            if (![window isKindOfClass:NSDictionary.class] || !TMWindowMatchesKind(window, kind)) continue;
            double used = TMNumber(window[@"usedPercent"]);
            if (used <= bestValue) continue;
            bestValue = used;
            NSString *provider = [account[@"provider"] isKindOfClass:NSString.class] ? account[@"provider"] : @"";
            best = @{
                @"usedPercent": @(used), @"provider": provider,
                @"accountId": [account[@"accountId"] isKindOfClass:NSString.class] ? account[@"accountId"] : @"",
                @"label": [account[@"label"] isKindOfClass:NSString.class] ? account[@"label"] : @"",
                @"kind": kind, @"shortLabel": TMShortLabelForKind(provider, kind)
            };
        }
    }
    return best;
}

static NSDictionary *TMAggregate(NSArray *accounts, NSString *provider, NSString *kind) {
    NSDictionary *best = TMBestForKind(accounts, kind, ^BOOL(NSDictionary *account) {
        return [account[@"provider"] isEqualToString:provider];
    });
    if (!best) return nil;
    NSMutableDictionary *out = [best mutableCopy];
    out[@"aggregated"] = @YES;
    return out;
}

NSDictionary *TMResolveMenuBarMetric(NSString *metric, NSArray *accounts) {
    if (![accounts isKindOfClass:NSArray.class]) accounts = @[];
    NSString *value = metric.length ? metric : @"claude:weekly";

    if ([value hasPrefix:@"acct:"]) {
        NSArray *parts = [value componentsSeparatedByString:@":"];
        if (parts.count >= 4) {
            NSString *provider = parts[1], *accountId = parts[2];
            NSString *kind = [[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)]
                              componentsJoinedByString:@":"];
            NSDictionary *pinned = TMBestForKind(accounts, kind, ^BOOL(NSDictionary *account) {
                return [account[@"accountId"] isEqualToString:accountId];
            });
            if (pinned) return pinned;
            // Compte supprimé, ou qui n'a pas encore de fenêtre : l'agrégat de son fournisseur dit
            // encore quelque chose de vrai, là où un tiret permanent ne dirait rien.
            return TMAggregate(accounts, provider, kind);
        }
        return nil;
    }

    NSArray *parts = [value componentsSeparatedByString:@":"];
    if (parts.count >= 2) {
        NSString *provider = parts[0];
        NSString *kind = [[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                          componentsJoinedByString:@":"];
        return TMAggregate(accounts, provider, kind);
    }

    // « lowest » : la marge la plus faible, donc le pourcentage consommé le plus élevé. Fenêtres
    // générales seulement — les sous-quotas scoped (Fable) ne pilotent aucun chiffre agrégé, même
    // règle que le héros du tableau de bord.
    NSDictionary *best = nil;
    for (NSString *kind in @[@"session", @"weekly"]) {
        NSDictionary *candidate = TMBestForKind(accounts, kind, nil);
        if (candidate && (!best || TMNumber(candidate[@"usedPercent"]) > TMNumber(best[@"usedPercent"]))) {
            best = candidate;
        }
    }
    return best;
}

BOOL TMHistoryKeyMatchesMetric(NSString *key, NSString *metric) {
    NSString *windowId = TMHistoryKeyWindowID(key);
    NSString *provider = TMHistoryKeyProvider(key);
    BOOL (^windowMatchesKind)(NSString *) = ^BOOL(NSString *kind) {
        if ([kind isEqualToString:@"session"]) return [windowId isEqualToString:@"five_hour"];
        if ([kind isEqualToString:@"weekly-fable"]) return [windowId hasPrefix:@"seven_day_scoped"];
        if ([kind isEqualToString:@"weekly"]) {
            if ([provider isEqualToString:TMProviderOpenAI]) return YES;
            return [windowId isEqualToString:@"seven_day"];
        }
        return NO;
    };

    if ([metric hasPrefix:@"acct:"]) {
        NSArray *parts = [metric componentsSeparatedByString:@":"];
        if (parts.count < 4) return NO;
        if (![TMHistoryKeyAccountID(key) isEqualToString:parts[2]]) return NO;
        return windowMatchesKind([[parts subarrayWithRange:NSMakeRange(3, parts.count - 3)]
                                  componentsJoinedByString:@":"]);
    }

    NSArray *parts = [metric componentsSeparatedByString:@":"];
    if (parts.count >= 2) {
        if (![provider isEqualToString:parts[0]]) return NO;
        return windowMatchesKind([[parts subarrayWithRange:NSMakeRange(1, parts.count - 1)]
                                  componentsJoinedByString:@":"]);
    }
    // « lowest » : toutes les fenêtres générales.
    return ![windowId containsString:@"scoped"];
}

#pragma mark - Historique

// Appends one sample per account window to a rolling on-disk series (max ~2000 points ≈ a week at
// 5-min cadence). Nothing here is a secret: only window ids and used percentages.
NSArray *TMAppendHistory(NSArray *pairs, long long now) {
    NSMutableDictionary *points = [NSMutableDictionary dictionary];
    for (NSArray *pair in pairs) {
        if (![pair isKindOfClass:NSArray.class] || pair.count < 3) continue;
        NSString *provider = pair[0], *accountId = pair[1];
        NSArray *windows = [pair[2] isKindOfClass:NSArray.class] ? pair[2] : @[];
        for (NSDictionary *w in windows) {
            if (![w isKindOfClass:NSDictionary.class]) continue;
            // windowId identifie la limite, pas la durée : sans lui deux limites OpenAI écrasaient
            // la même clé et la moitié de la donnée disparaissait en silence.
            NSString *wid = [w[@"windowId"] isKindOfClass:NSString.class] ? w[@"windowId"] : w[@"label"];
            if (![wid isKindOfClass:NSString.class] || !wid.length) continue;
            points[TMHistoryKey(provider, accountId, wid)] = @((long)(TMNumber(w[@"usedPercent"]) + 0.5));
        }
    }
    if (!points.count) return TMLoadHistory();

    NSMutableArray *history = [TMLoadHistory() mutableCopy];
    NSDictionary *last = history.lastObject;
    // Coalesce: don't record a new row if <2 min since the previous one (double refresh, wake, etc.).
    if (![last isKindOfClass:NSDictionary.class] || now - TMInteger(last[@"t"]) >= 120) {
        [history addObject:@{@"t": @(now), @"p": points}];
        while (history.count > 2000) [history removeObjectAtIndex:0];
        NSData *data = [NSJSONSerialization dataWithJSONObject:history options:0 error:nil];
        [data writeToFile:TMHistoryPath() atomically:YES];
    }
    return history;
}

// Turns a pasted "k=v; k2=v2" header into cookies for the WKWebView store. Only the name/value
// pairs are used; everything else about the paste is discarded.
//
// Cloudflare's own cookies are deliberately skipped: cf_clearance is bound to the IP and
// User-Agent that earned it and expires within hours, so re-seeding the pasted (stale) copy on
// every launch would clobber the fresh one WebKit earns by solving the challenge itself.
NSArray<NSHTTPCookie *> *TMCookiesFromHeader(NSString *header) {
    NSMutableArray *cookies = [NSMutableArray array];
    for (NSString *pair in [header componentsSeparatedByString:@";"]) {
        NSString *trimmed = [pair stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
        NSRange equals = [trimmed rangeOfString:@"="];
        if (equals.location == NSNotFound || equals.location == 0) continue;
        NSString *name = [trimmed substringToIndex:equals.location];
        NSString *value = [trimmed substringFromIndex:equals.location + 1];
        if (!name.length || !value.length) continue;
        if ([name hasPrefix:@"cf_"] || [name hasPrefix:@"__cf"]) continue;
        NSHTTPCookie *cookie = [NSHTTPCookie cookieWithProperties:@{
            NSHTTPCookieName: name,
            NSHTTPCookieValue: value,
            NSHTTPCookieDomain: @".claude.ai",
            NSHTTPCookiePath: @"/",
            NSHTTPCookieSecure: @"TRUE",
            NSHTTPCookieExpires: [NSDate dateWithTimeIntervalSinceNow:60 * 60 * 24 * 365]
        }];
        if (cookie) [cookies addObject:cookie];
    }
    return cookies;
}

NSDictionary *TMQuotaNotificationDecisions(NSDictionary *state, NSArray *pairs,
                                           NSArray<NSNumber *> *levels, BOOL weeklyResets,
                                           NSTimeInterval now) {
    NSMutableDictionary *next = [state mutableCopy] ?: [NSMutableDictionary dictionary];
    NSMutableArray *events = [NSMutableArray array];

    // Purge : chaque clé de seuil porte l'heure de reset de sa période ; une période passée ne
    // reviendra pas, sa clé non plus — l'état ne peut donc pas croître sans borne.
    for (NSString *key in next.allKeys) {
        if (![key hasPrefix:@"th:"]) continue;
        NSRange at = [key rangeOfString:@"@" options:NSBackwardsSearch];
        if (at.location != NSNotFound && [key substringFromIndex:at.location + 1].longLongValue <= (long long)now)
            [next removeObjectForKey:key];
    }

    for (NSArray *pair in pairs) {
        if (![pair isKindOfClass:NSArray.class] || pair.count < 2) continue;
        NSString *provider = pair[0];
        for (NSDictionary *window in pair[1]) {
            if (![window isKindOfClass:NSDictionary.class]) continue;
            NSString *identifier = [window[@"windowId"] isKindOfClass:NSString.class] ? window[@"windowId"]
                                 : ([window[@"label"] isKindOfClass:NSString.class] ? window[@"label"] : nil);
            long long resetsAt = TMInteger(window[@"resetsAt"]);
            if (!identifier.length || resetsAt <= 0) continue;
            double used = TMNumber(window[@"usedPercent"]);
            NSString *label = [window[@"label"] isKindOfClass:NSString.class] ? window[@"label"] : identifier;

            // Seuils : le plus haut niveau atteint, notifié une seule fois par niveau et par
            // période — la clé inclut resetsAt, une nouvelle période réarme d'elle-même.
            if (levels.count) {
                NSString *thresholdKey = [NSString stringWithFormat:@"th:%@:%@@%lld", provider, identifier, resetsAt];
                NSInteger reached = 0;
                for (NSNumber *level in levels)
                    if (used >= level.doubleValue) reached = MAX(reached, level.integerValue);
                if (reached > [next[thresholdKey] integerValue]) {
                    next[thresholdKey] = @(reached);
                    [events addObject:@{ @"kind": @"threshold", @"provider": provider, @"label": label,
                                         @"level": @(reached), @"usedPercent": @(used), @"resetsAt": @(resetsAt) }];
                }
            }

            // Réinitialisations : hebdo seulement — les fenêtres session tournent plusieurs fois
            // par jour. Deux signaux, car les fournisseurs ne préviennent pas de la même façon :
            //   — resetsAt qui avance : le roulement ordinaire, en fin de période ou anticipé ;
            //   — le pourcentage qui s'effondre (≥ 25 % → ≤ 5 %) à resetsAt inchangé : OpenAI
            //     recharge parfois un compteur en plein milieu de semaine sans toucher à la date.
            // Un pourcentage encore haut à l'arrivée d'une nouvelle période signale des données
            // mêlées (deux sources) : l'état avance, la notification se tait. Et une seule
            // notification par période (clé rstfired) : deux sources qui oscillent — l'une figée
            // haute, l'autre en direct basse — ne doivent pas mitrailler.
            if (TMWindowIsWeekly(window)) {
                NSString *resetKey = [NSString stringWithFormat:@"reset:%@:%@", provider, identifier];
                NSString *usedKey = [NSString stringWithFormat:@"used:%@:%@", provider, identifier];
                NSString *firedKey = [NSString stringWithFormat:@"rstfired:%@:%@", provider, identifier];
                long long known = [next[resetKey] longLongValue];
                NSNumber *previousUsed = [next[usedKey] isKindOfClass:NSNumber.class] ? next[usedKey] : nil;
                // Le roulement exige une baisse corroborante : la fenêtre hebdo d'OpenAI est
                // GLISSANTE — resetsAt dérive au fil de l'activité (+37 h observées entre deux
                // relevés) sans qu'aucun compteur ne se recharge. La date qui avance seule ne
                // prouve donc rien ; un compteur qui retombe, si. Corollaire assumé : une semaine
                // restée légère (< 20 points consommés) tourne sans notification — rien ne
                // contraignait, il n'y a rien à annoncer.
                BOOL rolled = known > 0 && resetsAt > known && used < 50
                    && previousUsed && previousUsed.doubleValue - used >= 20;
                BOOL collapsed = previousUsed && previousUsed.doubleValue >= 25 && used <= 5;
                BOOL alreadyFired = [next[firedKey] longLongValue] == resetsAt;
                if (weeklyResets && (rolled || collapsed) && !alreadyFired) {
                    next[firedKey] = @(resetsAt);
                    [events addObject:@{ @"kind": @"reset", @"provider": provider, @"label": label,
                                         @"usedPercent": @(used), @"resetsAt": @(resetsAt) }];
                }
                if (resetsAt > known) next[resetKey] = @(resetsAt);
                next[usedKey] = @(used);
            }
        }
    }
    return @{ @"events": events, @"state": next };
}

BOOL TMWindowIsSession(NSDictionary *window) {
    NSString *windowId = [window[@"windowId"] isKindOfClass:NSString.class] ? window[@"windowId"] : @"";
    NSString *label = [window[@"label"] isKindOfClass:NSString.class] ? window[@"label"] : @"";
    long long duration = TMInteger(window[@"durationMinutes"]);
    if ([windowId isEqualToString:@"five_hour"]) return YES;
    if (duration == 300) return YES;
    return [label isEqualToString:@"5 h"];
}

BOOL TMWindowIsWeekly(NSDictionary *window) {
    NSString *windowId = [window[@"windowId"] isKindOfClass:NSString.class] ? window[@"windowId"] : @"";
    NSString *label = [window[@"label"] isKindOfClass:NSString.class] ? window[@"label"] : @"";
    long long duration = TMInteger(window[@"durationMinutes"]);
    if ([windowId isEqualToString:@"overage"]) return NO;
    if ([windowId hasPrefix:@"seven_day"]) return YES;
    if (duration == 10080) return YES;
    return [label isEqualToString:@"Semaine"] || [label isEqualToString:@"7 jours"];
}

BOOL TMWindowIsScopedWeekly(NSDictionary *window) {
    NSString *windowId = [window[@"windowId"] isKindOfClass:NSString.class] ? window[@"windowId"] : @"";
    return TMWindowIsWeekly(window) && [windowId containsString:@"scoped"];
}

BOOL TMMaxUsedPercent(NSArray<NSArray *> *windowArrays, BOOL (^predicate)(NSDictionary *window), double *outValue) {
    BOOL found = NO;
    double best = 0;
    for (NSArray *windows in windowArrays) {
        for (NSDictionary *window in windows) {
            if (![window isKindOfClass:NSDictionary.class] || !predicate(window)) continue;
            double used = TMNumber(window[@"usedPercent"]);
            if (!found || used > best) { best = used; found = YES; }
        }
    }
    if (found && outValue) *outValue = best;
    return found;
}
