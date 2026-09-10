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
static TMLidMode *Mode(FakePower *backend){return [[TMLidMode alloc]initWithBackend:backend];}
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
    b=[FakePower new];b.failSave=YES;m=Mode(b);Start(m);Check(!m.active&&b.writes==0,@"sans journal aucune mutation");
    b=[FakePower new];b.power[@"sleepDisabled"]=@1;m=Mode(b);Start(m);Check(!m.active&&b.writes==0,@"ne s'approprie pas un blocage extérieur");
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
    // Le binaire de test est ad hoc : il ne peut pas définir une autorité XPC valable.
    Check(TMLidPeerRequirement(@"com.raphael.status")==nil,@"signature ad hoc ne peut pas autoriser le service");
    printf("Capot fermé : %d vérifications, %d échecs (aucun réglage réel modifié).\n",checks,failures);
    return failures?1:0;
}}
