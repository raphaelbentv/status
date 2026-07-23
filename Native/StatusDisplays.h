// StatusDisplays — luminosité des écrans (interne + externes DDC/CI).
//
// Même moule que StatusSystemMonitor : logique pure testable (bornes, pas clavier, protocole
// DDC/CI) séparée des contrôleurs qui parlent au matériel via des API privées non documentées.
// Écran interne : CoreDisplay_Display_Get/SetUserBrightness (framework privé CoreDisplay),
// chargé par dlsym — jamais lié statiquement, pour ne jamais faire échouer le build ni planter au
// lancement si Apple renomme le symbole : la famille disparaît alors du snapshot, comme un
// collecteur du Moniteur qui rendrait nil.
// Écrans externes : DDC/CI (norme VESA MCCS publique) transporté en I2C via IOAVService — API
// privée elle aussi chargée par dlsym, réservée à Apple Silicon (voir design, §Architecture).
//
// Voir docs/superpowers/specs/2026-07-23-controle-luminosite-design.md.

#import <Foundation/Foundation.h>
#import <CoreGraphics/CoreGraphics.h>

NS_ASSUME_NONNULL_BEGIN

#pragma mark - Logique pure (testable sans machine)

typedef NS_ENUM(NSInteger, TMDisplayKind) {
    TMDisplayKindBuiltin,
    TMDisplayKindExternal,
};

// Borne un pourcentage à [0, 100]. NaN (lecture matérielle invalide) devient 0 plutôt que de se
// propager dans un JSON, où il romprait la sérialisation.
double TMClampBrightnessPercent(double percent);

// Un cran de la touche clavier F1/F2. `stepPercent` est toujours positif ; `increase` donne le
// sens. Le résultat reste dans [0, 100].
double TMSteppedBrightness(double current, BOOL increase, double stepPercent);

// Conversion pourcentage <-> valeur VCP (l'échelle interne du moniteur, qui n'est pas toujours
// 0-100 : certains exposent 0-64). `maximum` à 0 signale un VCP mal formé : 0 en sortie plutôt
// qu'une division par zéro.
NSInteger TMPercentFromVCPValue(uint16_t current, uint16_t maximum);
uint16_t TMVCPValueFromPercent(double percent, uint16_t maximum);

// VCP MCCS de la luminosité — constante de la norme publique, pas une valeur Apple.
extern const uint8_t TMDDCBrightnessVCPCode;

// Construit la requête DDC/CI « Get/Set VCP Feature » prête à écrire en I2C (adresse 0x37).
// Format de trame VESA DDC/CI public ; seul le transport (IOAVService) est une API privée Apple.
NSData *TMDDCGetVCPRequest(uint8_t vcpCode);
NSData *TMDDCSetVCPRequest(uint8_t vcpCode, uint16_t value);

// Décode une réponse « Get VCP Feature » : vérifie le checksum, l'opcode et le code VCP, extrait
// valeur courante et maximum. NO si la trame est trop courte, mal formée, en erreur côté moniteur,
// ou si le checksum ne correspond pas — un moniteur qui répond n'importe quoi doit être traité
// comme « sans réponse », jamais afficher une valeur inventée.
BOOL TMDDCParseVCPReply(NSData *reply, uint8_t expectedVCPCode, uint16_t *outCurrent, uint16_t *outMaximum);

#pragma mark - Contrôleur d'écran (parle au matériel — pas de tests unitaires)

// Un écran détecté et son état de pilotage. `identifier` est stable d'un lancement à l'autre pour
// un écran externe (vendeur/produit/série CoreGraphics) ; l'écran interne utilise toujours
// "builtin", puisqu'il n'y en a jamais deux à la fois.
@interface TMDisplay : NSObject
@property (readonly) NSString *identifier;
@property (readonly) NSString *name;
@property (readonly) TMDisplayKind kind;
// NO si le canal de pilotage (CoreDisplay ou DDC/CI) n'a jamais répondu à la détection — l'écran
// reste listé, mais sans curseur actionnable (état « sans réponse » du design).
@property (readonly) BOOL available;
// Dernière valeur connue, nil si `available` est NO. Mise à jour de manière optimiste à l'écriture
// (pas de relecture DDC systématique — coûteuse sur le bus I2C).
@property (readonly, nullable) NSNumber *brightnessPercent;
- (BOOL)setBrightnessPercent:(double)percent;
@end

// Détecte les écrans actifs et construit un TMDisplay par écran.
@interface TMDisplayManager : NSObject
// Ré-énumère CGGetActiveDisplayList et reconstruit les contrôleurs. À appeler à l'ouverture d'une
// surface et sur NSApplicationDidChangeScreenParametersNotification — pas en continu, la
// luminosité ne dérive pas toute seule entre deux branchements.
- (void)rescan;
@property (readonly) NSArray<TMDisplay *> *displays;
// [{ id, name, kind, available, brightness }] — sérialisable en JSON tel quel.
- (NSArray<NSDictionary *> *)snapshot;
- (nullable TMDisplay *)displayWithIdentifier:(NSString *)identifier;
// Ajuste tous les écrans pilotables ensemble — pour la touche clavier physique, qui règle
// l'ambiance du poste plutôt qu'un écran en particulier (contrairement aux curseurs, indépendants).
- (void)stepAllByPercent:(double)stepPercent increase:(BOOL)increase;
@end

NS_ASSUME_NONNULL_END
