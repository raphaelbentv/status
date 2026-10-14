#import "StatusI18n.h"

static NSString *gLang;
static NSDictionary<NSString *, NSString *> *gDict;
static NSDictionary<NSString *, NSString *> *gReverse;  // texte français → clé `msg.*`
static NSDictionary<NSString *, NSString *> *gFrench;

NSArray<NSString *> *TMSupportedLanguages(void) { return @[@"fr", @"en", @"it", @"es"]; }

static NSString *TMI18nDirectory(void) {
    const char *env = getenv("STATUS_I18N_DIR");
    if (env) return @(env);
    return [NSBundle.mainBundle.resourcePath stringByAppendingPathComponent:@"i18n"];
}

static NSDictionary<NSString *, NSString *> *TMLoadDictionary(NSString *lang) {
    NSData *data = [NSData dataWithContentsOfFile:
        [TMI18nDirectory() stringByAppendingPathComponent:[lang stringByAppendingString:@".json"]]];
    id parsed = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [parsed isKindOfClass:NSDictionary.class] ? parsed : @{};
}

static NSString *TMResolveLanguage(void) {
    const char *env = getenv("STATUS_LANGUAGE");
    NSString *choice = env ? @(env) : [NSUserDefaults.standardUserDefaults stringForKey:@"language"];
    if ([TMSupportedLanguages() containsObject:choice]) return choice;
    for (NSString *preferred in NSLocale.preferredLanguages) {
        NSString *code = [preferred componentsSeparatedByString:@"-"].firstObject;
        if ([TMSupportedLanguages() containsObject:code]) return code;
    }
    return @"fr";
}

void TMI18nReload(void) {
    gLang = TMResolveLanguage();
    gFrench = TMLoadDictionary(@"fr");
    gDict = [gLang isEqualToString:@"fr"] ? gFrench : TMLoadDictionary(gLang);
    NSMutableDictionary *reverse = [NSMutableDictionary dictionary];
    [gFrench enumerateKeysAndObjectsUsingBlock:^(NSString *key, NSString *value, BOOL *stop) {
        if ([key hasPrefix:@"msg."]) reverse[value] = key;
    }];
    gReverse = reverse;
}

static void TMEnsureLoaded(void) {
    static dispatch_once_t once;
    dispatch_once(&once, ^{ TMI18nReload(); });
}

NSString *TMLanguage(void) { TMEnsureLoaded(); return gLang; }

NSString *TMLocaleIdentifier(void) {
    return @{@"fr": @"fr-FR", @"en": @"en-US", @"it": @"it-IT", @"es": @"es-ES"}[TMLanguage()];
}

NSString *TMTP(NSString *key, NSDictionary *params) {
    TMEnsureLoaded();
    NSString *text = nil;
    if (params[@"n"]) {
        NSInteger n = labs([params[@"n"] integerValue]);
        BOOL one = [gLang isEqualToString:@"fr"] ? n < 2 : n == 1;
        text = gDict[[key stringByAppendingString:one ? @".one" : @".other"]];
    }
    if (!text) text = gDict[key];
    if (!text) return key;
    for (NSString *name in params)
        text = [text stringByReplacingOccurrencesOfString:[NSString stringWithFormat:@"{%@}", name]
                                               withString:[NSString stringWithFormat:@"%@", params[name]]];
    return text;
}

NSString *TMT(NSString *key) { return TMTP(key, nil); }

NSString *TMTranslateFR(NSString *text) {
    TMEnsureLoaded();
    NSString *key = text ? gReverse[text] : nil;
    return key ? TMT(key) : text;
}

NSDictionary *TMI18nPayload(void) {
    TMEnsureLoaded();
    return @{@"lang": gLang, @"locale": TMLocaleIdentifier(), @"dict": gDict, @"reverse": gReverse};
}
