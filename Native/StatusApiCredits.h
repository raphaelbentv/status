// StatusApiCredits — comptes API Anthropic et OpenAI : dépense et crédit restant.
//
// Ni Anthropic ni OpenAI n'exposent le solde de crédits prépayés par API (vérifié en
// octobre 2026). Les deux Admin API donnent en revanche le coût par jour UTC :
//   Anthropic : GET https://api.anthropic.com/v1/organizations/cost_report (clé sk-ant-admin…)
//   OpenAI    : GET https://api.openai.com/v1/organization/costs            (clé sk-admin-…)
// Le crédit restant est donc une ESTIMATION : solde saisi par l'utilisateur, moins ce qui a été
// dépensé depuis la saisie. Les organisations en recharge automatique ou facturées au mois
// suivent plutôt un budget mensuel.
//
// Comme StatusAccounts, ce module ne dépend que de Foundation : il ne connaît ni le Trousseau, ni
// l'interface. Les clés n'y transitent que pour construire une requête. Voir Tests/native-tests.m.
//
// Un compte API, forme normalisée (plist-safe, rien de secret) :
//   { accountId, provider, label, mode, balanceUSD, balanceSetAt, baselineUSD, baselinePending,
//     budgetUSD }
// mode : « none » (dépense seule), « prepaid » (solde saisi) ou « budget » (budget mensuel).

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

extern NSString *const TMApiProviderAnthropic;  // « anthropic »
extern NSString *const TMApiProviderOpenAI;     // « openai »
extern NSString *const TMApiAccountsDefaultsKey;
extern const NSInteger TMMaxApiAccountsPerProvider;

#pragma mark - Registre

// Écarte les entrées illisibles, comble les champs, dédoublonne, plafonne par fournisseur. Un
// mode dont la valeur de référence manque retombe sur « none » plutôt que d'afficher une jauge
// fausse.
NSArray<NSDictionary *> *TMNormalizeApiRegistry(id _Nullable raw);
NSDictionary * _Nullable TMApiAccountWithID(NSArray *registry, NSString * _Nullable accountId);
NSArray<NSDictionary *> *TMApiAccountsForProvider(NSArray *registry, NSString *provider);
// Nom affiché : le label s'il existe, sinon « Anthropic API 2 ».
NSString *TMApiAccountDisplayLabel(NSDictionary *account, NSInteger indexInProvider);

// Toutes renvoient un nouveau registre normalisé ; nil si l'opération est impossible.
NSArray * _Nullable TMApiRegistryAdding(NSArray *registry, NSString *provider, NSString *accountId);
NSArray *TMApiRegistryRemoving(NSArray *registry, NSString *accountId);
NSArray *TMApiRegistrySettingLabel(NSArray *registry, NSString *accountId, NSString *label);
// Nouveau solde : la saisie repart de maintenant. La dépense déjà comptée ce jour-là est inconnue
// tant que le prochain relevé n'a pas répondu : baselinePending la fait mesurer à ce moment-là.
NSArray *TMApiRegistrySettingBalance(NSArray *registry, NSString *accountId, double balanceUSD,
                                     NSTimeInterval now);
// Recharge : s'ajoute au solde sans déplacer la date de saisie. Sans effet hors mode prepaid.
NSArray *TMApiRegistryAddingCredit(NSArray *registry, NSString *accountId, double amountUSD);
NSArray *TMApiRegistrySettingBudget(NSArray *registry, NSString *accountId, double budgetUSD);
NSArray *TMApiRegistryClearingMode(NSArray *registry, NSString *accountId);
// Fixe la ligne de base des comptes en attente, avec la dépense du jour de saisie lue dans `daily`.
// Si ce jour n'est plus le jour courant (relevé en échec toute une journée), la base vaut 0 :
// l'estimation est alors pessimiste, jamais optimiste.
NSArray *TMApiRegistryResolvingBaseline(NSArray *registry, NSString *accountId,
                                        NSDictionary<NSString *, NSNumber *> *daily, NSTimeInterval now);

#pragma mark - Saisies

// Montant en dollars saisi à la main : « 12,50 », « 12.50 », « $1 234 », « 1,234.5 ». NO pour un
// texte vide, négatif, non numérique ou supérieur à 10 millions.
BOOL TMParseUSDAmount(NSString * _Nullable text, double *outValue);
// Clé collée : espaces et retours à la ligne retirés.
NSString *TMApiKeyCleaned(NSString * _Nullable raw);
// Forme attendue d'une clé d'administration : préfixe du fournisseur, 20 à 512 caractères sûrs.
// Une clé d'API ordinaire (sk-ant-api…, sk-proj-…) est refusée : les Admin API la rejetteraient.
BOOL TMApiKeyHasExpectedShape(NSString *provider, NSString *key);
// Nom de l'entrée du Trousseau d'un compte.
NSString *TMApiKeychainAccount(NSString *accountId);

#pragma mark - Réseau

// Seuls https://api.anthropic.com et https://api.openai.com sont permis : ni autre hôte, ni port,
// ni identifiants dans l'URL. Une redirection doit aussi passer par ce filtre.
BOOL TMApiURLAllowed(NSURL * _Nullable url);
// Requête d'une page du rapport de coûts, à partir de `start` (secondes epoch), buckets d'un jour.
// nil si le fournisseur est inconnu ou si l'URL ne passe pas le filtre.
NSMutableURLRequest * _Nullable TMApiCostRequest(NSString *provider, NSString *key, NSTimeInterval start,
                                                 NSString * _Nullable page, NSString *userAgent);
// Une page de réponse → { days: { "<début du jour UTC en secondes>": dollars }, nextPage: "" }.
// nil si la forme est inattendue. Anthropic donne des cents en chaîne décimale, OpenAI des
// dollars en nombre.
NSDictionary * _Nullable TMApiParseCostPage(NSString *provider, id _Nullable json);
// Clé i18n d'un échec HTTP : auth (401/403), notFound, rateLimited, server, http.
NSString *TMApiErrorKey(NSInteger status);

#pragma mark - Calcul

NSTimeInterval TMUTCDayStart(NSTimeInterval t);
NSTimeInterval TMUTCMonthStart(NSTimeInterval t);
// Premier jour à relever : début du mois UTC, ou jour de saisie du solde s'il est antérieur.
NSTimeInterval TMApiQueryStart(NSDictionary *account, NSTimeInterval now);
// Fusionne un relevé frais dans l'existant (le frais l'emporte) et oublie les jours avant `keepFrom`.
NSDictionary<NSString *, NSNumber *> *TMApiDailyMerging(NSDictionary * _Nullable old,
                                                        NSDictionary * _Nullable fresh,
                                                        NSTimeInterval keepFrom);
// Synthèse d'un compte :
//   mode, todayUSD, monthUSD ; en prepaid sinceSetUSD ; hors mode none : remainingUSD,
//   referenceUSD (solde ou budget), fraction (reste / référence, 0…1) et severity (0, 1, 2).
// Sévérité : prepaid, 2 à 0 $ et 1 sous `alertBelowUSD` ; budget, 2 à 100 % et 1 à 80 %.
NSDictionary *TMApiSummary(NSDictionary *account, NSDictionary * _Nullable daily, NSTimeInterval now,
                           double alertBelowUSD);
// Compte montré par le widget d'un fournisseur : l'épinglé s'il a une jauge, sinon celui qui a la
// plus petite fraction restante. nil si aucun compte du fournisseur n'a de jauge.
NSDictionary * _Nullable TMApiWidgetPick(NSArray<NSDictionary *> *summaries, NSString *provider,
                                         NSString * _Nullable pinnedAccountId);

#pragma mark - Alertes

// Décisions de notification, avec hystérésis. `state` persiste entre deux relevés (et deux
// lancements) ; clés « <accountId>:<kind> ». Renvoie { state, fire: [ { accountId, kind } ] }
// avec kind ∈ low, empty, budget80, budget100 — une seule notification par compte et par passage,
// la plus grave. Désactivé : rien ne part, mais l'état suit pour ne pas tout déclencher au
// réveil de l'alerte.
NSDictionary *TMApiAlertDecisions(NSDictionary * _Nullable state, NSArray<NSDictionary *> *summaries,
                                  double thresholdUSD, BOOL enabled);

#pragma mark - Affichage

// « 12,40 $ » / « $12.40 » selon la langue ; à partir de 100 $, sans centimes.
NSString *TMFormatUSD(double value, NSString *localeIdentifier);

NS_ASSUME_NONNULL_END
