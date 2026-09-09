#import "StatusAccounts.h"

NSString *const TMProviderOpenAI = @"openai";
NSString *const TMProviderClaude = @"claude";
const NSInteger TMMaxAccountsPerProvider = 5;
NSString *const TMAccountsDefaultsKey = @"accounts";

static NSString *TMString(id value) {
    return [value isKindOfClass:NSString.class] ? value : @"";
}

#pragma mark - Identifiants

NSString *TMNewAccountID(void) {
    return NSUUID.UUID.UUIDString;
}

BOOL TMIsAccountID(NSString *value) {
    if (![value isKindOfClass:NSString.class] || value.length != 36) return NO;
    return [[NSUUID alloc] initWithUUIDString:value] != nil;
}

static BOOL TMKnownProvider(NSString *provider) {
    return [provider isEqualToString:TMProviderOpenAI] || [provider isEqualToString:TMProviderClaude];
}

#pragma mark - Lecture

NSArray<NSDictionary *> *TMNormalizeAccountRegistry(id raw) {
    if (![raw isKindOfClass:NSArray.class]) return @[];
    NSMutableArray *kept = [NSMutableArray array];
    NSMutableSet *seenIDs = [NSMutableSet set];
    NSMutableDictionary<NSString *, NSNumber *> *counts = [NSMutableDictionary dictionary];

    for (id entry in (NSArray *)raw) {
        if (![entry isKindOfClass:NSDictionary.class]) continue;
        NSDictionary *account = entry;
        NSString *accountId = TMString(account[@"accountId"]);
        NSString *provider = TMString(account[@"provider"]);
        // Un compte sans identifiant valide n'a pas de clé d'historique et ne peut pas être sondé :
        // le garder ne produirait qu'une carte fantôme.
        if (!TMIsAccountID(accountId) || !TMKnownProvider(provider)) continue;
        if ([seenIDs containsObject:accountId]) continue;
        NSInteger used = counts[provider].integerValue;
        if (used >= TMMaxAccountsPerProvider) continue;
        counts[provider] = @(used + 1);
        [seenIDs addObject:accountId];
        [kept addObject:@{
            @"accountId": accountId,
            @"provider": provider,
            @"label": TMString(account[@"label"]),
            @"orgId": TMString(account[@"orgId"]),
            @"orgName": TMString(account[@"orgName"]),
            @"claudeSource": TMString(account[@"claudeSource"]),
            @"order": @(kept.count)
        }];
    }
    return kept;
}

NSArray<NSDictionary *> *TMAccountsForProvider(NSArray *registry, NSString *provider) {
    NSMutableArray *matches = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeAccountRegistry(registry)) {
        if ([account[@"provider"] isEqualToString:provider]) [matches addObject:account];
    }
    return matches;
}

NSDictionary *TMAccountWithID(NSArray *registry, NSString *accountId) {
    if (!accountId.length) return nil;
    for (NSDictionary *account in TMNormalizeAccountRegistry(registry)) {
        if ([account[@"accountId"] isEqualToString:accountId]) return account;
    }
    return nil;
}

BOOL TMProviderIsFull(NSArray *registry, NSString *provider) {
    return TMAccountsForProvider(registry, provider).count >= (NSUInteger)TMMaxAccountsPerProvider;
}

NSString *TMAccountDisplayLabel(NSDictionary *account, NSInteger indexInProvider) {
    NSString *label = TMString(account[@"label"]);
    if (label.length) return label;
    // Numérotation par fournisseur plutôt que le nom fourni par le service. Un « OpenAI 2 » tient
    // dans une pastille de barre des menus, ne change pas quand une organisation se renomme, et
    // ne vieillit pas comme le ferait « nouveau » à l'arrivée d'un troisième compte. L'identité
    // réelle — e-mail, organisation — reste affichée en sous-titre du compte.
    NSString *provider = TMString(account[@"provider"]);
    NSString *name = [provider isEqualToString:TMProviderOpenAI] ? @"OpenAI" : @"Claude";
    return [NSString stringWithFormat:@"%@ %ld", name, (long)(indexInProvider + 1)];
}

#pragma mark - Écriture

NSArray<NSDictionary *> *TMRegistryAdding(NSArray *registry, NSString *provider,
                                          NSString *accountId, NSString *label) {
    NSArray *current = TMNormalizeAccountRegistry(registry);
    if (!TMKnownProvider(provider) || !TMIsAccountID(accountId)) return nil;
    if (TMProviderIsFull(current, provider)) return nil;
    NSMutableArray *next = [current mutableCopy];
    [next addObject:@{
        @"accountId": accountId, @"provider": provider,
        @"label": label.length ? label : @"", @"orgId": @"", @"orgName": @"",
        @"order": @(next.count)
    }];
    return TMNormalizeAccountRegistry(next);
}

NSArray<NSDictionary *> *TMRegistryRemoving(NSArray *registry, NSString *accountId) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeAccountRegistry(registry)) {
        if ([account[@"accountId"] isEqualToString:accountId]) continue;
        [next addObject:account];
    }
    return TMNormalizeAccountRegistry(next);
}

NSArray<NSDictionary *> *TMRegistrySetting(NSArray *registry, NSString *accountId,
                                           NSString *field, id value) {
    NSMutableArray *next = [NSMutableArray array];
    for (NSDictionary *account in TMNormalizeAccountRegistry(registry)) {
        if (![account[@"accountId"] isEqualToString:accountId]) { [next addObject:account]; continue; }
        NSMutableDictionary *updated = [account mutableCopy];
        updated[field] = TMString(value);
        [next addObject:updated];
    }
    return TMNormalizeAccountRegistry(next);
}

#pragma mark - Migration

NSDictionary *TMMigrateLegacyRegistry(NSArray *registry) {
    NSArray *current = TMNormalizeAccountRegistry(registry);
    if (current.count) return @{ @"registry": current };

    // Un compte par fournisseur : c'est exactement ce que l'installation mono-compte affichait, et
    // les cartes vides sont celles qui invitent à se connecter. En créer zéro laisserait un
    // tableau de bord muet après mise à jour.
    NSString *openaiID = TMNewAccountID();
    NSString *claudeID = TMNewAccountID();
    NSArray *next = TMRegistryAdding(current, TMProviderOpenAI, openaiID, @"");
    next = TMRegistryAdding(next, TMProviderClaude, claudeID, @"");
    return @{ @"registry": next ?: @[], @"openaiAccountId": openaiID, @"claudeAccountId": claudeID };
}

NSDictionary *TMMigrateLegacyAccountsCache(id cache, NSString *openaiAccountId,
                                           NSString *claudeAccountId) {
    if (![cache isKindOfClass:NSDictionary.class]) return @{};
    NSDictionary *source = cache;
    NSMutableDictionary *out = [NSMutableDictionary dictionary];
    for (NSString *key in source) {
        id payload = source[key];
        if (![payload isKindOfClass:NSDictionary.class]) continue;
        // Déjà au nouveau format : les clés y sont des accountId.
        if (TMIsAccountID(key)) { out[key] = payload; continue; }
        NSString *target = [key isEqualToString:TMProviderOpenAI] ? openaiAccountId
                         : [key isEqualToString:TMProviderClaude] ? claudeAccountId : nil;
        if (target.length) out[target] = payload;
    }
    return out;
}
