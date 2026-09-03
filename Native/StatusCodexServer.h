// StatusCodexServer — dialogue JSON-RPC avec le serveur applicatif local de Codex.
//
// C'est la source *officielle* des quotas OpenAI : l'app ChatGPT embarque un binaire `codex` qui
// expose ses compteurs sur stdin/stdout. Rien à voir avec l'API facturée, et rien de scrapé.
//
// Extrait de Status.m, qui dépassait 1600 lignes. Le serveur n'a qu'une dépendance vers le reste
// de l'app — aucune : il ne connaît ni l'interface, ni les fenêtres de quota. C'est ce qui rend
// l'extraction sûre, et le module testable en isolation.

#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

typedef void (^TMAppServerCompletion)(id _Nullable result, NSError * _Nullable error);

// Chemin du binaire `codex`. Cherche l'app ChatGPT puis les emplacements d'installation usuels ;
// STATUS_CODEX_PATH force la main pour les tests. nil si rien n'est installé.
NSString * _Nullable TMCodexExecutablePath(void);

@interface TMCodexAppServer : NSObject
// Dossier d'authentification du serveur, passé en CODEX_HOME au processus fils. Un dossier par
// compte : c'est ce qui rend le multi-comptes possible, et ce qui fait qu'une déconnexion depuis
// Status ne touche plus la session Codex partagée du Mac. nil ⇒ le CODEX_HOME hérité (~/.codex).
@property (copy, nullable) NSString *codexHome;
@property (copy, nullable) void (^notificationHandler)(NSString *method, NSDictionary *params);
- (void)start:(TMAppServerCompletion)completion;
- (void)request:(NSString *)method params:(nullable NSDictionary *)params completion:(TMAppServerCompletion)completion;
- (void)notify:(NSString *)method params:(nullable NSDictionary *)params;
- (void)stop;
@end

NS_ASSUME_NONNULL_END
