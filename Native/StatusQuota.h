// StatusQuota — logique pure de Status : parsing des quotas, fenêtres, cookies, historique.
//
// Ce module ne dépend que de Foundation : aucune UI, aucun réseau, aucun état d'application. C'est
// délibéré — c'est la partie où se cachent les vrais bugs (formats non documentés, fenêtres
// expirées, collages hétérogènes), donc c'est la partie qui doit être testable sans lancer l'app.
// Voir Tests/native-tests.m.
//
// Vocabulaire d'une « fenêtre » (window), forme normalisée produite ici et consommée par le JS :
//   { label, windowId, usedPercent, remainingPercent, resetsAt }

#import <Foundation/Foundation.h>

#pragma mark - Coercition défensive
// Les payloads viennent d'API non documentées : tout champ peut manquer ou changer de type.
double TMNumber(id value);
long long TMInteger(id value);
NSDate *TMParseISODate(NSString *value);

#pragma mark - Cookies
// Accepte un en-tête Cookie brut ou un collage « Copier comme cURL » ; renvoie @"" si absent.
NSString *TMExtractCookieHeader(NSString *input);
// Convertit un en-tête en cookies pour le store WebKit. Les cookies Cloudflare sont écartés.
NSArray<NSHTTPCookie *> *TMCookiesFromHeader(NSString *header);

#pragma mark - Fenêtres de quota
NSString *TMQuotaWindowLabel(long long minutes);
NSString *TMClaudeWindowLabel(NSString *name);
// Unique source des quotas Claude : réponse de claude.ai /api/organizations/{org}/usage.
NSArray *TMClaudeWindowsFromUsagePayload(NSDictionary *payload);
// Écarte les fenêtres dont le reset est passé : leur pourcentage ne veut plus rien dire.
NSArray *TMDropExpiredWindows(NSArray *windows);

BOOL TMWindowIsSession(NSDictionary *window);
BOOL TMWindowIsWeekly(NSDictionary *window);
// Fenêtre hebdo « scoped » : un sous-quota dédié à un modèle (seven_day_scoped_fable), distinct de
// la semaine générale. À agréger séparément — fondre son pourcentage dans « semaine » ferait dire
// à l'icône autre chose que ce que les cartes de l'app affichent.
BOOL TMWindowIsScopedWeekly(NSDictionary *window);

#pragma mark - Notifications de quota

// Décisions de notification entre deux observations des fenêtres : seuils franchis et
// réinitialisations hebdomadaires. Pur — l'appelant poste les notifications et persiste l'état.
//   state  : état persistant (plist-safe) — { "th:<provider>:<id>@<resetsAt>": niveau déjà notifié,
//            "reset:<provider>:<id>": dernier resetsAt connu }. nil = première observation.
//   pairs  : [[provider, fenêtres], …] — fenêtres normalisées (voir en tête de fichier).
//   levels : seuils croissants de % consommé (ex. @[@80, @95]) ; un franchissement notifie le plus
//            haut niveau atteint, une seule fois par niveau et par période — la clé inclut
//            resetsAt, une nouvelle période réarme donc tout. Vide = seuils coupés.
//   weeklyResets : notifier quand une fenêtre HEBDO tourne. Deux signaux, tous deux corroborés
//            par une baisse du compteur — la fenêtre OpenAI est glissante, sa date dérive au fil
//            de l'activité sans que rien ne se recharge, la date seule ne prouve donc rien :
//            resetsAt qui avance avec une consommation retombée d'au moins 20 points, ou
//            l'effondrement du pourcentage (≥ 25 % → ≤ 5 %) à date inchangée (recharge OpenAI en
//            plein milieu de semaine). Une seule notification par période, même si deux sources
//            oscillent ; une semaine restée légère tourne sans bruit (rien ne contraignait). Les
//            fenêtres session (5 h) ne notifient jamais : il y en a plusieurs par jour.
//   now    : epoch (s), pour purger du nouvel état les clés de périodes passées.
// Retourne { events: [ { kind: "threshold"|"reset", provider, label, level, usedPercent,
//            resetsAt } ], state: nouvel état }, events dans l'ordre des fenêtres fournies.
NSDictionary *TMQuotaNotificationDecisions(NSDictionary *state, NSArray *pairs,
                                           NSArray<NSNumber *> *levels, BOOL weeklyResets,
                                           NSTimeInterval now);
BOOL TMMaxUsedPercent(NSArray<NSArray *> *windowArrays, BOOL (^predicate)(NSDictionary *window), double *outValue);

#pragma mark - Payloads de compte
NSDictionary *TMDisconnectedOpenAIAccount(NSString *error);
NSDictionary *TMOpenAIAccountPayload(NSDictionary *account, NSDictionary *rateResponse, BOOL connecting, NSString *error);
// Compte Claude sans source exploitable : ni cookie, ni organisation résolue.
NSDictionary *TMEmptyClaudeAccount(void);

#pragma mark - Historique local
NSString *TMSupportDirectory(void);
NSString *TMHistoryPath(void);
NSArray *TMLoadHistory(void);

// Cache du dernier état de comptes connu (volumes courants), pour réafficher les volumes tout de
// suite au lancement au lieu d'attendre le premier sondage. Écriture atomique. `accounts` est un
// dictionnaire { "openai": <payload>, "claude": <payload> } ; seul le contenu sérialisable en JSON
// est conservé. Le chargement renvoie nil si rien n'est en cache ou si le fichier est illisible.
NSString *TMAccountsCachePath(void);
void TMSaveAccountsCache(NSDictionary *accounts);
NSDictionary *TMLoadAccountsCache(void);

// Historique système long (24 h, une ligne par minute) — voir TMLongHistoryAppend. Persisté à part
// de l'historique quota : cadence, durée de vie et contenu n'ont rien à voir. Écriture atomique ;
// un fichier illisible se solde par un historique vide, jamais par un échec de lancement.
NSString *TMMetricsHistoryPath(void);
void TMSaveMetricsHistory(NSArray *rows);
NSArray *TMLoadMetricsHistory(void);

// Historique en CSV, format long : une ligne par (instant, fenêtre). Colonnes
// timestamp_unix, date_iso_utc, fenetre, pourcent. Le format long tient sans peine des fenêtres
// qui apparaissent et disparaissent (Fable, limites OpenAI), là où un format large laisserait des
// trous et changerait de colonnes au fil du temps. Trié par instant croissant.
NSString *TMHistoryToCSV(NSArray *history);


// Instant d'épuisement prévu d'une fenêtre, extrapolé de son historique récent — « au rythme
// actuel, épuisé jeudi à 16 h », l'information qui fait décider là où « 78 % » ne fait que
// constater. `history` est le format de TMLoadHistory : [{ t: secondes, p: { clé: pourcent } }].
//
// NO — et *outAt intact — dans tous les cas où une prévision mentirait :
//   — moins de deux points, ou moins de TMForecastMinimumSpan entre le premier et le dernier ;
//   — consommation stable ou en baisse (pente ≤ 0) : rien ne permet d'annoncer un épuisement ;
//   — épuisement prévu après `resetsAt` : la fenêtre tient jusqu'à sa réinitialisation, ce qui
//     est une réponse en soi et non une prévision.
// Les points antérieurs à la dernière réinitialisation sont écartés : la chute de 90 % à 5 %
// qu'elle provoque donnerait une pente absurde.
// Santé de la source directe claude.ai.

// Détecteur de front : YES seulement au passage de « frais » à « périmé », pour n'alerter qu'une
// fois par épisode. `wasStale` est l'état persistant, mis à jour par l'appel ; il se réarme dès
// que la source redevient fraîche, de sorte qu'une nouvelle péremption réalerte.
BOOL TMStaleAlertShouldFire(BOOL *wasStale, BOOL isStale);

// Chien de garde de la WebView. `failures` est le compteur persistant. Un succès le remet à zéro
// et renvoie NO. Un échec l'incrémente ; quand il atteint `threshold`, renvoie YES *une fois* et
// se réarme (retour à zéro) — sinon on rechargerait la WebView à chaque tick d'un échec durable.
BOOL TMWatchdogShouldReload(NSInteger *failures, BOOL success, NSInteger threshold);

extern const NSTimeInterval TMForecastMinimumSpan;
BOOL TMForecastExhaustion(NSArray *history, NSString *key, NSTimeInterval resetsAt, NSTimeInterval *outAt);
#pragma mark - Clés d'historique par compte
// Forme : `<provider>:<accountId>:<windowId>`. L'accountId est dans la clé, jamais le libellé :
// renommer un compte réécrirait sinon tout son historique. Le libellé est résolu à l'affichage.
NSString *TMHistoryKey(NSString *provider, NSString *accountId, NSString *windowId);
NSString *TMHistoryKeyProvider(NSString *key);
// @"" pour une clé héritée (mono-compte), qui n'en porte pas.
NSString *TMHistoryKeyAccountID(NSString *key);
NSString *TMHistoryKeyWindowID(NSString *key);

// Réécrit les clés héritées vers le compte migré de leur fournisseur. Idempotent : une clé qui
// porte déjà un accountId traverse sans changement — la forme de l'UUID suffit à les distinguer,
// donc aucun drapeau persistant n'est nécessaire.
NSArray *TMMigrateHistoryKeys(NSArray *history, NSString *openaiAccountId, NSString *claudeAccountId);

// Retire toutes les clés d'un compte. Sans cela, supprimer un compte laisserait dans le graphe des
// séries orphelines que plus rien ne permet de nommer.
NSArray *TMHistoryDroppingAccount(NSArray *history, NSString *accountId);

#pragma mark - Métrique de la barre des menus
// Grammaire de `menuBarMetric`, côté quotas :
//   "lowest"                              — la fenêtre générale la plus consommée, tous comptes ;
//   "<provider>:<kind>"                   — agrégat : le maximum des comptes du fournisseur ;
//   "acct:<provider>:<accountId>:<kind>"  — un compte précis.
// `kind` ∈ { "session", "weekly", "weekly-fable" }. Le fournisseur figure dans la forme épinglée
// pour qu'un compte supprimé retombe sur l'agrégat de SON fournisseur plutôt que sur du vide.
BOOL TMWindowMatchesKind(NSDictionary *window, NSString *kind);
NSString *TMPinnedMetricForAccount(NSString *provider, NSString *accountId, NSString *kind);

// `accounts` : [ { accountId, provider, label, windows } ] dans l'ordre d'affichage.
// nil si aucune valeur n'est disponible ; sinon
//   { usedPercent, provider, accountId, label, kind, shortLabel, aggregated }
NSDictionary *TMResolveMenuBarMetric(NSString *metric, NSArray *accounts);

// Une clé d'historique participe-t-elle à la sparkline de cette métrique ?
BOOL TMHistoryKeyMatchesMetric(NSString *key, NSString *metric);

// `pairs` : [ [provider, accountId, fenêtres] ].
NSArray *TMAppendHistory(NSArray *pairs, long long now);
