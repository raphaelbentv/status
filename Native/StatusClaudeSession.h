// StatusClaudeSession — une session claude.ai par compte.
//
// claude.ai est derrière Cloudflare, dont le défi est une preuve de travail JavaScript : une
// requête NSURLSession reçoit une page 403 « Just a moment… » quelles que soient ses en-têtes, et
// le cookie cf_clearance est lié à l'IP et à l'User-Agent qui l'ont gagné. Seul un vrai contexte
// WebKit passe et continue de passer : il exécute le défi et regagne cf_clearance tout seul. Le
// cookie collé n'est donc qu'une amorce pour sessionKey ; WebKit possède le reste.
//
// UNE INSTANCE PAR COMPTE, et c'est le point structurant du multi-comptes. Les cookies de claude.ai
// portent les mêmes noms sur le même domaine : deux comptes partageant un magasin de données
// s'écraseraient l'un l'autre, et l'app afficherait pour l'un les chiffres de l'autre — plausibles,
// silencieux et faux. Chaque session ouvre donc son propre WKWebsiteDataStore, identifié par
// l'accountId (macOS 14+), ce qui l'isole tout en restant persistant : la session et cf_clearance
// survivent aux redémarrages, comme avant.

#import <Foundation/Foundation.h>
#import <WebKit/WebKit.h>

NS_ASSUME_NONNULL_BEGIN

@interface TMClaudeSession : NSObject <WKNavigationDelegate>

// `accountId` doit être un UUID : il identifie le magasin de données isolé.
- (instancetype)initWithAccountID:(NSString *)accountId;
@property (readonly, copy) NSString *accountId;

// Compteurs de santé de la source, propres au compte : un cookie mort ne doit pas déclencher le
// rechargement des WebViews des autres comptes.
@property BOOL wasStale;
@property NSInteger failures;

// Amorce le magasin avec un en-tête Cookie collé, puis force un rechargement.
- (void)seedCookieHeader:(NSString *)header completion:(nullable void (^)(void))completion;

// Amorce une seule fois par valeur de cookie. Appelé avant chaque sondage : ré-injecter le même
// cookie à chaque tour invaliderait la session que WebKit entretient (et le cf_clearance qu'il a
// gagné) toutes les cinq minutes.
- (void)seedCookieIfNeeded:(NSString *)header;

// Repart de zéro : utile quand un défi Cloudflare persistant a laissé la WebView coincée hors de
// la vraie page, plutôt que d'attendre un rétablissement qui peut ne pas venir.
- (void)hardReloadWithCookieHeader:(NSString *)header completion:(nullable void (^)(void))completion;

// GET /api/organizations/{orgId}/usage — les fenêtres de quota du compte.
- (void)fetchUsage:(NSString *)orgId completion:(void (^)(NSDictionary * _Nullable json, NSError * _Nullable error))completion;

// GET /api/organizations — sert à résoudre l'org id d'un compte à partir de son seul cookie, la
// CLI locale n'étant plus consultée. Renvoie [{ uuid, name }].
- (void)fetchOrganizations:(void (^)(NSArray * _Nullable organizations, NSError * _Nullable error))completion;

// Libère la WebView et efface le magasin de données du compte. Appelé à la suppression d'un
// compte : sans cela le magasin isolé resterait sur le disque sans plus rien pour le nommer.
- (void)destroy;

@end

NS_ASSUME_NONNULL_END
