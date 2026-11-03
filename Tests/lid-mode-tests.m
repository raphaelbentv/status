#import <Foundation/Foundation.h>
#import "StatusLidMode.h"
#import "StatusLidProtocol.h"
#include <math.h>
static int checks=0,failures=0;
static void Check(BOOL ok, NSString *label) { checks++; if(!ok){failures++; NSLog(@"FAIL: %@",label);} }
@interface FakePower : NSObject <TMLidBackend>
@property NSMutableDictionary *power;
@property NSDictionary *journal;
@property BOOL failSave,failSleepOn,failRestore,failLowPower,unreadable,lieAboutWrite;
@property NSUInteger writes;
@end
@implementation FakePower
- (instancetype)init { if((self=[super init]))_power=[@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2} mutableCopy];return self; }
- (NSDictionary *)powerSettings{return self.unreadable?nil:[self.power copy];}
- (BOOL)setSleepDisabled:(BOOL)disabled{self.writes++; if((disabled&&self.failSleepOn)||(!disabled&&self.failRestore))return NO;if(!self.lieAboutWrite)self.power[@"sleepDisabled"]=@(disabled);return YES;}
- (BOOL)setPowerMode:(NSInteger)mode battery:(BOOL)battery{self.writes++;if((mode==1&&self.failLowPower)||(mode!=1&&self.failRestore))return NO;if(!self.lieAboutWrite)self.power[battery?@"batteryMode":@"acMode"]=@(mode);return YES;}
- (NSDictionary *)loadJournal{return self.journal;}
- (BOOL)saveJournal:(NSDictionary *)journal{if(self.failSave)return NO;self.journal=[journal copy];return YES;}
- (BOOL)clearJournal{self.journal=nil;return YES;}
@end
// Modèle fixé (un MacBook Pro) : ces tests décrivent le profil à ventilateurs, quel que soit le Mac qui les lance.
static TMLidMode *Mode(FakePower *backend){TMLidMode *m=[[TMLidMode alloc]initWithBackend:backend];m.machineModel=@"Mac16,6";return m;}
static void Start(TMLidMode *mode){[mode startMinutes:17 battery:65 thermal:0 now:100];}
int main(void){@autoreleasepool{
    Check(TMLidDurationAllowed(1)&&TMLidDurationAllowed(17)&&TMLidDurationAllowed(240),@"durée personnalisée acceptée");
    Check(!TMLidDurationAllowed(0)&&!TMLidDurationAllowed(-1)&&!TMLidDurationAllowed(241)&&!TMLidDurationAllowed(NSIntegerMax),@"durée bornée");
    Check(!TMLidStopReason(31,0,100,200,90),@"état admissible");
    Check(TMLidStopReason(30,0,100,200,90)!=nil,@"seuil batterie");
    Check(TMLidStopReason(NAN,0,100,200,90)!=nil&&TMLidStopReason(-1,0,100,200,90)!=nil,@"batterie absente refuse");
    for(NSInteger thermal=1;thermal<=3;thermal++) Check(TMLidStopReason(80,thermal,100,200,90)!=nil,@"pression thermique arrête dès fair");
    Check(TMLidStopReason(80,0,200,200,199)!=nil,@"échéance exacte");
    Check(TMLidStopReason(80,0,121,200,100)!=nil,@"app muette 21 secondes");
    NSString *fixture=@"System-wide power settings:\nCurrently in use:\n sleep 1\nBattery Power:\n powermode 0\n sleep 1\nAC Power:\n powermode 2\n";
    NSDictionary *parsed=TMLidParsePowerSettings(fixture);
    Check([parsed isEqual:@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2}],@"lecture des profils distincts");
    Check(TMLidParsePowerSettings(@"Battery Power:\n powermode 0\n")==nil,@"lecture incomplète refuse");
    Check([TMLidParsePowerSettings([fixture stringByReplacingOccurrencesOfString:@"System-wide power settings:" withString:@"System-wide power settings:\n SleepDisabled 1"])[@"sleepDisabled"] isEqual:@1],@"blocage extérieur détecté");
    Check(TMLidParsePowerSettings([fixture stringByReplacingOccurrencesOfString:@"powermode 0" withString:@"powermode invalid"])==nil,@"mode inconnu refuse");
    Check(TMLidParsePowerSettings([fixture stringByReplacingOccurrencesOfString:@"System-wide power settings:" withString:@"System-wide power settings:\n SleepDisabled unknown"])==nil,@"blocage inconnu refuse");
    FakePower *b=[FakePower new];TMLidMode *m=Mode(b);Start(m);
    Check(m.active&&m.deadline==1120&&b.journal!=nil,@"session active et journal préalable");
    Check([b.power isEqual:@{@"sleepDisabled":@1,@"batteryMode":@1,@"acMode":@1}],@"faible consommation batterie et secteur");
    [m heartbeatAt:110];[m tickBattery:70 thermal:0 now:115];Check(m.active,@"heartbeat maintient sans prolonger");
    Start(m);Check(m.deadline==1120,@"double clic ne prolonge pas");
    [m extendMinutes:30 now:1000];Check(m.deadline==2800,@"prolongation explicite : maintenant + durée");
    [m extendMinutes:1 now:1100];Check(m.deadline==2800,@"prolongation : jamais d'échéance raccourcie");
    [m extendMinutes:241 now:1100];[m extendMinutes:0 now:1100];Check(m.deadline==2800,@"prolongation : durée bornée");
    [m extendMinutes:240 now:14000];Check(m.deadline==100+240*60,@"prolongation : jamais au-delà de 240 min après le démarrage");
    [m stop:@"test"];Check(!m.active&&!m.restorationPending&&!b.journal,@"arrêt termine et efface journal");
    Check([b.power isEqual:@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2}],@"réglages originaux restaurés exactement");
    for(int reason=0;reason<4;reason++){
        b=[FakePower new];m=Mode(b);Start(m);
        if(reason==0)[m tickBattery:30 thermal:0 now:110];
        if(reason==1)[m tickBattery:80 thermal:1 now:110];
        if(reason==2){[m heartbeatAt:1120];[m tickBattery:80 thermal:0 now:1120];}
        if(reason==3)[m tickBattery:80 thermal:0 now:121];
        Check(!m.active&&!m.restorationPending&&[b.power[@"sleepDisabled"]isEqual:@0],@"chaque limite restaure");
    }
    b=[FakePower new];m=Mode(b);[m extendMinutes:30 now:100];Check(!m.active&&m.deadline==0,@"prolongation sans session : sans effet");
    b=[FakePower new];b.failSave=YES;m=Mode(b);Start(m);Check(!m.active&&b.writes==0,@"sans journal aucune mutation");
    // Veille déjà bloquée par un autre outil : la session démarre sans toucher ce blocage, et l'arrêt le laisse.
    b=[FakePower new];b.power[@"sleepDisabled"]=@1;m=Mode(b);Start(m);
    Check(m.active&&[b.journal[@"sleepDisabled"]isEqual:@1]&&[b.power[@"acMode"]isEqual:@1],@"blocage extérieur : session active, faible consommation imposée");
    [m heartbeatAt:110];[m tickBattery:80 thermal:0 now:115];Check(m.active,@"blocage extérieur : la session se maintient");
    [m stop:@"test"];
    Check(!m.restorationPending&&[b.power isEqual:@{@"sleepDisabled":@1,@"batteryMode":@0,@"acMode":@2}],@"blocage extérieur : modes restaurés, blocage laissé");
    b=[FakePower new];b.power[@"sleepDisabled"]=@1;m=Mode(b);Start(m);TMLidMode *crashed=Mode(b);[crashed recover];
    Check(!crashed.restorationPending&&[b.power[@"sleepDisabled"]isEqual:@1]&&[b.power[@"acMode"]isEqual:@2],@"blocage extérieur : reprise après crash sans lever le blocage");
    // L'autre outil lève son blocage en cours de session : Status le reprend, puis le restaure à l'arrêt.
    b=[FakePower new];b.power[@"sleepDisabled"]=@1;m=Mode(b);Start(m);b.power[@"sleepDisabled"]=@0;
    [m heartbeatAt:110];[m tickBattery:80 thermal:0 now:115];
    Check(m.active&&[b.power[@"sleepDisabled"]isEqual:@1]&&[b.journal[@"sleepDisabled"]isEqual:@0],@"blocage levé par l'autre outil : repris par Status");
    [m stop:@"test"];Check([b.power isEqual:@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2}],@"blocage repris : restauré à l'arrêt");
    b=[FakePower new];b.power[@"sleepDisabled"]=@1;m=Mode(b);Start(m);b.power[@"sleepDisabled"]=@0;b.failSleepOn=YES;
    [m heartbeatAt:110];[m tickBattery:80 thermal:0 now:115];
    Check(!m.active&&!m.restorationPending&&[b.power isEqual:@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2}],@"reprise impossible : arrêt et restauration");
    b=[FakePower new];b.failLowPower=YES;m=Mode(b);Start(m);Check(!m.active&&!m.restorationPending,@"faible consommation refusée annule");
    b=[FakePower new];b.failSleepOn=YES;m=Mode(b);Start(m);Check(!m.active&&!m.restorationPending&&[b.power[@"acMode"]isEqual:@2],@"échec capot restaure modes");
    b=[FakePower new];b.lieAboutWrite=YES;m=Mode(b);Start(m);Check(!m.active,@"écriture réussie sans effet ne prétend pas active");
    b=[FakePower new];m=Mode(b);Start(m);b.failRestore=YES;[m stop:@"test"];
    Check(!m.active&&m.restorationPending&&b.journal!=nil,@"restauration échouée garde le journal");
    b.failRestore=NO;[m tickBattery:90 thermal:0 now:200];Check(!m.restorationPending,@"restauration réessayée");
    b=[FakePower new];m=Mode(b);Start(m);TMLidMode *restarted=Mode(b);[restarted recover];
    Check(!restarted.active&&!restarted.restorationPending&&[b.power[@"sleepDisabled"]isEqual:@0],@"redémarrage restaure sans reprendre session");
    b=[FakePower new];m=Mode(b);Start(m);b.power[@"acMode"]=@0;[m tickBattery:80 thermal:0 now:110];
    Check(!m.active&&[b.power[@"acMode"]isEqual:@0],@"changement externe préservé et session arrêtée");
    b=[FakePower new];b.journal=@{@"corrupt":@YES};m=Mode(b);[m recover];Start(m);
    Check(!m.active&&m.restorationPending&&b.writes==0,@"journal invalide bloque sans écrire");
    b=[FakePower new];b.unreadable=YES;m=Mode(b);Start(m);Check(!m.active&&b.writes==0,@"lecture initiale échouée refuse");
    b=[FakePower new];m=Mode(b);[m startMinutes:0 battery:80 thermal:0 now:100];Check(b.writes==0,@"entrée invalide sans effets");
    // Le minuteur seul reste actif jusqu'à l'échéance, indépendamment de toute sonde SMC.
    b=[FakePower new];m=Mode(b);[m startMinutes:1 battery:80 thermal:0 now:100];
    [m heartbeatAt:159];[m tickBattery:80 thermal:0 now:159];
    Check(m.active&&m.deadline==160,@"une minute reste active avant son échéance");
    [m heartbeatAt:160];[m tickBattery:80 thermal:0 now:160];
    Check(!m.active&&!m.restorationPending&&[b.power[@"sleepDisabled"]isEqual:@0],@"une minute restaure à 60 secondes exactement");
    b=[FakePower new];m=Mode(b);[m startMinutes:240 battery:80 thermal:0 now:100];
    Check(m.active&&m.deadline==14500,@"durée maximale de quatre heures");
    [m stop:@"test"];
    Check([b.power isEqual:@{@"sleepDisabled":@0,@"batteryMode":@0,@"acMode":@2}],@"arrêt anticipé de la durée maximale restaure");
    // Propriété par jeton : un client sans session (jeton 0 ou étranger) ne libère jamais la session d'un autre.
    TMLidOwnership *own=[TMLidOwnership new];
    Check(![own releaseClient:1]&&![own releaseClient:0]&&![own isOwner:0],@"déconnexion sans session : aucun arrêt");
    Check(![own claim:0]&&own.owner==0,@"jeton nul jamais propriétaire");
    Check([own claim:2]&&[own isOwner:2]&&![own claim:3]&&own.owner==2,@"la session reste à son premier client");
    Check(![own releaseClient:3]&&![own releaseClient:1]&&own.owner==2,@"un autre client qui se déconnecte n'arrête rien");
    Check([own releaseClient:2]&&own.owner==0&&![own releaseClient:2],@"la déconnexion du propriétaire libère une seule fois");
    // Ce que fait le service à la déconnexion : libérer la session sans l'arrêter (réouverture du capot),
    // puis la confier à la connexion suivante de Status ; sans elle, le battement manquant l'arrête.
    b=[FakePower new];m=Mode(b);Start(m);[own claim:7];
    [own releaseClient:8];
    Check(m.active&&[own isOwner:7],@"client sans session déconnecté : session intacte");
    [own releaseClient:7];
    Check(m.active&&own.owner==0,@"déconnexion du propriétaire : session conservée, sans propriétaire");
    if(m.active)[own claim:9];
    if([own isOwner:9])[m heartbeatAt:118];
    [m tickBattery:80 thermal:0 now:130];
    Check(m.active&&[own isOwner:9],@"la connexion suivante reprend la session et la maintient");
    [own releaseClient:9];[m tickBattery:80 thermal:0 now:139];
    Check(!m.active&&[m.message isEqualToString:@"Status ne répond plus."]&&[b.power[@"sleepDisabled"]isEqual:@0],@"sans reconnexion, l'absence de battement arrête et restaure");
    // Le binaire de test est ad hoc : il ne peut pas définir une autorité XPC valable.
    Check(TMLidPeerRequirement(@"com.raphael.status")==nil,@"signature ad hoc ne peut pas autoriser le service");
    printf("Capot fermé : %d vérifications, %d échecs (aucun réglage réel modifié).\n",checks,failures);
    return failures?1:0;
}}
