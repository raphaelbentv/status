#import "StatusCost.h"
#import "StatusQuota.h"  // TMNumber

NSString *const TMPricesAsOfDate = @"19 juillet 2026";

double TMCostForTokens(TMTokens t, TMPrices p, TMCostProvider provider) {
    if (provider == TMCostProviderOpenAI) {
        // OpenAI : cached_input est un SOUS-ENSEMBLE d'input_tokens. On facture la part non cachée
        // au tarif plein, la part cachée au tarif réduit. cacheWrite n'existe pas côté OpenAI.
        double fullInput = MAX(t.input - t.cacheRead, 0);
        return (fullInput * p.input + t.cacheRead * p.cacheRead + t.output * p.output) / 1e6;
    }
    // Claude : trois compartiments DISJOINTS, on somme chacun à son tarif.
    return (t.input * p.input + t.output * p.output
          + t.cacheRead * p.cacheRead + t.cacheWrite * p.cacheWrite) / 1e6;
}

BOOL TMParseClaudeUsageLine(NSDictionary *line, TMTokens *outTokens, NSString **outModel) {
    if (![line isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *message = [line[@"message"] isKindOfClass:NSDictionary.class] ? line[@"message"] : nil;
    NSDictionary *usage = [message[@"usage"] isKindOfClass:NSDictionary.class] ? message[@"usage"] : nil;
    if (!usage) return NO;
    if (outTokens) *outTokens = (TMTokens){
        .input = TMNumber(usage[@"input_tokens"]),
        .output = TMNumber(usage[@"output_tokens"]),
        .cacheRead = TMNumber(usage[@"cache_read_input_tokens"]),
        .cacheWrite = TMNumber(usage[@"cache_creation_input_tokens"]),
    };
    if (outModel) *outModel = [message[@"model"] isKindOfClass:NSString.class] ? message[@"model"] : nil;
    return YES;
}

BOOL TMParseCodexTokenCount(NSDictionary *info, TMTokens *outTokens, NSString **outModel) {
    if (![info isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *total = [info[@"total_token_usage"] isKindOfClass:NSDictionary.class] ? info[@"total_token_usage"] : nil;
    if (!total) return NO;
    if (outTokens) *outTokens = (TMTokens){
        .input = TMNumber(total[@"input_tokens"]),                                  // total, cache inclus
        .output = TMNumber(total[@"output_tokens"]) + TMNumber(total[@"reasoning_output_tokens"]),  // reasoning = sortie
        .cacheRead = TMNumber(total[@"cached_input_tokens"]),                        // sous-ensemble
        .cacheWrite = 0,
    };
    if (outModel) *outModel = [info[@"model"] isKindOfClass:NSString.class] ? info[@"model"] : nil;
    return YES;
}

BOOL TMPricesForModel(NSString *model, TMPrices *outPrices) {
    if (![model isKindOfClass:NSString.class] || !model.length) return NO;
    // Tarifs par 1M de tokens, relevés le 19 juillet 2026 (voir la spec pour les sources).
    // Modèle inconnu → NO, jamais un prix fabriqué : ses tokens seront comptés à part.
    static NSDictionary<NSString *, NSArray<NSNumber *> *> *table;  // [input, output, cacheRead, cacheWrite]
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        table = @{
            @"claude-opus-4-8":   @[@5.0,  @25.0, @0.5,   @6.25],
            @"claude-opus-4-7":   @[@5.0,  @25.0, @0.5,   @6.25],
            @"claude-sonnet-5":   @[@2.0,  @10.0, @0.2,   @2.50],   // tarif d'intro jusqu'au 31/08/2026
            @"claude-sonnet-4-6": @[@3.0,  @15.0, @0.3,   @3.75],
            @"claude-fable-5":    @[@10.0, @50.0, @1.0,   @12.50],
            @"claude-haiku-4-5":  @[@1.0,  @5.0,  @0.1,   @1.25],
            @"gpt-5.6-sol":       @[@5.0,  @30.0, @0.5,   @6.25],
            @"gpt-5.6-terra":     @[@2.5,  @15.0, @0.25,  @3.125],
            @"gpt-5.6-luna":      @[@1.0,  @6.0,  @0.1,   @1.25],
            @"gpt-5.5":           @[@5.0,  @30.0, @0.5,   @6.25],
            @"gpt-5.3-codex-spark": @[@1.75, @14.0, @0.175, @2.1875],
        };
    });
    // Certains modèles Claude portent un suffixe de date (claude-haiku-4-5-20251001) : on tolère
    // le préfixe pour ne pas rater un tarif à cause d'un horodatage.
    NSArray<NSNumber *> *prices = table[model];
    if (!prices) {
        for (NSString *known in table) {
            if ([model hasPrefix:known]) { prices = table[known]; break; }
        }
    }
    if (!prices) return NO;
    if (outPrices) *outPrices = (TMPrices){ prices[0].doubleValue, prices[1].doubleValue,
                                            prices[2].doubleValue, prices[3].doubleValue };
    return YES;
}


#pragma mark - Somme par fenêtre (pure)

double TMCostSince(NSDictionary<NSString *, NSNumber *> *buckets, NSTimeInterval startEpoch) {
    if (![buckets isKindOfClass:NSDictionary.class]) return 0;
    double total = 0;
    for (NSString *hourKey in buckets) {
        if (hourKey.doubleValue >= startEpoch) total += buckets[hourKey].doubleValue;
    }
    return total;
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

// Accumule le coût d'un lot de tokens dans les tranches et le compteur d'inconnus d'un fichier.
static void TMAccumulate(NSMutableDictionary *buckets, double *unpriced, TMTokens t, NSString *model,
                         TMCostProvider provider, NSTimeInterval epoch) {
    TMPrices prices;
    if (model && TMPricesForModel(model, &prices)) {
        double cost = TMCostForTokens(t, prices, provider);
        NSString *hour = TMHourKey(epoch);
        buckets[hour] = @([buckets[hour] doubleValue] + cost);
    } else {
        *unpriced += t.input + t.output + t.cacheRead + t.cacheWrite;  // comptés à part, jamais chiffrés
    }
}

// Un fichier Claude : une ligne = un message additif. Chaque usage est chiffré à son heure.
static NSDictionary *TMScanClaudeFile(NSString *path) {
    NSMutableDictionary *buckets = [NSMutableDictionary dictionary];
    __block double unpriced = 0;
    TMEnumerateMatchingLines(path, "\"usage\"", ^(NSDictionary *line) {
        TMTokens t; NSString *model = nil;
        if (!TMParseClaudeUsageLine(line, &t, &model)) return;
        NSString *ts = [line[@"timestamp"] isKindOfClass:NSString.class] ? line[@"timestamp"] : nil;
        TMAccumulate(buckets, &unpriced, t, model, TMCostProviderClaude, TMParseISO(ts));
    });
    return @{ @"buckets": buckets, @"unpriced": @(unpriced) };
}

// Un fichier Codex : total_token_usage est CUMULÉ par session. On retient le dernier, avec le
// modèle vu en cours de route (absent du token_count lui-même), à l'heure du dernier événement.
// Balayage octets à deux marqueurs, pour ne parser que les lignes portant un modèle ou un total.
static NSDictionary *TMScanCodexFile(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path options:NSDataReadingMappedIfSafe error:nil];
    NSMutableDictionary *buckets = [NSMutableDictionary dictionary];
    double unpriced = 0;
    if (!data.length) return @{ @"buckets": buckets, @"unpriced": @0 };
    const char *bytes = data.bytes; NSUInteger len = data.length, start = 0;
    NSString *model = nil; NSDictionary *lastTotal = nil; NSString *lastTs = nil;
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
                NSString *m = [line[@"model"] isKindOfClass:NSString.class] ? line[@"model"] : payload[@"model"];
                if ([m isKindOfClass:NSString.class]) model = m;
                NSDictionary *info = [payload[@"info"] isKindOfClass:NSDictionary.class] ? payload[@"info"] : nil;
                if (info[@"total_token_usage"]) {
                    lastTotal = info;
                    lastTs = [line[@"timestamp"] isKindOfClass:NSString.class] ? line[@"timestamp"] : lastTs;
                }
            }
        }
        start = i + 1;
    }
    TMTokens t; NSString *tokenModel = nil;
    if (lastTotal && TMParseCodexTokenCount(lastTotal, &t, &tokenModel)) {
        TMAccumulate(buckets, &unpriced, t, tokenModel ?: model, TMCostProviderOpenAI, TMParseISO(lastTs));
    }
    return @{ @"buckets": buckets, @"unpriced": @(unpriced) };
}

// La fenêtre la plus longue affichée est de 7 jours : les sessions plus anciennes ne peuvent
// contribuer à aucun coût de fenêtre. On les ignore — ce qui rend le balayage à froid tenable.
static const NSTimeInterval TMCostMaxAge = 8 * 86400;
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

NSDictionary *TMScanTerminalCosts(void) {
    NSDictionary *cache = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:TMCostCachePath()] ?: [NSData data] options:0 error:nil];
    NSDictionary *cachedFiles = [cache[@"files"] isKindOfClass:NSDictionary.class] ? cache[@"files"] : @{};
    NSMutableDictionary *files = [NSMutableDictionary dictionary];  // path -> {fp, provider, buckets, unpriced}

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
            NSDictionary *parsed = [provider isEqualToString:@"claude"] ? TMScanClaudeFile(path) : TMScanCodexFile(path);
            files[path] = @{ @"fp": fp, @"provider": provider, @"buckets": parsed[@"buckets"], @"unpriced": parsed[@"unpriced"] };
        }
    }

    // Agrège par fournisseur. Les fichiers disparus du disque sortent naturellement (absents de `files`).
    NSMutableDictionary *claudeBuckets = [NSMutableDictionary dictionary], *codexBuckets = [NSMutableDictionary dictionary];
    double claudeUnpriced = 0, codexUnpriced = 0;
    for (NSDictionary *entry in files.allValues) {
        BOOL isClaude = [entry[@"provider"] isEqualToString:@"claude"];
        NSMutableDictionary *dst = isClaude ? claudeBuckets : codexBuckets;
        for (NSString *hour in entry[@"buckets"]) dst[hour] = @([dst[hour] doubleValue] + [entry[@"buckets"][hour] doubleValue]);
        if (isClaude) claudeUnpriced += [entry[@"unpriced"] doubleValue]; else codexUnpriced += [entry[@"unpriced"] doubleValue];
    }

    NSData *out = [NSJSONSerialization dataWithJSONObject:@{ @"files": files } options:0 error:nil];
    [out writeToFile:TMCostCachePath() atomically:YES];

    return @{ @"claude": @{ @"buckets": claudeBuckets, @"unpriced": @(claudeUnpriced) },
              @"codex":  @{ @"buckets": codexBuckets,  @"unpriced": @(codexUnpriced) } };
}
