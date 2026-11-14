#import "StatusCost.h"
#import "StatusQuota.h"  // TMNumber

NSString *const TMPricesAsOfDate = @"14 novembre 2026";
const double TMEurPerUsd = 0.92;            // 1 $ ≈ 0,92 € — taux indicatif du 19 juillet 2026
NSString *const TMFxAsOfDate = @"19 juillet 2026";

double TMCostForTokens(TMTokens t, TMPrices p, TMCostProvider provider) {
    if (provider == TMCostProviderOpenAI) {
        // OpenAI : cached_input est un SOUS-ENSEMBLE d'input_tokens. On facture la part non cachée
        // au tarif plein, la part cachée au tarif réduit. cacheWrite n'existe pas côté OpenAI.
        double fullInput = MAX(t.input - t.cacheRead, 0);
        return (fullInput * p.input + t.cacheRead * p.cacheRead + t.output * p.output) / 1e6;
    }
    // Claude : compartiments DISJOINTS, on somme chacun à son tarif. Les écritures de cache 5 min
    // (1,25× input) et 1 h (2× input) sont facturées séparément.
    return (t.input * p.input + t.output * p.output + t.cacheRead * p.cacheRead
          + t.cacheWrite * p.cacheWrite + t.cacheWrite1h * p.cacheWrite1h) / 1e6;
}

BOOL TMParseClaudeUsageLine(NSDictionary *line, TMTokens *outTokens, NSString **outModel) {
    if (![line isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *message = [line[@"message"] isKindOfClass:NSDictionary.class] ? line[@"message"] : nil;
    NSDictionary *usage = [message[@"usage"] isKindOfClass:NSDictionary.class] ? message[@"usage"] : nil;
    if (!usage) return NO;
    // Les écritures de cache se répartissent 5 min / 1 h dans `cache_creation`. Les logs récents
    // détaillent ephemeral_5m/ephemeral_1h ; sur les anciens (détail absent), on range tout le
    // cache_creation_input_tokens en 5 min — prudent, c'est le tarif le plus bas.
    NSDictionary *cc = [usage[@"cache_creation"] isKindOfClass:NSDictionary.class] ? usage[@"cache_creation"] : nil;
    double write5m, write1h;
    if (cc) {
        write5m = TMNumber(cc[@"ephemeral_5m_input_tokens"]);
        write1h = TMNumber(cc[@"ephemeral_1h_input_tokens"]);
    } else {
        write5m = TMNumber(usage[@"cache_creation_input_tokens"]);
        write1h = 0;
    }
    if (outTokens) *outTokens = (TMTokens){
        .input = TMNumber(usage[@"input_tokens"]),
        .output = TMNumber(usage[@"output_tokens"]),
        .cacheRead = TMNumber(usage[@"cache_read_input_tokens"]),
        .cacheWrite = write5m,
        .cacheWrite1h = write1h,
    };
    if (outModel) *outModel = [message[@"model"] isKindOfClass:NSString.class] ? message[@"model"] : nil;
    return YES;
}

static TMTokens TMCodexTokens(NSDictionary *usage);

BOOL TMParseCodexTokenCount(NSDictionary *info, TMTokens *outTokens, NSString **outModel) {
    if (![info isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *total = [info[@"total_token_usage"] isKindOfClass:NSDictionary.class] ? info[@"total_token_usage"] : nil;
    if (!total) return NO;
    if (outTokens) *outTokens = TMCodexTokens(total);
    if (outModel) *outModel = [info[@"model"] isKindOfClass:NSString.class] ? info[@"model"] : nil;
    return YES;
}

// Un identifiant porte parfois une date en suffixe (claude-haiku-4-5-20251001, gpt-…-2026-10-01).
static BOOL TMIsDateSuffix(NSString *suffix) {
    static NSRegularExpression *re; static dispatch_once_t once;
    dispatch_once(&once, ^{ re = [NSRegularExpression regularExpressionWithPattern:@"^-(\\d{8}|\\d{4}-\\d{2}-\\d{2})$" options:0 error:nil]; });
    return [re numberOfMatchesInString:suffix options:0 range:NSMakeRange(0, suffix.length)] == 1;
}

BOOL TMPricesForModel(NSString *model, TMPrices *outPrices) {
    if (![model isKindOfClass:NSString.class] || !model.length) return NO;
    // Tarifs standard par 1M de tokens, relevés le 14 novembre 2026 sur les pages officielles :
    //   https://platform.claude.com/docs/en/about-claude/pricing
    //   https://developers.openai.com/api/docs/pricing
    // Modèle inconnu → NO, jamais un prix fabriqué : ses tokens seront comptés à part.
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *table;  // [input, output, cacheRead, write5m, write1h]
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        // Claude : écriture de cache 5 min à 1,25× l'input, 1 h à 2×. La lecture de cache n'est plus
        // un multiple fixe : 0,1× en général, 0,05× sur Opus 5.5 et Sonnet 5.5, 0,025× sur Fable
        // 5.1 et 5.2 — d'où une ligne par version, jamais un tarif hérité de la version précédente.
        // OpenAI : pas d'écriture de cache facturée (colonnes inutilisées, laissées à 0).
        table = @{
            @"claude-fable-5-2":  @[@8.0,  @40.0, @0.20,  @10.0,   @16.0],
            @"claude-fable-5-1":  @[@10.0, @50.0, @0.25,  @12.50,  @20.0],
            @"claude-fable-5":    @[@10.0, @50.0, @1.0,   @12.50,  @20.0],
            @"claude-opus-5-5":   @[@4.0,  @20.0, @0.20,  @5.0,    @8.0],
            @"claude-opus-5":     @[@5.0,  @25.0, @0.5,   @6.25,   @10.0],
            @"claude-opus-4-8":   @[@5.0,  @25.0, @0.5,   @6.25,   @10.0],
            @"claude-opus-4-7":   @[@5.0,  @25.0, @0.5,   @6.25,   @10.0],
            @"claude-opus-4-6":   @[@5.0,  @25.0, @0.5,   @6.25,   @10.0],
            @"claude-opus-4-5":   @[@5.0,  @25.0, @0.5,   @6.25,   @10.0],
            @"claude-sonnet-5-5": @[@2.0,  @10.0, @0.10,  @2.50,   @4.0],
            @"claude-sonnet-5":   @[@2.0,  @10.0, @0.2,   @2.50,   @4.0],    // le tarif d'introduction est devenu le tarif normal
            @"claude-sonnet-4-6": @[@3.0,  @15.0, @0.3,   @3.75,   @6.0],
            @"claude-sonnet-4-5": @[@3.0,  @15.0, @0.3,   @3.75,   @6.0],
            // Haiku 5.5 : tarif des prompts jusqu'à 100 000 tokens ; au-delà, voir TMPricesForRequest.
            @"claude-haiku-5-5":  @[@0.10, @0.50, @0.01,  @0.125,  @0.20],
            @"claude-haiku-4-5":  @[@1.0,  @5.0,  @0.1,   @1.25,   @2.0],
            // OpenAI, contexte court (≤ 272 000 tokens d'entrée) ; au-delà, voir TMPricesForRequest.
            @"gpt-6-astra":       @[@10.0, @50.0, @1.0,   @0, @0],
            @"gpt-6.1-sol":       @[@2.0,  @10.0, @0.10,  @0, @0],
            @"gpt-6.1-terra":     @[@1.0,  @5.0,  @0.05,  @0, @0],
            @"gpt-5.6-sol":       @[@4.0,  @20.0, @0.4,   @0, @0],
            @"gpt-5.6-terra":     @[@2.0,  @12.0, @0.2,   @0, @0],
            @"gpt-5.6-luna":      @[@0.2,  @1.2,  @0.02,  @0, @0],
            @"gpt-5.5":           @[@5.0,  @30.0, @0.5,   @0, @0],
            @"gpt-5.3-codex-spark": @[@1.75, @14.0, @0.175, @0, @0],         // relevé de juillet 2026, absent de la page depuis
        };
    });
    // Seul un suffixe de date est toléré. Un simple préfixe ferait hériter « claude-opus-5-6 » du
    // tarif de « claude-opus-5 » : c'est ainsi que Fable 5.2 et Sonnet 5.5 ont été chiffrés au
    // tarif de leur prédécesseur. Une version inconnue reste « non tarifée », donc visible.
    NSArray<NSNumber *> *prices = table[model];
    if (!prices) {
        for (NSString *known in table) {
            if ([model hasPrefix:known] && TMIsDateSuffix([model substringFromIndex:known.length])) { prices = table[known]; break; }
        }
    }
    if (!prices) return NO;
    if (outPrices) *outPrices = (TMPrices){ prices[0].doubleValue, prices[1].doubleValue,
                                            prices[2].doubleValue, prices[3].doubleValue,
                                            prices[4].doubleValue };
    return YES;
}

static TMPrices TMScalePrices(TMPrices p, double input, double output) {
    return (TMPrices){ p.input * input, p.output * output, p.cacheRead * input, p.cacheWrite * input, p.cacheWrite1h * input };
}

BOOL TMPricesForRequest(NSString *model, TMCostProvider provider, TMTokens t, BOOL fast, TMPrices *outPrices) {
    TMPrices p;
    if (!TMPricesForModel(model, &p)) return NO;
    if (provider == TMCostProviderClaude) {
        // Haiku 5.5 : une requête dont le prompt (entrée + lectures + écritures de cache) dépasse
        // 100 000 tokens paie cinq fois le tarif, sur tous les compartiments.
        if ([model hasPrefix:@"claude-haiku-5-5"] && t.input + t.cacheRead + t.cacheWrite + t.cacheWrite1h > 100000)
            p = TMScalePrices(p, 5, 5);
        // Mode rapide (usage.speed = "fast") : 2× le tarif standard, cache compris.
        if (fast) p = TMScalePrices(p, 2, 2);
    } else {
        // Contexte long : plus de 272 000 tokens d'entrée → entrée et cache à 2×, sortie à 1,5×.
        if (t.input > 272000) p = TMScalePrices(p, 2, 1.5);
        // Palier « Fast » (service_tier priority) : 2× le standard, 2,5× sur gpt-5.5. La page ne
        // donne pas de tarif Fast en contexte long : on cumule les deux majorations.
        if (fast) { double k = [model hasPrefix:@"gpt-5.5"] ? 2.5 : 2; p = TMScalePrices(p, k, k); }
    }
    if (outPrices) *outPrices = p;
    return YES;
}


#pragma mark - Somme et ventilation par fenêtre (pures)

// Chaque tranche est heure → modèle → @{ @"cost": prix?, @"tokens": total }. Somme les `cost`
// (les modèles non tarifés, sans clé `cost`, ne contribuent pas) sur les heures ≥ startEpoch.
double TMCostSince(NSDictionary *buckets, NSTimeInterval startEpoch) {
    if (![buckets isKindOfClass:NSDictionary.class]) return 0;
    double total = 0;
    for (NSString *hourKey in buckets) {
        if (hourKey.doubleValue < startEpoch) continue;
        NSDictionary *models = buckets[hourKey];
        if (![models isKindOfClass:NSDictionary.class]) continue;
        for (NSString *model in models) {
            NSNumber *cost = models[model][@"cost"];
            if ([cost isKindOfClass:NSNumber.class]) total += cost.doubleValue;
        }
    }
    return total;
}

NSArray<NSDictionary *> *TMModelBreakdownSince(NSDictionary *buckets, NSTimeInterval startEpoch) {
    if (![buckets isKindOfClass:NSDictionary.class]) return @[];
    NSMutableDictionary<NSString *, NSMutableDictionary *> *agg = [NSMutableDictionary dictionary];
    for (NSString *hourKey in buckets) {
        if (hourKey.doubleValue < startEpoch) continue;
        NSDictionary *models = buckets[hourKey];
        if (![models isKindOfClass:NSDictionary.class]) continue;
        for (NSString *model in models) {
            NSDictionary *entry = models[model];
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *row = agg[model];
            if (!row) { row = [@{ @"tokens": @0.0, @"priced": @NO, @"cost": @0.0 } mutableCopy]; agg[model] = row; }
            row[@"tokens"] = @([row[@"tokens"] doubleValue] + [entry[@"tokens"] doubleValue]);
            NSNumber *cost = entry[@"cost"];
            if ([cost isKindOfClass:NSNumber.class]) {
                row[@"priced"] = @YES;
                row[@"cost"] = @([row[@"cost"] doubleValue] + cost.doubleValue);
            }
        }
    }
    NSMutableArray<NSDictionary *> *out = [NSMutableArray array];
    for (NSString *model in agg) {
        NSMutableDictionary *row = agg[model];
        NSMutableDictionary *item = [@{ @"model": model, @"tokens": row[@"tokens"] } mutableCopy];
        if ([row[@"priced"] boolValue]) item[@"cost"] = row[@"cost"];
        [out addObject:item];
    }
    // Tri par coût décroissant ; les non tarifés (sans clé `cost`, traités comme -1) en fin.
    [out sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        double ca = a[@"cost"] ? [a[@"cost"] doubleValue] : -1;
        double cb = b[@"cost"] ? [b[@"cost"] doubleValue] : -1;
        if (ca > cb) return NSOrderedAscending;
        if (ca < cb) return NSOrderedDescending;
        return [a[@"model"] compare:b[@"model"]];  // stable et déterministe à coût égal
    }];
    return out;
}

#pragma mark - Balayage incrémental (I/O)

static void TMEnumerateMatchingLines(NSString *path, const char *marker, void (^block)(NSDictionary *line));
static NSTimeInterval TMParseISO(NSString *ts);

static NSString *TMCostCachePath(void) {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    dir = [dir stringByAppendingPathComponent:@"Status"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"token-usage.json"];
}

static NSString *TMFileFingerprint(NSString *path) {
    NSDictionary *attrs = [NSFileManager.defaultManager attributesOfItemAtPath:path error:nil];
    return [NSString stringWithFormat:@"%llu:%.0f", (unsigned long long)[attrs fileSize],
            [attrs.fileModificationDate timeIntervalSince1970]];
}

static NSTimeInterval TMParseISO(NSString *ts) {
    if (![ts isKindOfClass:NSString.class]) return 0;
    static NSDateFormatter *fmt; static dispatch_once_t once;
    dispatch_once(&once, ^{ fmt = [NSDateFormatter new]; fmt.dateFormat = @"yyyy-MM-dd'T'HH:mm:ss.SSS'Z'";
        fmt.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0]; fmt.locale = [NSLocale localeWithLocaleIdentifier:@"en_US_POSIX"]; });
    NSDate *d = [fmt dateFromString:ts];
    return d ? d.timeIntervalSince1970 : 0;
}

static NSString *TMHourKey(NSTimeInterval epoch) {
    return [NSString stringWithFormat:@"%lld", (long long)(epoch - fmod(epoch, 3600))];
}

// Accumule les tokens d'UNE requête dans la tranche heure → modèle → {cost?, tokens}. Le tarif se
// décide par requête (palier de taille, mode rapide). Un modèle sans tarif connu garde ses tokens
// et son nom, mais aucune clé `cost` (distingue « pas de prix » de « nul »).
static void TMAccumulate(NSMutableDictionary *buckets, TMTokens t, NSString *model,
                         TMCostProvider provider, NSTimeInterval epoch, BOOL fast) {
    NSString *hour = TMHourKey(epoch);
    NSString *modelKey = (model.length ? model : @"(inconnu)");
    // OpenAI : cacheRead est un sous-ensemble d'input, il ne s'ajoute pas au volume.
    double tokens = provider == TMCostProviderOpenAI ? t.input + t.output
                                                     : t.input + t.output + t.cacheRead + t.cacheWrite + t.cacheWrite1h;

    NSMutableDictionary *models = buckets[hour];
    if (!models) { models = [NSMutableDictionary dictionary]; buckets[hour] = models; }
    NSMutableDictionary *entry = models[modelKey];
    if (!entry) { entry = [@{ @"tokens": @0.0 } mutableCopy]; models[modelKey] = entry; }
    entry[@"tokens"] = @([entry[@"tokens"] doubleValue] + tokens);

    TMPrices prices;
    if (model && TMPricesForRequest(model, provider, t, fast, &prices)) {
        double cost = TMCostForTokens(t, prices, provider);
        entry[@"cost"] = @([entry[@"cost"] doubleValue] + cost);  // absent → 0 → présent : devient tarifé
    }
}

// Un fichier Claude. Claude Code écrit une ligne par bloc de contenu (réflexion, texte, appel
// d'outil) et répète sur chacune l'usage de la réponse entière : une même réponse (message.id +
// requestId) apparaît donc deux fois ou plus. Chaque réponse n'est comptée qu'une fois, avec son
// relevé le plus complet (la sortie grossit pendant le flux).
NSDictionary *TMScanClaudeLogFile(NSString *path) {
    NSMutableDictionary *buckets = [NSMutableDictionary dictionary];
    NSMutableDictionary<NSString *, NSArray *> *responses = [NSMutableDictionary dictionary];  // clé → [tokens, modèle, instant, rapide]
    TMEnumerateMatchingLines(path, "\"usage\"", ^(NSDictionary *line) {
        TMTokens t; NSString *model = nil;
        if (!TMParseClaudeUsageLine(line, &t, &model)) return;
        NSString *ts = [line[@"timestamp"] isKindOfClass:NSString.class] ? line[@"timestamp"] : nil;
        NSDictionary *message = line[@"message"];
        BOOL fast = [message[@"usage"][@"speed"] isEqual:@"fast"];
        NSString *messageId = [message[@"id"] isKindOfClass:NSString.class] ? message[@"id"] : nil;
        if (!messageId.length) { TMAccumulate(buckets, t, model, TMCostProviderClaude, TMParseISO(ts), fast); return; }
        NSString *requestId = [line[@"requestId"] isKindOfClass:NSString.class] ? line[@"requestId"] : @"";
        NSString *key = [NSString stringWithFormat:@"%@|%@", messageId, requestId];
        NSArray *seen = responses[key];
        TMTokens previous; [seen[0] getValue:&previous];
        if (seen && previous.output >= t.output) return;
        responses[key] = @[[NSValue valueWithBytes:&t objCType:@encode(TMTokens)], model ?: @"",
                           seen ? seen[2] : @(TMParseISO(ts)), @(fast)];
    });
    for (NSArray *response in responses.allValues) {
        TMTokens t; [response[0] getValue:&t];
        TMAccumulate(buckets, t, [response[1] length] ? response[1] : nil, TMCostProviderClaude,
                     [response[2] doubleValue], [response[3] boolValue]);
    }
    return @{ @"buckets": buckets };
}

static TMTokens TMCodexTokens(NSDictionary *usage) {
    return (TMTokens){
        .input = TMNumber(usage[@"input_tokens"]),                                  // total, cache inclus
        // output_tokens INCLUT déjà reasoning_output_tokens (vérifié : input+output == total_tokens).
        // Le réadditionner double-compterait le raisonnement (sur-facturation).
        .output = TMNumber(usage[@"output_tokens"]),
        .cacheRead = TMNumber(usage[@"cached_input_tokens"]),                        // sous-ensemble
        .cacheWrite = 0,
        .cacheWrite1h = 0,
    };
}

// Un fichier Codex. Chaque événement token_count porte le total CUMULÉ de la session et l'usage de
// la dernière requête (last_token_usage). Chaque requête est chiffrée à son heure, avec le modèle
// et le palier de service en vigueur à ce moment-là : une session peut changer de modèle en route,
// et le tarif dépend de la taille de chaque requête. Vérifié sur les journaux réels : la somme des
// last_token_usage est égale au dernier total. Un événement répété (même total) n'est pas recompté.
// Balayage octets à deux marqueurs, pour ne parser que les lignes portant un modèle ou un total.
NSDictionary *TMScanCodexLogFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSMutableDictionary *buckets = [NSMutableDictionary dictionary];
    if (!data.length) return @{ @"buckets": buckets };
    const char *bytes = data.bytes; NSUInteger len = data.length, start = 0;
    NSString *model = nil; NSDictionary *previousTotal = nil; BOOL fast = NO;
    for (NSUInteger i = 0; i <= len; i++) {
        if (i != len && bytes[i] != '\n') continue;
        NSUInteger lineLen = i - start;
        BOOL hasModel = memmem(bytes + start, lineLen, "\"model\"", 7) != NULL;
        BOOL hasTotal = memmem(bytes + start, lineLen, "total_token_usage", 17) != NULL;
        if (hasModel || hasTotal) {
            NSData *lineData = [NSData dataWithBytesNoCopy:(void *)(bytes + start) length:lineLen freeWhenDone:NO];
            NSDictionary *line = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
            if ([line isKindOfClass:NSDictionary.class]) {
                NSDictionary *payload = [line[@"payload"] isKindOfClass:NSDictionary.class] ? line[@"payload"] : nil;
                // Réglages du fil (thread_settings_applied) : modèle et palier de service.
                NSDictionary *settings = [payload[@"thread_settings"] isKindOfClass:NSDictionary.class] ? payload[@"thread_settings"] : nil;
                NSString *m = settings ? settings[@"model"] : [line[@"model"] isKindOfClass:NSString.class] ? line[@"model"] : payload[@"model"];
                if ([m isKindOfClass:NSString.class] && m.length) model = m;
                if ([settings[@"service_tier"] isKindOfClass:NSString.class])
                    fast = [@[@"priority", @"fast"] containsObject:settings[@"service_tier"]];
                NSDictionary *info = [payload[@"info"] isKindOfClass:NSDictionary.class] ? payload[@"info"] : nil;
                NSDictionary *total = [info[@"total_token_usage"] isKindOfClass:NSDictionary.class] ? info[@"total_token_usage"] : nil;
                if (total && ![total isEqual:previousTotal]) {
                    NSDictionary *last = [info[@"last_token_usage"] isKindOfClass:NSDictionary.class] ? info[@"last_token_usage"] : nil;
                    TMTokens t = TMCodexTokens(last ?: total);
                    if (!last && previousTotal) {  // anciens journaux sans last_token_usage : écart entre deux totaux
                        TMTokens before = TMCodexTokens(previousTotal);
                        t = (TMTokens){ MAX(t.input - before.input, 0), MAX(t.output - before.output, 0), MAX(t.cacheRead - before.cacheRead, 0), 0, 0 };
                    }
                    previousTotal = total;
                    NSString *ts = [line[@"timestamp"] isKindOfClass:NSString.class] ? line[@"timestamp"] : nil;
                    NSString *tokenModel = [info[@"model"] isKindOfClass:NSString.class] ? info[@"model"] : model;
                    TMAccumulate(buckets, t, tokenModel, TMCostProviderOpenAI, TMParseISO(ts), fast);
                }
            }
        }
        start = i + 1;
    }
    return @{ @"buckets": buckets };
}

// La fenêtre la plus longue affichée est de 30 jours (totaux 8 j et 30 j de la vue Volumes) : les
// sessions plus anciennes ne peuvent contribuer à aucun coût affiché. On les ignore — c'est ce qui
// garde le balayage à froid tenable. Un jour de marge couvre les journaux écrits en fin de fenêtre.
static const NSTimeInterval TMCostMaxAge = 31 * 86400;
static NSArray<NSString *> *TMLogFiles(NSString *root) {
    NSMutableArray *files = [NSMutableArray array];
    NSDate *cutoff = [NSDate dateWithTimeIntervalSinceNow:-TMCostMaxAge];
    NSDirectoryEnumerator *e = [NSFileManager.defaultManager enumeratorAtURL:[NSURL fileURLWithPath:root]
        includingPropertiesForKeys:@[NSURLContentModificationDateKey] options:0 errorHandler:nil];
    for (NSURL *url in e) {
        if (![url.pathExtension isEqualToString:@"jsonl"]) continue;
        NSDate *mtime = nil;
        [url getResourceValue:&mtime forKey:NSURLContentModificationDateKey error:nil];
        if (mtime && [mtime compare:cutoff] == NSOrderedAscending) continue;  // trop vieux
        [files addObject:url.path];
    }
    return files;
}

// Itère les lignes d'un fichier au niveau des octets, sans allouer une NSString par ligne. Seules
// les lignes dont les octets bruts contiennent `marker` sont converties et remises au bloc — le
// reste (l'écrasante majorité) ne coûte qu'un balayage mémoire.
static void TMEnumerateMatchingLines(NSString *path, const char *marker, void (^block)(NSDictionary *line)) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    if (!data.length) return;
    const char *bytes = data.bytes;
    NSUInteger len = data.length, markerLen = strlen(marker), start = 0;
    for (NSUInteger i = 0; i <= len; i++) {
        if (i == len || bytes[i] == '\n') {
            NSUInteger lineLen = i - start;
            if (lineLen > markerLen && memmem(bytes + start, lineLen, marker, markerLen)) {
                NSData *lineData = [NSData dataWithBytesNoCopy:(void *)(bytes + start) length:lineLen freeWhenDone:NO];
                NSDictionary *line = [NSJSONSerialization JSONObjectWithData:lineData options:0 error:nil];
                if ([line isKindOfClass:NSDictionary.class]) block(line);
            }
            start = i + 1;
        }
    }
}

// Fusionne un nid heure→modèle→{cost?,tokens} source dans une destination mutable (deep merge).
static void TMMergeBuckets(NSMutableDictionary *dst, NSDictionary *src) {
    if (![src isKindOfClass:NSDictionary.class]) return;
    for (NSString *hour in src) {
        NSDictionary *models = src[hour];
        if (![models isKindOfClass:NSDictionary.class]) continue;
        NSMutableDictionary *dstModels = dst[hour];
        if (!dstModels) { dstModels = [NSMutableDictionary dictionary]; dst[hour] = dstModels; }
        for (NSString *model in models) {
            NSDictionary *entry = models[model];
            if (![entry isKindOfClass:NSDictionary.class]) continue;
            NSMutableDictionary *dstEntry = dstModels[model];
            if (!dstEntry) { dstEntry = [@{ @"tokens": @0.0 } mutableCopy]; dstModels[model] = dstEntry; }
            dstEntry[@"tokens"] = @([dstEntry[@"tokens"] doubleValue] + [entry[@"tokens"] doubleValue]);
            NSNumber *cost = entry[@"cost"];
            if ([cost isKindOfClass:NSNumber.class])
                dstEntry[@"cost"] = @([dstEntry[@"cost"] doubleValue] + cost.doubleValue);
        }
    }
}

// Version du format de token-usage.json. v3 : coûts recalculés avec le cache 1 h à 2× et sans
// double-comptage du reasoning Codex. Un cache d'une autre version est ignoré (rescan complet),
// pas migré — les coûts mémorisés d'une version antérieure seraient faux.
// v4 : rescanner aussi les anciens fichiers pour valoriser les tokens Astra déjà enregistrés.
// v5 : réponses Claude dédoublonnées, Codex chiffré requête par requête, tarifs de novembre 2026.
static NSInteger const TMCostCacheVersion = 5;

NSDictionary *TMScanTerminalCosts(void) {
    NSDictionary *cache = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:TMCostCachePath()] ?: [NSData data] options:0 error:nil];
    BOOL versionOK = [cache[@"version"] isKindOfClass:NSNumber.class] && [cache[@"version"] integerValue] == TMCostCacheVersion;
    NSDictionary *cachedFiles = (versionOK && [cache[@"files"] isKindOfClass:NSDictionary.class]) ? cache[@"files"] : @{};
    NSMutableDictionary *files = [NSMutableDictionary dictionary];  // path -> {fp, provider, buckets}

    NSString *home = NSHomeDirectory();
    NSArray *sources = @[
        @[[home stringByAppendingPathComponent:@".claude/projects"], @"claude"],
        @[[home stringByAppendingPathComponent:@".codex/sessions"], @"codex"],
        @[[home stringByAppendingPathComponent:@".codex/archived_sessions"], @"codex"],
    ];
    for (NSArray *source in sources) {
        NSString *root = source[0], *provider = source[1];
        for (NSString *path in TMLogFiles(root)) {
            NSString *fp = TMFileFingerprint(path);
            NSDictionary *prev = cachedFiles[path];
            if ([prev[@"fp"] isEqualToString:fp]) { files[path] = prev; continue; }  // inchangé : réutilisé
            NSDictionary *parsed = [provider isEqualToString:@"claude"] ? TMScanClaudeLogFile(path) : TMScanCodexLogFile(path);
            files[path] = @{ @"fp": fp, @"provider": provider, @"buckets": parsed[@"buckets"] };
        }
    }

    // Agrège par fournisseur. Les fichiers disparus du disque sortent naturellement (absents de `files`).
    NSMutableDictionary *claudeBuckets = [NSMutableDictionary dictionary], *codexBuckets = [NSMutableDictionary dictionary];
    for (NSDictionary *entry in files.allValues) {
        BOOL isClaude = [entry[@"provider"] isEqualToString:@"claude"];
        TMMergeBuckets(isClaude ? claudeBuckets : codexBuckets, entry[@"buckets"]);
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:@{ @"version": @(TMCostCacheVersion), @"files": files } options:0 error:nil];
    [out writeToFile:TMCostCachePath() atomically:YES];

    return @{ @"claude": @{ @"buckets": claudeBuckets },
              @"codex":  @{ @"buckets": codexBuckets } };
}


#pragma mark - Export CSV

// Semaine ISO « 2026-W44 » d'un instant, en UTC.
static NSString *TMISOWeekLabel(NSTimeInterval t) {
    static NSCalendar *cal;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        cal = [NSCalendar calendarWithIdentifier:NSCalendarIdentifierISO8601];
        cal.timeZone = [NSTimeZone timeZoneForSecondsFromGMT:0];
    });
    NSDateComponents *c = [cal components:NSCalendarUnitYearForWeekOfYear | NSCalendarUnitWeekOfYear
                                 fromDate:[NSDate dateWithTimeIntervalSince1970:t]];
    return [NSString stringWithFormat:@"%04ld-W%02ld", (long)c.yearForWeekOfYear, (long)c.weekOfYear];
}

NSArray<NSDictionary *> *TMCostWeeklyRows(NSArray<NSDictionary *> *sources) {
    NSMutableArray *rows = [NSMutableArray array];
    for (NSDictionary *src in sources) {
        if (![src isKindOfClass:NSDictionary.class]) continue;
        // instant → dollars, quelle que soit la forme de la source
        NSMutableArray<NSArray<NSNumber *> *> *points = [NSMutableArray array];
        NSDictionary *daily = src[@"daily"], *buckets = src[@"buckets"];
        if ([daily isKindOfClass:NSDictionary.class]) {
            for (NSString *k in daily) if ([daily[k] isKindOfClass:NSNumber.class]) [points addObject:@[@(k.doubleValue), daily[k]]];
        } else if ([buckets isKindOfClass:NSDictionary.class]) {
            for (NSString *k in buckets) {
                double c = TMCostSince(@{ k: buckets[k] }, 0);
                if (c != 0) [points addObject:@[@(k.doubleValue), @(c)]];
            }
        }
        if (!points.count) continue;
        NSMutableDictionary<NSString *, NSNumber *> *weeks = [NSMutableDictionary dictionary];
        NSTimeInterval lo = DBL_MAX, hi = 0;
        for (NSArray *p in points) {
            NSTimeInterval t = [p[0] doubleValue];
            lo = MIN(lo, t); hi = MAX(hi, t);
            NSString *w = TMISOWeekLabel(t);
            weeks[w] = @([weeks[w] doubleValue] + [p[1] doubleValue]);
        }
        // Chaque semaine entre la première et la dernière, sans trou : pas de saut dans un tableur.
        for (NSTimeInterval t = lo; ; t += 7 * 86400) {
            NSString *w = TMISOWeekLabel(MIN(t, hi));
            if (!weeks[w]) weeks[w] = @0;
            if (t >= hi) break;
        }
        for (NSString *w in weeks)
            [rows addObject:@{ @"provider": src[@"provider"] ?: @"", @"account": src[@"account"] ?: @"",
                               @"week": w, @"cost": weeks[w], @"source": src[@"source"] ?: @"" }];
    }
    NSArray *keys = @[@"provider", @"account", @"week", @"source"];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) {
        for (NSString *k in keys) {
            NSComparisonResult r = [a[k] compare:b[k]];
            if (r != NSOrderedSame) return r;
        }
        return NSOrderedSame;
    }];
    return rows;
}

// Guillemets si la valeur contient « ; », un guillemet ou un saut de ligne. Une valeur qui
// commence par = + - @ reçoit une apostrophe : Excel l'exécuterait sinon comme une formule.
static NSString *TMCSVField(NSString *value) {
    if (value.length && [@"=+-@\t\r" rangeOfString:[value substringToIndex:1]].location != NSNotFound) value = [@"'" stringByAppendingString:value];
    if ([value rangeOfCharacterFromSet:[NSCharacterSet characterSetWithCharactersInString:@";\"\r\n"]].location == NSNotFound) return value;
    return [NSString stringWithFormat:@"\"%@\"", [value stringByReplacingOccurrencesOfString:@"\"" withString:@"\"\""]];
}

NSData *TMCostRowsToCSV(NSArray<NSDictionary *> *rows, NSArray<NSString *> *headers) {
    NSMutableString *csv = [NSMutableString string];
    NSMutableArray *head = [NSMutableArray array];
    for (NSString *h in headers) [head addObject:TMCSVField(h)];
    [csv appendFormat:@"%@\r\n", [head componentsJoinedByString:@";"]];
    for (NSDictionary *r in rows)
        [csv appendFormat:@"%@;%@;%@;%@;USD;%@\r\n", TMCSVField(r[@"provider"]), TMCSVField(r[@"account"]), r[@"week"],
         [NSString stringWithFormat:@"%.4f", [r[@"cost"] doubleValue]], TMCSVField(r[@"source"])];
    NSMutableData *data = [NSMutableData dataWithBytes:"\xEF\xBB\xBF" length:3];
    [data appendData:[csv dataUsingEncoding:NSUTF8StringEncoding]];
    return data;
}
