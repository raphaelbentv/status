// StatusAccounts — registre des comptes de Status.
//
// Status suit N comptes par fournisseur. Ce module détient la liste : qui existe, dans quel ordre,
// sous quel nom. Il ne connaît ni le réseau, ni les quotas, ni l'interface — comme StatusQuota, il
// ne dépend que de Foundation, et pour la même raison : c'est là que se cachent les bugs coûteux
// (identifiants qui dérivent, migrations non idempotentes) et il doit être testable sans lancer
// l'app. Voir Tests/native-tests.m.
//
// Un compte, forme normalisée (plist-safe) :
//   { accountId, provider, label, order, orgId }
//
// L'accountId est un UUID généré à l'ajout, jamais dérivé de l'e-mail ni de l'org id. Ceux-là
// changent — un e-mail se modifie, une organisation se renomme — et l'accountId sert de clé
// d'historique : le voir changer effacerait les courbes du compte.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

// Ne sélectionne jamais une autre organisation que celle attendue. Sans identité préalable,
// seule une liste à une entrée est résolue automatiquement.
NSDictionary * _Nullable TMClaudeWebOrganization(NSArray *organizations, NSString *expectedOrgId);

extern NSString *const TMProviderOpenAI;
extern NSString *const TMProviderClaude;

// Chaque compte coûte un processus (OpenAI) ou une WebView (Claude). Une limite explicite vaut
// mieux qu'une dégradation silencieuse.
extern const NSInteger TMMaxAccountsPerProvider;

// Clé de NSUserDefaults où vit le registre. Rien de secret n'y figure : les cookies restent au
// Trousseau, une entrée par compte.
extern NSString *const TMAccountsDefaultsKey;

#pragma mark - Identifiants

NSString *TMNewAccountID(void);
// YES pour la forme d'un UUID. Sert à distinguer une clé d'historique déjà migrée
// (`claude:<uuid>:seven_day`) d'une clé héritée (`claude:seven_day`) — donc à rendre la migration
// idempotente sans drapeau persistant.
BOOL TMIsAccountID(NSString * _Nullable value);

#pragma mark - Lecture du registre

// Normalise ce qui sort des préférences : écarte les entrées illisibles ou sans fournisseur connu,
// comble les champs manquants, dédoublonne les identifiants, renumérote `order` et plafonne à
// TMMaxAccountsPerProvider. Un registre corrompu se solde par un registre vide, jamais par un
// plantage au lancement.
NSArray<NSDictionary *> *TMNormalizeAccountRegistry(id _Nullable raw);

NSArray<NSDictionary *> *TMAccountsForProvider(NSArray *registry, NSString *provider);
NSDictionary * _Nullable TMAccountWithID(NSArray *registry, NSString * _Nullable accountId);
BOOL TMProviderIsFull(NSArray *registry, NSString *provider);

// Nom affiché : le label s'il existe, sinon un repli numéroté lisible (« Compte Claude 2 »).
NSString *TMAccountDisplayLabel(NSDictionary *account, NSInteger indexInProvider);

#pragma mark - Écriture du registre
// Toutes ces fonctions renvoient un nouveau registre normalisé. Aucune ne modifie son entrée.

// nil si le fournisseur est plein — l'appelant affiche l'explication plutôt que d'ajouter en
// silence un compte qui ne serait jamais sondé.
NSArray<NSDictionary *> * _Nullable TMRegistryAdding(NSArray *registry, NSString *provider,
                                                     NSString *accountId, NSString * _Nullable label);
NSArray<NSDictionary *> *TMRegistryRemoving(NSArray *registry, NSString *accountId);
NSArray<NSDictionary *> *TMRegistrySetting(NSArray *registry, NSString *accountId,
                                           NSString *field, id _Nullable value);

#pragma mark - Migration depuis l'état mono-compte

// Crée un compte par fournisseur à partir de l'installation mono-compte, une seule fois : le
// registre existant est renvoyé tel quel s'il n'est pas vide. Les identifiants produits sont ceux
// vers lesquels l'historique hérité doit être réécrit (voir TMMigrateHistoryKeys) et vers lequel
// l'entrée Trousseau `claude-session-cookie` doit être déplacée.
//
// Retourne { registry, openaiAccountId, claudeAccountId }.
NSDictionary *TMMigrateLegacyRegistry(NSArray * _Nullable registry);

// Ancien cache de comptes { openai: …, claude: … } vers la forme par compte
// { <accountId>: … }. Un cache déjà au nouveau format traverse sans changement.
NSDictionary *TMMigrateLegacyAccountsCache(id _Nullable cache, NSString * _Nullable openaiAccountId,
                                           NSString * _Nullable claudeAccountId);

NS_ASSUME_NONNULL_END
