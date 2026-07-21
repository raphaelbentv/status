#import "StatusFx.h"
#import "StatusCost.h"  // TMEurPerUsd, TMFxAsOfDate — repli ultime

#pragma mark - Logique pure

BOOL TMFxShouldRefresh(NSTimeInterval fetchedAt, NSTimeInterval now, NSTimeInterval ttl) {
    if (fetchedAt <= 0) return YES;               // jamais récupéré
    return (now - fetchedAt) > ttl;               // périmé
}

BOOL TMParseFxResponse(NSDictionary *json, double *outRate, NSString **outAsOf) {
    if (![json isKindOfClass:NSDictionary.class]) return NO;
    NSDictionary *rates = [json[@"rates"] isKindOfClass:NSDictionary.class] ? json[@"rates"] : nil;
    NSNumber *eur = [rates[@"EUR"] isKindOfClass:NSNumber.class] ? rates[@"EUR"] : nil;
    if (!eur || eur.doubleValue <= 0) return NO;
    if (outRate) *outRate = eur.doubleValue;
    if (outAsOf) *outAsOf = [json[@"date"] isKindOfClass:NSString.class] ? json[@"date"] : nil;
    return YES;
}

#pragma mark - Cache + fetch (I/O)

// Taux publié une fois par jour ouvré : ~20 h de TTL suffisent à rester à jour sans marteler l'API.
static const NSTimeInterval TMFxTTL = 20 * 3600;
static NSString *const TMFxURL = @"https://api.frankfurter.dev/v1/latest?base=USD&symbols=EUR";

@implementation TMFxRate {
    double _rate;
    NSString *_asOf;
    NSTimeInterval _fetchedAt;
    BOOL _fetching;
}

+ (instancetype)shared {
    static TMFxRate *shared; static dispatch_once_t once;
    dispatch_once(&once, ^{ shared = [TMFxRate new]; [shared loadCache]; });
    return shared;
}

- (NSString *)cachePath {
    NSString *dir = NSSearchPathForDirectoriesInDomains(NSApplicationSupportDirectory, NSUserDomainMask, YES).firstObject;
    dir = [dir stringByAppendingPathComponent:@"Status"];
    [NSFileManager.defaultManager createDirectoryAtPath:dir withIntermediateDirectories:YES attributes:nil error:nil];
    return [dir stringByAppendingPathComponent:@"fx-rate.json"];
}

- (void)loadCache {
    NSDictionary *c = [NSJSONSerialization JSONObjectWithData:
        [NSData dataWithContentsOfFile:self.cachePath] ?: [NSData data] options:0 error:nil];
    if (![c isKindOfClass:NSDictionary.class]) return;
    NSNumber *rate = [c[@"rate"] isKindOfClass:NSNumber.class] ? c[@"rate"] : nil;
    if (rate && rate.doubleValue > 0) {
        _rate = rate.doubleValue;
        _asOf = [c[@"asOf"] isKindOfClass:NSString.class] ? c[@"asOf"] : nil;
        _fetchedAt = [c[@"fetchedAt"] isKindOfClass:NSNumber.class] ? [c[@"fetchedAt"] doubleValue] : 0;
    }
}

// Repli : taux en cache s'il est valide, sinon la constante compilée. Jamais de valeur inventée.
- (double)eurPerUsd { return _rate > 0 ? _rate : TMEurPerUsd; }
- (NSString *)asOfDate { return (_rate > 0 && _asOf.length) ? _asOf : TMFxAsOfDate; }

- (void)refreshIfStale {
    if (_fetching) return;
    if (!TMFxShouldRefresh(_fetchedAt, [NSDate date].timeIntervalSince1970, TMFxTTL)) return;
    _fetching = YES;
    NSURLSessionDataTask *task = [[NSURLSession sharedSession] dataTaskWithURL:[NSURL URLWithString:TMFxURL]
        completionHandler:^(NSData *data, NSURLResponse *resp, NSError *error) {
        NSDictionary *json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
        double rate = 0; NSString *asOf = nil;
        if (TMParseFxResponse(json, &rate, &asOf)) {
            NSTimeInterval now = [NSDate date].timeIntervalSince1970;
            dispatch_async(dispatch_get_main_queue(), ^{
                self->_rate = rate; self->_asOf = asOf; self->_fetchedAt = now;
                NSData *out = [NSJSONSerialization dataWithJSONObject:
                    @{ @"rate": @(rate), @"asOf": asOf ?: @"", @"fetchedAt": @(now) } options:0 error:nil];
                [out writeToFile:self.cachePath atomically:YES];
            });
        }
        // Échec (réseau coupé, réponse malformée) : on garde le cache/repli, on réessaiera plus tard.
        dispatch_async(dispatch_get_main_queue(), ^{ self->_fetching = NO; });
    }];
    [task resume];
}

@end
