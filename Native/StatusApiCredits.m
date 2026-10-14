#import "StatusApiCredits.h"

NSString *const TMApiProviderAnthropic = @"anthropic";
NSString *const TMApiProviderOpenAI = @"openai";
NSString *const TMApiAccountsDefaultsKey = @"apiAccounts";
const NSInteger TMMaxApiAccountsPerProvider = 5;

static NSString *const TMApiModeNone = @"none";
static NSString *const TMApiModePrepaid = @"prepaid";
static NSString *const TMApiModeBudget = @"budget";
// Au-delà, une saisie est plus probablement une faute de frappe qu'un solde.
static const double TMApiMaxAmount = 10000000;
// Garde-fou : un solde saisi il y a plus d'un an ne justifie pas de relire toute l'année à chaque
// relevé. Les coûts plus anciens sont ignorés (l'estimation devient optimiste, à ressaisir).
static const NSTimeInterval TMApiMaxLookback = 400 * 86400;

static NSString *TMStr(id value) { return [value isKindOfClass:NSString.class] ? value : @""; }

// NAN pour tout ce qui n'est pas un nombre fini : les préférences peuvent avoir été bricolées.
static double TMDbl(id value) {
    if (![value isKindOfClass:NSNumber.class]) return NAN;
    double v = [value doubleValue];
    return isfinite(v) ? v : NAN;
}

static BOOL TMKnownApiProvider(NSString *provider) {
    return [provider isEqualToString:TMApiProviderAnthropic] || [provider isEqualToString:TMApiProviderOpenAI];
}

static BOOL TMIsUUID(NSString *value) {
    return [value isKindOfClass:NSString.class] && value.length == 36 && [[NSUUID alloc] initWithUUIDString:value];
}

#pragma mark - Registre

NSArray<NSDictionary *> *TMNormalizeApiRegistry(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *kept = [NSMutableArray array];
    NSMutableSet *seen = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];
    for (id entry in (NSArray *)raw) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSString *accountId = TMStr(entry[@"accountId"]), *provider = TMStr(entry[@"provider"]);
        if (!TMIsUUID(accountId) || !TMKnownApiProvider(provider) || [seen containsObject:accountId]) continue;
        NSInteger used = counts[provider].integerValue;
        if (used >= TMMaxApiAccountsPerProvider) continue;
        counts[provider] = @(used + 1);
        [seen addObject:accountId];

        double balance = TMDbl(entry[@"balanceUSD"]), setAt = TMDbl(entry[@"balanceSetAt"]);
        double baseline = TMDbl(entry[@"baselineUSD"]), budget = TMDbl(entry[@"budgetUSD"]);
        NSMutableDictionary *account = [@{ @"accountId": accountId, @"provider": provider,
                                           @"label": TMStr(entry[@"label"]) } mutableCopy];
        BOOL hasBalance = !isnan(balance) && balance >= 0 && !isnan(setAt) && setAt > 0;
        BOOL hasBudget = !isnan(budget) && budget > 0;
        if (hasBalance) {
            account[@"balanceUSD"] = @(balance);
            account[@"balanceSetAt"] = @(setAt);
            account[@"baselineUSD"] = @(!isnan(baseline) && baseline > 0 ? baseline : 0);
            account[@"baselinePending"] = @([entry[@"baselinePending"] isKindOfClass:NSNumber.class]
                                            && [entry[@"baselinePending"] boolValue]);
            account[@"baselineApprox"] = @([entry[@"baselineApprox"] isKindOfClass:NSNumber.class]
                                           && [entry[@"baselineApprox"] boolValue]);
        }
        if (hasBudget) account[@"budgetUSD"] = @(budget);
        // Le solde et le budget restent mémorisés quand on change de mode : revenir en arrière ne
        // demande pas de tout ressaisir. Le mode, lui, n'est retenu que si sa valeur existe.
        NSString *mode = TMStr(entry[@"mode"]);
        if ([mode isEqualToString:TMApiModePrepaid] && hasBalance) account[@"mode"] = TMApiModePrepaid;
        else if ([mode isEqualToString:TMApiModeBudget] && hasBudget) account[@"mode"] = TMApiModeBudget;
        else account[@"mode"] = TMApiModeNone;
        [kept addObject:account];
    }
    return kept;
}

NSDictionary *TMApiAccountWithID(NSArray *registry, NSString *accountId) {
    if (!accountId.length) return nil;
    for (NSDictionary *account in TMNormalizeApiRegistry(registry))
        if ([account[@"accountId"] isEqualToString:accountId]) return account;
    return nil;
}

NSArray<NSDictionary *> *TMApiAccountsForProvider(NSArray *registry, NSString *provider) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeApiRegistry(registry))
        if ([account[@"provider"] isEqualToString:provider]) [matches addObject:account];
    return matches;
}

NSString *TMApiAccountDisplayLabel(NSDictionary *account, NSInteger indexInProvider) {
    NSString *label = [TMStr(account[@"label"]) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    if (label.length) return label;
    NSString *name = [TMStr(account[@"provider"]) isEqualToString:TMApiProviderOpenAI] ? @"OpenAI API" : @"Anthropic API";
    return [NSString stringWithFormat:@"%@ %ld", name, (long)(indexInProvider + 1)];
}

NSArray *TMApiRegistryAdding(NSArray *registry, NSString *provider, NSString *accountId) {
    NSArray *current = TMNormalizeApiRegistry(registry);
    if (!TMKnownApiProvider(provider) || !TMIsUUID(accountId) || TMApiAccountWithID(current, accountId)) return nil;
    if ((NSInteger)TMApiAccountsForProvider(current, provider).count >= TMMaxApiAccountsPerProvider) return nil;
    return TMNormalizeApiRegistry([current arrayByAddingObject:@{ @"accountId": accountId, @"provider": provider,
                                                                  @"label": @"", @"mode": TMApiModeNone }]);
}

NSArray *TMApiRegistryRemoving(NSArray *registry, NSString *accountId) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeApiRegistry(registry))
        if (![account[@"accountId"] isEqualToString:accountId]) [next addObject:account];
    return next;
}

// Applique `change` au seul compte visé, puis renormalise.
static NSArray *TMApiRegistryChanging(NSArray *registry, NSString *accountId, void (^change)(NSMutableDictionary *)) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeApiRegistry(registry)) {
        if (![account[@"accountId"] isEqualToString:accountId]) { [next addObject:account]; continue; }
        NSMutableDictionary *updated = [account mutableCopy];
        change(updated);
        [next addObject:updated];
    }
    return TMNormalizeApiRegistry(next);
}

NSArray *TMApiRegistrySettingLabel(NSArray *registry, NSString *accountId, NSString *label) {
    NSString *clean = [TMStr(label) stringByTrimmingCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) { a[@"label"] = clean; });
}

NSArray *TMApiRegistrySettingBalance(NSArray *registry, NSString *accountId, double balanceUSD,
                                     NSTimeInterval now, double provisionalBaselineUSD) {
    if (!isfinite(balanceUSD) || balanceUSD < 0 || balanceUSD > TMApiMaxAmount) return TMNormalizeApiRegistry(registry);
    double provisional = isfinite(provisionalBaselineUSD) && provisionalBaselineUSD > 0 ? provisionalBaselineUSD : 0;
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) {
        a[@"mode"] = TMApiModePrepaid;
        a[@"balanceUSD"] = @(balanceUSD);
        a[@"balanceSetAt"] = @(now);
        a[@"baselineUSD"] = @(provisional);
        a[@"baselinePending"] = @YES;
        a[@"baselineApprox"] = @NO;
    });
}

NSArray *TMApiRegistryAddingCredit(NSArray *registry, NSString *accountId, double amountUSD) {
    if (!isfinite(amountUSD) || amountUSD <= 0 || amountUSD > TMApiMaxAmount) return TMNormalizeApiRegistry(registry);
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) {
        if (![a[@"mode"] isEqualToString:TMApiModePrepaid]) return;
        a[@"balanceUSD"] = @([a[@"balanceUSD"] doubleValue] + amountUSD);
    });
}

NSArray *TMApiRegistrySettingBudget(NSArray *registry, NSString *accountId, double budgetUSD) {
    if (!isfinite(budgetUSD) || budgetUSD <= 0 || budgetUSD > TMApiMaxAmount) return TMNormalizeApiRegistry(registry);
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) {
        a[@"mode"] = TMApiModeBudget;
        a[@"budgetUSD"] = @(budgetUSD);
    });
}

NSArray *TMApiRegistryClearingMode(NSArray *registry, NSString *accountId) {
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) { a[@"mode"] = TMApiModeNone; });
}

static NSString *TMDayKey(NSTimeInterval t) {
    return [NSString stringWithFormat:@"%lld", (long long)TMUTCDayStart(t)];
}

NSArray *TMApiRegistryResolvingBaseline(NSArray *registry, NSString *accountId,
                                        NSDictionary<NSString *, NSNumber *> *daily, NSTimeInterval now) {
    return TMApiRegistryChanging(registry, accountId, ^(NSMutableDictionary *a) {
        if (![a[@"baselinePending"] boolValue]) return;
        NSTimeInterval setAt = [a[@"balanceSetAt"] doubleValue];
        a[@"baselinePending"] = @NO;
        if (TMUTCDayStart(setAt) == TMUTCDayStart(now)) {
            double spent = TMDbl(daily[TMDayKey(setAt)]);
            a[@"baselineUSD"] = @(!isnan(spent) && spent > 0 ? spent : 0);
            a[@"baselineApprox"] = @NO;
        } else {
            a[@"baselineApprox"] = @YES;  // jour de saisie fini avant tout relevé : base provisoire
        }
    });
}

#pragma mark - Saisies

BOOL TMParseUSDAmount(NSString *text, double *outValue) {
    if (![text isKindOfClass:NSString.class]) return NO;
    NSMutableString *s = [text mutableCopy];
    for (NSString *noise in @[@"USD", @"usd", @"US", @"$", @" ", @" ", @" ", @"'", @"’", @"\t", @"\n"])
        [s replaceOccurrencesOfString:noise withString:@"" options:0 range:NSMakeRange(0, s.length)];
    if (!s.length) return NO;
    NSRange lastComma = [s rangeOfString:@"," options:NSBackwardsSearch];
    NSRange lastDot = [s rangeOfString:@"." options:NSBackwardsSearch];
    if (lastComma.location != NSNotFound && lastDot.location != NSNotFound) {
        // Les deux séparateurs : le dernier est la décimale, l'autre groupe les milliers.
        BOOL commaIsDecimal = lastComma.location > lastDot.location;
        NSString *grouping = commaIsDecimal ? @"." : @",";
        [s replaceOccurrencesOfString:grouping withString:@"" options:0 range:NSMakeRange(0, s.length)];
        if (commaIsDecimal) [s replaceOccurrencesOfString:@"," withString:@"." options:0 range:NSMakeRange(0, s.length)];
    } else if (lastComma.location != NSNotFound) {
        // Virgule seule : décimale française (« 12,5 », « 12,50 »), sinon séparateur de milliers.
        NSUInteger commas = [s componentsSeparatedByString:@","].count - 1;
        NSUInteger after = s.length - lastComma.location - 1;
        if (commas == 1 && after >= 1 && after <= 2)
            [s replaceOccurrencesOfString:@"," withString:@"." options:0 range:NSMakeRange(0, s.length)];
        else
            [s replaceOccurrencesOfString:@"," withString:@"" options:0 range:NSMakeRange(0, s.length)];
    } else if ([s componentsSeparatedByString:@"."].count > 2) {
        [s replaceOccurrencesOfString:@"." withString:@"" options:0 range:NSMakeRange(0, s.length)];
    }
    NSRegularExpression *shape = [NSRegularExpression regularExpressionWithPattern:@"^[0-9]+(\\.[0-9]+)?$" options:0 error:nil];
    if (![shape firstMatchInString:s options:0 range:NSMakeRange(0, s.length)]) return NO;
    double value = s.doubleValue;
    if (!isfinite(value) || value < 0 || value > TMApiMaxAmount) return NO;
    if (outValue) *outValue = value;
    return YES;
}

NSString *TMApiKeyCleaned(NSString *raw) {
    if (![raw isKindOfClass:NSString.class]) return @"";
    NSArray *parts = [raw componentsSeparatedByCharactersInSet:NSCharacterSet.whitespaceAndNewlineCharacterSet];
    return [parts componentsJoinedByString:@""];
}

BOOL TMApiKeyHasExpectedShape(NSString *provider, NSString *key) {
    if (![key isKindOfClass:NSString.class] || key.length < 20 || key.length > 512) return NO;
    NSString *prefix = [provider isEqualToString:TMApiProviderAnthropic] ? @"sk-ant-admin"
                     : [provider isEqualToString:TMApiProviderOpenAI] ? @"sk-admin-" : nil;
    if (!prefix || ![key hasPrefix:prefix]) return NO;
    NSCharacterSet *allowed = [NSCharacterSet characterSetWithCharactersInString:
        @"abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_"];
    return [key rangeOfCharacterFromSet:allowed.invertedSet].location == NSNotFound;
}

NSString *TMApiKeychainAccount(NSString *accountId) {
    return [NSString stringWithFormat:@"api-admin-key:%@", accountId ?: @""];
}

#pragma mark - Réseau

BOOL TMApiURLAllowed(NSURL *url) {
    if (![url isKindOfClass:NSURL.class]) return NO;
    if (![url.scheme.lowercaseString isEqualToString:@"https"]) return NO;
    if (url.user.length || url.password.length) return NO;
    if (url.port && url.port.integerValue != 443) return NO;
    NSString *host = url.host.lowercaseString;
    return [host isEqualToString:@"api.anthropic.com"] || [host isEqualToString:@"api.openai.com"];
}

static NSString *TMISO8601UTC(NSTimeInterval t) {
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    formatter.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime;
    return [formatter stringFromDate:[NSDate dateWithTimeIntervalSince1970:t]];
}

NSMutableURLRequest *TMApiCostRequest(NSString *provider, NSString *key, NSTimeInterval start,
                                      NSString *page, NSString *userAgent) {
    if (!key.length) return nil;
    NSURLComponents *components = [NSURLComponents new];
    components.scheme = @"https";
    NSMutableArray<NSURLQueryItem *> *query = [NSMutableArray array];
    if ([provider isEqualToString:TMApiProviderAnthropic]) {
        components.host = @"api.anthropic.com";
        components.path = @"/v1/organizations/cost_report";
        [query addObject:[NSURLQueryItem queryItemWithName:@"starting_at" value:TMISO8601UTC(start)]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"bucket_width" value:@"1d"]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"31"]];  // maximum documenté
    } else if ([provider isEqualToString:TMApiProviderOpenAI]) {
        components.host = @"api.openai.com";
        components.path = @"/v1/organization/costs";
        [query addObject:[NSURLQueryItem queryItemWithName:@"start_time" value:[NSString stringWithFormat:@"%lld", (long long)start]]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"bucket_width" value:@"1d"]];
        [query addObject:[NSURLQueryItem queryItemWithName:@"limit" value:@"180"]];  // maximum documenté
    } else {
        return nil;
    }
    if (page.length) [query addObject:[NSURLQueryItem queryItemWithName:@"page" value:page]];
    components.queryItems = query;
    NSURL *url = components.URL;
    if (!TMApiURLAllowed(url)) return nil;

    NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:url
                                                           cachePolicy:NSURLRequestReloadIgnoringLocalCacheData
                                                       timeoutInterval:30];
    request.HTTPMethod = @"GET";
    request.HTTPShouldHandleCookies = NO;
    [request setValue:@"application/json" forHTTPHeaderField:@"Accept"];
    [request setValue:userAgent forHTTPHeaderField:@"User-Agent"];
    if ([provider isEqualToString:TMApiProviderAnthropic]) {
        [request setValue:key forHTTPHeaderField:@"x-api-key"];
        [request setValue:@"2023-06-01" forHTTPHeaderField:@"anthropic-version"];
    } else {
        [request setValue:[@"Bearer " stringByAppendingString:key] forHTTPHeaderField:@"Authorization"];
    }
    return request;
}

static NSTimeInterval TMParseISODate(NSString *text) {
    if (![text isKindOfClass:NSString.class]) return NAN;
    NSISO8601DateFormatter *formatter = [NSISO8601DateFormatter new];
    NSDate *date = [formatter dateFromString:text];
    if (!date) {
        formatter.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
        date = [formatter dateFromString:text];
    }
    return date ? date.timeIntervalSince1970 : NAN;
}

NSDictionary *TMApiParseCostPage(NSString *provider, id json, NSString **outErrorKey) {
    // Un relevé douteux ne doit jamais remplacer des chiffres connus : au premier doute, rien.
    NSString *(^fail)(NSString *) = ^NSString *(NSString *key) { if (outErrorKey) *outErrorKey = key; return key; };
    if (outErrorKey) *outErrorKey = nil;
    if (![json isKindOfClass:NSDictionary.class] || ![json[@"data"] isKindOfClass:NSArray.class]) { fail(@"api.err.malformed"); return nil; }
    BOOL anthropic = [provider isEqualToString:TMApiProviderAnthropic];
    if (!anthropic && ![provider isEqualToString:TMApiProviderOpenAI]) { fail(@"api.err.malformed"); return nil; }
    NSMutableDictionary<NSString *, NSNumber *> *days = [NSMutableDictionary dictionary];
    for (id bucket in json[@"data"]) {
        if (![bucket isKindOfClass:NSDictionary.class]) { fail(@"api.err.malformed"); return nil; }
        NSTimeInterval start = anthropic ? TMParseISODate(bucket[@"starting_at"]) : TMDbl(bucket[@"start_time"]);
        // Un jour vide se signale par une liste vide ; sans liste, on ne sait pas.
        if (isnan(start) || ![bucket[@"results"] isKindOfClass:NSArray.class]) { fail(@"api.err.malformed"); return nil; }
        double total = 0;
        for (id result in bucket[@"results"]) {
            if (![result isKindOfClass:NSDictionary.class]) { fail(@"api.err.malformed"); return nil; }
            double value = NAN;
            NSString *currency = @"";
            if (anthropic) {
                // Cents, en chaîne décimale (« 123.78912 » = 1,24 $).
                id amount = result[@"amount"];
                if ([amount isKindOfClass:NSString.class]) {
                    NSDecimalNumber *decimal = [NSDecimalNumber decimalNumberWithString:amount
                                                                                 locale:@{NSLocaleDecimalSeparator: @"."}];
                    if (![decimal isEqualToNumber:NSDecimalNumber.notANumber]) value = decimal.doubleValue / 100.0;
                } else {
                    double cents = TMDbl(amount);
                    if (!isnan(cents)) value = cents / 100.0;
                }
                currency = TMStr(result[@"currency"]);
            } else {
                NSDictionary *amount = [result[@"amount"] isKindOfClass:NSDictionary.class] ? result[@"amount"] : nil;
                value = TMDbl(amount[@"value"]);
                currency = TMStr(amount[@"currency"]);
            }
            // Les deux fournisseurs facturent en dollars : une autre devise (ou aucune) ne
            // s'additionne pas, et l'ignorer sous-estimerait la dépense.
            if ([currency caseInsensitiveCompare:@"usd"] != NSOrderedSame) { fail(@"api.err.currency"); return nil; }
            if (isnan(value) || !isfinite(value)) { fail(@"api.err.malformed"); return nil; }
            total += value;
        }
        NSString *key = TMDayKey(start);
        days[key] = @(days[key].doubleValue + total);
    }
    NSString *next = @"";
    if ([json[@"has_more"] boolValue]) {
        next = TMStr(json[@"next_page"]);
        if (!next.length) { fail(@"api.err.incomplete"); return nil; }  // la suite existe mais reste hors d'atteinte
    }
    return @{ @"days": days, @"nextPage": next };
}

NSString *TMApiErrorKey(NSInteger status) {
    if (status == 401 || status == 403) return @"api.err.auth";
    if (status == 404) return @"api.err.notFound";
    if (status == 429) return @"api.err.rateLimited";
    if (status >= 500) return @"api.err.server";
    return @"api.err.http";
}

NSTimeInterval TMApiFetchStart(NSTimeInterval queryStart, BOOL hasCache, NSTimeInterval coveredFrom,
                               NSTimeInterval lastSuccess, NSTimeInterval now, BOOL *outIncremental) {
    BOOL incremental = hasCache && coveredFrom > 0 && coveredFrom <= queryStart && lastSuccess > 0;
    if (outIncremental) *outIncremental = incremental;
    if (!incremental) return queryStart;
    NSTimeInterval resume = MIN(TMUTCDayStart(lastSuccess) - 86400, TMUTCDayStart(now) - 2 * 86400);
    return MAX(queryStart, resume);
}

@implementation TMApiFetchGate {
    NSMutableDictionary<NSString *, NSNumber *> *_tokens;
    NSMutableSet<NSString *> *_fetching;
    NSUInteger _counter;
}
- (instancetype)init {
    if ((self = [super init])) { _tokens = [NSMutableDictionary dictionary]; _fetching = [NSMutableSet set]; }
    return self;
}
- (NSUInteger)beginForAccount:(NSString *)accountId {
    NSUInteger token = ++_counter;
    _tokens[accountId] = @(token);
    [_fetching addObject:accountId];
    return token;
}
- (BOOL)isCurrent:(NSUInteger)token forAccount:(NSString *)accountId {
    return [_fetching containsObject:accountId] && _tokens[accountId].unsignedIntegerValue == token;
}
- (BOOL)finish:(NSUInteger)token forAccount:(NSString *)accountId {
    if (![self isCurrent:token forAccount:accountId]) return NO;
    [_fetching removeObject:accountId];
    return YES;
}
- (void)invalidateAccount:(NSString *)accountId {
    _tokens[accountId] = @(++_counter);
    [_fetching removeObject:accountId];
}
- (BOOL)isFetching:(NSString *)accountId { return [_fetching containsObject:accountId]; }
@end

#pragma mark - Trousseau

NSString *TMKeychainReadOutcome(OSStatus status) {
    if (status == errSecSuccess) return @"found";
    if (status == errSecItemNotFound) return @"absent";
    return @"denied";
}

BOOL TMKeychainDeleteSucceeded(OSStatus status) {
    return status == errSecSuccess || status == errSecItemNotFound;
}

#pragma mark - Calcul

static NSCalendar *TMUTCCalendar(void) {
    NSCalendar *calendar = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierGregorian];
    calendar.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    return calendar;
}

NSTimeInterval TMUTCDayStart(NSTimeInterval t) {
    return floor(t / 86400.0) * 86400.0;
}

NSTimeInterval TMUTCMonthStart(NSTimeInterval t) {
    NSCalendar *calendar = TMUTCCalendar();
    NSDateComponents *parts = [calendar components:NSCalendarUnitYear | NSCalendarUnitMonth
                                          fromDate:[NSDate dateWithTimeIntervalSince1970:t]];
    return [calendar dateFromComponents:parts].timeIntervalSince1970;
}

NSTimeInterval TMApiQueryStart(NSDictionary *account, NSTimeInterval now) {
    NSTimeInterval start = TMUTCMonthStart(now);
    if ([account[@"mode"] isEqual:TMApiModePrepaid]) {
        double setAt = TMDbl(account[@"balanceSetAt"]);
        if (!isnan(setAt) && setAt <= now) start = MIN(start, TMUTCDayStart(setAt));
    }
    return MAX(start, TMUTCDayStart(now - TMApiMaxLookback));
}

NSDictionary<NSString *, NSNumber *> *TMApiDailyMerging(NSDictionary *old, NSDictionary *fresh, NSTimeInterval keepFrom) {
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSDictionary *source in @[old ?: @{}, fresh ?: @{}]) {
        if (![source isKindOfClass:NSDictionary.class]) continue;
        for (NSString *key in source) {
            double value = TMDbl(source[key]);
            if (![key isKindOfClass:NSString.class] || isnan(value) || key.doubleValue < keepFrom) continue;
            out[key] = @(value);
        }
    }
    return out;
}

static double TMSumSince(NSDictionary *daily, NSTimeInterval from, NSTimeInterval now) {
    double total = 0;
    for (NSString *key in daily) {
        double day = key.doubleValue, value = TMDbl(daily[key]);
        if (day >= from && day <= now && !isnan(value)) total += value;
    }
    return total;
}

NSDictionary *TMApiSummary(NSDictionary *account, NSDictionary *daily, NSTimeInterval now, double alertBelowUSD) {
    if (![daily isKindOfClass:NSDictionary.class]) daily = @{};
    NSString *mode = TMStr(account[@"mode"]);
    if (!mode.length) mode = TMApiModeNone;
    double today = TMDbl(daily[TMDayKey(now)]);
    NSMutableDictionary *summary = [@{
        @"accountId": TMStr(account[@"accountId"]), @"provider": TMStr(account[@"provider"]), @"mode": mode,
        @"todayUSD": @(isnan(today) ? 0 : today),
        @"monthUSD": @(TMSumSince(daily, TMUTCMonthStart(now), now)),
    } mutableCopy];

    if ([mode isEqualToString:TMApiModePrepaid]) {
        double balance = TMDbl(account[@"balanceUSD"]), setAt = TMDbl(account[@"balanceSetAt"]);
        if (isnan(balance) || isnan(setAt)) { summary[@"mode"] = TMApiModeNone; return summary; }
        // Base en attente le jour même : la dépense de ce jour déjà connue en tient lieu jusqu'au
        // prochain relevé. Le jour de saisie passé, seule la base provisoire reste, approximative.
        double stored = isnan(TMDbl(account[@"baselineUSD"])) ? 0 : TMDbl(account[@"baselineUSD"]);
        BOOL pending = [account[@"baselinePending"] boolValue];
        BOOL sameDay = TMUTCDayStart(setAt) == TMUTCDayStart(now);
        double knownToday = isnan(TMDbl(daily[TMDayKey(setAt)])) ? 0 : TMDbl(daily[TMDayKey(setAt)]);
        double baseline = pending && sameDay ? MAX(stored, knownToday) : stored;
        summary[@"baselineApprox"] = @([account[@"baselineApprox"] boolValue] || (pending && !sameDay));
        double since = MAX(0, TMSumSince(daily, TMUTCDayStart(setAt), now) - baseline);
        double remaining = balance - since;
        summary[@"sinceSetUSD"] = @(since);
        summary[@"remainingUSD"] = @(remaining);
        summary[@"referenceUSD"] = @(balance);
        summary[@"fraction"] = @(balance > 0 ? MIN(1, MAX(0, remaining / balance)) : 0);
        summary[@"severity"] = @(remaining <= 0 ? 2 : (remaining < alertBelowUSD ? 1 : 0));
    } else if ([mode isEqualToString:TMApiModeBudget]) {
        double budget = TMDbl(account[@"budgetUSD"]);
        if (isnan(budget) || budget <= 0) { summary[@"mode"] = TMApiModeNone; return summary; }
        double month = [summary[@"monthUSD"] doubleValue];
        double ratio = month / budget;
        summary[@"remainingUSD"] = @(budget - month);
        summary[@"referenceUSD"] = @(budget);
        summary[@"fraction"] = @(MIN(1, MAX(0, 1 - ratio)));
        summary[@"severity"] = @(ratio >= 1 ? 2 : (ratio >= 0.8 ? 1 : 0));
    }
    return summary;
}

NSDictionary *TMApiWidgetPick(NSArray<NSDictionary *> *summaries, NSString *provider, NSString *pinnedAccountId) {
    NSDictionary *best = nil;
    for (NSDictionary *summary in summaries) {
        if (![summary isKindOfClass:NSDictionary.class] || ![summary[@"provider"] isEqual:provider]) continue;
        if (![summary[@"fraction"] isKindOfClass:NSNumber.class]) continue;
        if (pinnedAccountId.length && [summary[@"accountId"] isEqual:pinnedAccountId]) return summary;
        if (!best || [summary[@"fraction"] doubleValue] < [best[@"fraction"] doubleValue]) best = summary;
    }
    return best;
}

#pragma mark - Alertes

NSDictionary *TMApiAlertDecisions(NSDictionary *state, NSArray<NSDictionary *> *summaries,
                                  double thresholdUSD, BOOL enabled) {
    NSDictionary *previous = [state isKindOfClass:NSDictionary.class] ? state : @{};
    NSMutableDictionary *next = [NSMutableDictionary dictionary];
    NSMutableArray *fire = [NSMutableArray array];
    for (NSDictionary *summary in summaries) {
        NSString *accountId = TMStr(summary[@"accountId"]);
        if (!accountId.length) continue;
        NSString *mode = TMStr(summary[@"mode"]);
        double remaining = TMDbl(summary[@"remainingUSD"]), reference = TMDbl(summary[@"referenceUSD"]);
        if (isnan(remaining)) continue;  // dépense seule : rien à surveiller, l'état s'efface
        // Du plus grave au moins grave : { kind, franchi, réarmé }. Le réarmement laisse une marge,
        // pour qu'une estimation qui oscille autour du seuil ne notifie pas à chaque relevé.
        NSArray *levels;
        if ([mode isEqualToString:TMApiModePrepaid]) {
            levels = @[@[@"empty", @(remaining <= 0), @(remaining > 0)],
                       @[@"low", @(remaining < thresholdUSD), @(remaining >= thresholdUSD + MAX(1, thresholdUSD * 0.1))]];
        } else if ([mode isEqualToString:TMApiModeBudget] && reference > 0) {
            double ratio = (reference - remaining) / reference;
            levels = @[@[@"budget100", @(ratio >= 1), @(ratio < 0.95)],
                       @[@"budget80", @(ratio >= 0.8), @(ratio < 0.75)]];
        } else continue;
        NSString *toFire = nil;
        for (NSArray *level in levels) {
            NSString *key = [NSString stringWithFormat:@"%@:%@", accountId, level[0]];
            BOOL wasOn = [previous[key] boolValue];
            BOOL crossed = [level[1] boolValue], rearmed = [level[2] boolValue];
            BOOL on = wasOn ? !rearmed : crossed;
            if (on) next[key] = @YES;
            if (on && !wasOn && !toFire) toFire = level[0];
        }
        if (toFire && enabled) [fire addObject:@{ @"accountId": accountId, @"kind": toFire }];
    }
    return @{ @"state": next, @"fire": fire };
}

#pragma mark - Affichage

NSString *TMFormatUSD(double value, NSString *localeIdentifier) {
    NSNumberFormatter *formatter = [NSNumberFormatter new];
    formatter.locale = [NSLocale localeWithLocaleIdentifier:localeIdentifier.length ? localeIdentifier : @"fr_FR"];
    formatter.numberStyle = NSNumberFormatterCurrencyStyle;
    formatter.currencyCode = @"USD";
    // « $ » partout : en français, le symbole local serait « $US », trop long pour une icône.
    formatter.currencySymbol = @"$";
    NSUInteger digits = fabs(value) >= 100 ? 0 : 2;
    formatter.minimumFractionDigits = digits;
    formatter.maximumFractionDigits = digits;
    return [formatter stringFromNumber:@(value)] ?: @"";
}
