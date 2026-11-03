#import <Foundation/Foundation.h>

// Démarrage automatique du mode capot fermé pendant que Claude Code travaille. Rien ici ne touche aux réglages
// d'énergie : le pilote ne fait que choisir une commande, que l'app transmet au service, seul juge de la sécurité.

typedef NS_ENUM(NSInteger, TMClaudeTurn) { TMClaudeTurnUnknown, TMClaudeTurnIdle, TMClaudeTurnWorking };
// État de la dernière entrée de conversation d'une transcription .jsonl (fin du fichier). `timestamp` : son heure.
TMClaudeTurn TMClaudeTranscriptTurn(NSData *tail, double *timestamp);
// YES si une session Claude Code est en plein tour dans l'un des dossiers « projects » donnés.
BOOL TMClaudeCodeWorking(NSArray<NSString *> *roots, double now);

typedef NS_ENUM(NSInteger, TMLidAutoCommand) { TMLidAutoNone, TMLidAutoStart, TMLidAutoExtend, TMLidAutoStop };
extern const double TMLidAutoGraceSeconds, TMLidAutoCooldownSeconds;
extern const NSInteger TMLidAutoChunkMinutes, TMLidAutoCapMinutes;

@interface TMLidAutoPilot : NSObject
@property (nonatomic) BOOL enabled;
// `lid` : instantané du client du service.
- (TMLidAutoCommand)decideWithService:(NSDictionary *)lid working:(BOOL)working
                                  now:(double)now minutes:(NSInteger *)minutes;
// Arrêt demandé à la main : plus de redémarrage automatique avant la fin du travail en cours.
- (void)userStopped;
@property (readonly) BOOL owns;
- (NSDictionary *)snapshot:(double)now;
@end
