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
// Source officielle : snapshot écrit par la status line de Claude Code.
NSArray *TMClaudeWindowsFromSnapshot(NSDictionary *snapshot);
// Source non officielle : réponse de claude.ai /api/organizations/{org}/usage.
NSArray *TMClaudeWindowsFromUsagePayload(NSDictionary *payload);
// Écarte les fenêtres dont le reset est passé : leur pourcentage ne veut plus rien dire.
NSArray *TMDropExpiredWindows(NSArray *windows);

BOOL TMWindowIsSession(NSDictionary *window);
BOOL TMWindowIsWeekly(NSDictionary *window);
BOOL TMMaxUsedPercent(NSArray<NSArray *> *windowArrays, BOOL (^predicate)(NSDictionary *window), double *outValue);

#pragma mark - Payloads de compte
NSDictionary *TMDisconnectedOpenAIAccount(NSString *error);
NSDictionary *TMOpenAIAccountPayload(NSDictionary *account, NSDictionary *rateResponse, BOOL connecting, NSString *error);
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
NSArray *TMAppendHistory(NSArray *claudeWindows, NSArray *openAIWindows, long long now);
