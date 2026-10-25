#import "StatusFanBoost.h"
#import "StatusFanCurve.h"
#import <assert.h>
#import <math.h>
@interface FakeFans:NSObject<TMFanBackend>
@property NSMutableArray *rows;
@property NSArray *journal;
@property BOOL failWrite,failRestore,failSave,failUnlock,unlocked;
@property NSInteger relocks;
@end
@implementation FakeFans
- (instancetype)init {if((self=[super init]))_rows=[@[@{@"index":@0,@"mode":@0,@"rpm":@2000,@"maxRPM":@6000,@"targetRPM":@2000},@{@"index":@1,@"mode":@3,@"rpm":@2100,@"maxRPM":@6500,@"targetRPM":@2100}] mutableCopy];return self;}
- (NSArray *)fans {return [_rows copy];}
- (BOOL)unlock {if(_failUnlock)return NO;_unlocked=YES;return YES;}
- (BOOL)setManual:(NSInteger)i rpm:(double)rpm {if(_failWrite)return NO;assert(_unlocked);NSMutableDictionary *f=[_rows[i] mutableCopy];f[@"mode"]=@1;f[@"targetRPM"]=@(rpm);_rows[i]=f;return YES;}
- (BOOL)setAutomatic:(NSInteger)i {if(_failRestore)return NO;NSMutableDictionary *f=[_rows[i] mutableCopy];f[@"mode"]=@0;_rows[i]=f;return YES;}
- (BOOL)relock {_unlocked=NO;_relocks++;return YES;}
- (BOOL)savePending:(NSArray *)indices {if(_failSave)return NO;_journal=indices;return YES;}
- (NSArray *)loadPending {return _journal;}
- (BOOL)clearPending {_journal=nil;return YES;}
- (void)spin {for(NSUInteger i=0;i<_rows.count;i++){NSMutableDictionary *f=[_rows[i] mutableCopy];f[@"rpm"]=f[@"targetRPM"];_rows[i]=f;}}
- (void)setRow:(NSInteger)i mode:(NSInteger)mode rpm:(double)rpm target:(double)target {NSMutableDictionary *f=[_rows[i] mutableCopy];f[@"mode"]=@(mode);f[@"rpm"]=@(rpm);f[@"targetRPM"]=@(target);_rows[i]=f;}
@end
// ── Courbe de ventilation (StatusFanCurve) : service simulé, réponse immédiate ──
typedef struct { BOOL ok, busy, active, pending, refuse; NSInteger percent; double remaining; NSInteger starts, stops; } Svc;
static TMFanServiceView View(Svc s) { return (TMFanServiceView){s.ok, s.busy, s.active, s.pending, s.percent, s.remaining}; }
static TMFanCommand Drive(TMFanController *c, Svc *s, double now) {
  TMFanCommand cmd=[c nextCommand:View(*s) now:now];
  if(cmd.kind==TMFanCommandStart){ assert(!s->active); assert(cmd.percent>=TMFanCurveFloor&&cmd.percent<=100); s->starts++;
    if(!s->refuse){s->active=YES;s->percent=cmd.percent;s->remaining=cmd.minutes*60;} }
  else if(cmd.kind==TMFanCommandStop){ s->stops++; s->active=NO;s->percent=0;s->remaining=0; }
  return cmd;
}
static void Elapse(Svc *s,double dt){ if(s->active){s->remaining-=dt;if(s->remaining<=0){s->active=NO;s->percent=0;s->remaining=0;}} }
static void curveTests(void){
  NSArray *bal=TMFanCurvePoints(@"balanced");
  assert(TMFanCurvePresetIds().count==3&&!TMFanCurvePoints(@"bogus")&&!TMFanCurvePoints(nil));
  // Interpolation linéaire, bornes et zone « macOS » sous le premier point.
  assert(isnan(TMFanCurveValue(bal,54.9))&&isnan(TMFanCurveValue(bal,NAN))&&isnan(TMFanCurveValue(nil,70)));
  assert(TMFanCurveValue(bal,55)==50&&TMFanCurveValue(bal,60)==55&&TMFanCurveValue(bal,70)==70&&TMFanCurveValue(bal,85)==100&&TMFanCurveValue(bal,119)==100);
  for(NSString *p in TMFanCurvePresetIds()) for(double t=0;t<=130;t+=0.5){double v=TMFanCurveValue(TMFanCurvePoints(p),t);
    assert(isnan(v)||(v>=TMFanCurveFloor&&v<=100)); assert(t<TMFanCurveCriticalC||v==100);}  // plancher 50 %, 100 % au critique
  // Hystérésis : ≥ 5 points ET ≥ 10 s ; zéro sous le premier point, reprise avec bande de 3 °C.
  TMFanCurve *c=[[TMFanCurve alloc]initWithPreset:@"balanced"];assert(c&&![[TMFanCurve alloc]initWithPreset:@"x"]);
  assert([c stepAt:0 tempC:50 thermal:0]==0&&c.reason==TMFanCurveReasonIdle);
  assert([c stepAt:1 tempC:55 thermal:0]==50&&c.reason==TMFanCurveReasonCurve);
  assert([c stepAt:20 tempC:58 thermal:0]==50);            // 53 % : écart < 5
  assert([c stepAt:21 tempC:66 thermal:0]==62);            // 62 % : écart 12, 20 s après
  assert([c stepAt:25 tempC:75 thermal:0]==62);            // 80 % voulu mais < 10 s
  assert([c stepAt:31 tempC:75 thermal:0]==80);
  assert([c stepAt:41 tempC:53 thermal:0]==50);            // bande 52–55 °C : plancher, pas encore macOS
  assert([c stepAt:52 tempC:51.9 thermal:0]==0&&c.reason==TMFanCurveReasonIdle);
  assert([c stepAt:63 tempC:54 thermal:0]==0);             // reprise seulement au premier point
  assert([c stepAt:64 tempC:55 thermal:0]==50);
  // Seuil critique : 100 % immédiatement, hystérésis ignorée ; état thermique « serious » aussi.
  assert([c stepAt:65 tempC:96 thermal:0]==100&&c.reason==TMFanCurveReasonCritical);
  TMFanCurve *hot=[[TMFanCurve alloc]initWithPreset:@"silent"];
  assert([hot stepAt:0 tempC:40 thermal:TMFanCurveCriticalThermal]==100);
  assert([hot stepAt:5 tempC:40 thermal:0]==100);           // redescend seulement après 10 s
  assert([hot stepAt:10 tempC:40 thermal:0]==0);
  // Pas d'extrême inaccessible : 98 % rejoint 100 % malgré un écart < 5.
  TMFanCurve *top=[[TMFanCurve alloc]initWithPreset:@"balanced"];[top stepAt:0 tempC:84 thermal:0];assert(top.target==98);
  assert([top stepAt:10 tempC:88 thermal:0]==100);
  // Capteur absent : palier tenu 10 s, puis abandon.
  TMFanCurve *blind=[[TMFanCurve alloc]initWithPreset:@"balanced"];[blind stepAt:0 tempC:70 thermal:0];
  assert([blind stepAt:5 tempC:NAN thermal:0]==70&&[blind stepAt:10 tempC:0 thermal:0]==70);
  assert([blind stepAt:10.5 tempC:NAN thermal:0]==0&&blind.reason==TMFanCurveReasonSensorLost);
  assert([blind stepAt:11 tempC:70 thermal:0]==0);          // définitif

  // Contrôleur : validation stricte.
  TMFanController *m=[TMFanController new];assert([m.mode isEqual:@"auto"]&&m.idle);
  assert(![m setMode:@"turbo" preset:nil percent:80 minutes:15]&&![m setMode:@"curve" preset:@"bogus" percent:0 minutes:0]);
  assert(![m setMode:@"manual" preset:nil percent:49 minutes:15]&&![m setMode:@"manual" preset:nil percent:101 minutes:15]);
  assert(![m setMode:@"manual" preset:nil percent:80 minutes:0]&&![m setMode:@"manual" preset:nil percent:80 minutes:61]);
  assert([m.mode isEqual:@"auto"]);
  // Courbe : bail de 2 min renouvelé (arrêt puis relance), une commande au plus toutes les 2 s.
  Svc s={.ok=YES};assert([m setMode:@"curve" preset:@"balanced" percent:0 minutes:0]&&[m.mode isEqual:@"curve"]);
  double last=-10;
  for(double t=0;t<600;t+=1){[m sensorAt:t tempC:70 thermal:0];TMFanCommand k=Drive(m,&s,t);Elapse(&s,1);
    if(k.kind!=TMFanCommandNone){assert(t-last>=2);last=t;}
    if(k.kind==TMFanCommandStart)assert(k.minutes==TMFanLeaseMinutes&&k.percent==70);}
  assert(s.starts>=6&&s.starts<=8&&s.stops==s.starts-1&&s.active&&[m.mode isEqual:@"curve"]);
  // Requête en vol : aucune commande.
  s.busy=YES;[m sensorAt:600 tempC:96 thermal:0];assert(Drive(m,&s,600).kind==TMFanCommandNone);s.busy=NO;
  // Nouveau palier (critique) : arrêt puis relance à 100 %.
  assert(Drive(m,&s,601).kind==TMFanCommandStop);assert(Drive(m,&s,602).kind==TMFanCommandNone);
  TMFanCommand up=Drive(m,&s,603);assert(up.kind==TMFanCommandStart&&up.percent==100);
  // Sous le premier point : macOS reprend (arrêt), puis reprise quand ça remonte.
  [m sensorAt:620 tempC:40 thermal:0];assert(m.desiredPercent==0&&Drive(m,&s,620).kind==TMFanCommandStop&&!s.active);
  assert(Drive(m,&s,640).kind==TMFanCommandNone&&[m.mode isEqual:@"curve"]);
  [m sensorAt:650 tempC:60 thermal:0];TMFanCommand back=Drive(m,&s,650);assert(back.kind==TMFanCommandStart&&back.percent==55);
  // Capteur muet > 10 s : retour en Auto et arrêt explicite.
  [m sensorAt:655 tempC:NAN thermal:0];assert([m.mode isEqual:@"curve"]);
  [m sensorAt:661 tempC:NAN thermal:0];assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"sensor"]&&!m.idle);
  assert(Drive(m,&s,661).kind==TMFanCommandStop&&!s.active);Drive(m,&s,664);assert(m.idle);
  // Service perdu pendant la courbe : Auto, sans commande impossible.
  [m setMode:@"curve" preset:@"performance" percent:0 minutes:0];[m sensorAt:700 tempC:65 thermal:0];
  Drive(m,&s,700);assert(s.active&&s.percent==83);
  s.ok=NO;Drive(m,&s,710);assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"service"]);s.ok=YES;s.active=NO;Drive(m,&s,713);
  // Palier refusé trois fois en cinq minutes : abandon (pas de boucle arrêt/relance).
  [m setMode:@"curve" preset:@"balanced" percent:0 minutes:0];s.refuse=YES;
  for(double t=800;t<900&&[m.mode isEqual:@"curve"];t+=1){[m sensorAt:t tempC:80 thermal:0];Drive(m,&s,t);}
  assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"failed"]&&s.starts>0);s.refuse=NO;
  // Boost coupé par le service à répétition (reprise par macOS) : même plafond.
  [m setMode:@"curve" preset:@"balanced" percent:0 minutes:0];
  for(double t=1000;t<1300&&[m.mode isEqual:@"curve"];t+=1){[m sensorAt:t tempC:80 thermal:0];Drive(m,&s,t);if(s.active&&fmod(t,25)==0){s.active=NO;s.percent=0;}}
  assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"failed"]);
  // Manuel : un seul démarrage avec la durée choisie ; fin du palier ⇒ Auto.
  s=(Svc){.ok=YES};assert([m setMode:@"manual" preset:nil percent:80 minutes:15]);
  TMFanCommand man=Drive(m,&s,2000);assert(man.kind==TMFanCommandStart&&man.minutes==15&&man.percent==80);
  for(double t=2001;t<2000+15*60+5;t+=1){Elapse(&s,1);assert(Drive(m,&s,t).kind!=TMFanCommandStart);}
  assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"ended"]&&s.starts==1);
  // Manuel refusé par le service : Auto.
  s=(Svc){.ok=YES,.refuse=YES};[m setMode:@"manual" preset:nil percent:60 minutes:30];Drive(m,&s,3000);Drive(m,&s,3002);
  assert([m.mode isEqual:@"auto"]&&[m.notice isEqual:@"refused"]);
  // Changement de mode : l'ancien boost est arrêté avant le nouveau.
  s=(Svc){.ok=YES};[m setMode:@"manual" preset:nil percent:100 minutes:60];Drive(m,&s,4000);assert(s.active&&s.percent==100);
  [m setMode:@"curve" preset:@"balanced" percent:0 minutes:0];[m sensorAt:4001 tempC:70 thermal:0];
  assert(Drive(m,&s,4002).kind==TMFanCommandStop);TMFanCommand sw=Drive(m,&s,4004);assert(sw.kind==TMFanCommandStart&&sw.percent==70&&sw.minutes==2);
  [m setMode:@"manual" preset:nil percent:60 minutes:15];assert(Drive(m,&s,4006).kind==TMFanCommandStop);
  sw=Drive(m,&s,4008);assert(sw.kind==TMFanCommandStart&&sw.percent==60&&sw.minutes==15);
  // Auto demandé : arrêt, puis plus rien.
  [m setMode:@"auto" preset:nil percent:0 minutes:0];assert(Drive(m,&s,4010).kind==TMFanCommandStop);
  assert(Drive(m,&s,4012).kind==TMFanCommandNone&&m.idle);
  // Restauration en cours côté service : on attend.
  [m setMode:@"curve" preset:@"balanced" percent:0 minutes:0];[m sensorAt:4100 tempC:70 thermal:0];s.pending=YES;
  assert(Drive(m,&s,4100).kind==TMFanCommandNone);s.pending=NO;assert(Drive(m,&s,4101).kind==TMFanCommandStart);
  // Températures aléatoires : jamais sous 50 %, toujours 100 % au critique, jamais deux commandes en < 2 s.
  srand48(7);s=(Svc){.ok=YES};Drive(m,&s,4200);[m setMode:@"curve" preset:@"silent" percent:0 minutes:0];last=-10;
  for(double t=5000;t<9000;t+=1){double temp=drand48()<0.02?NAN:20+drand48()*85;NSInteger th=drand48()<0.05?2:0;
    [m sensorAt:t tempC:temp thermal:th];if(![m.mode isEqual:@"curve"])break;
    if(th>=2||(isfinite(temp)&&temp>=95))assert(m.desiredPercent==100);
    assert(m.desiredPercent==0||(m.desiredPercent>=50&&m.desiredPercent<=100));
    TMFanCommand k=Drive(m,&s,t);Elapse(&s,1);if(k.kind!=TMFanCommandNone){assert(t-last>=2);last=t;}}
  puts("Fan curve: interpolation, floor, hysteresis, critical, sensor loss, idle zero, lease renewal, mode switches and failure cap passed.");
}
static const NSProcessInfoThermalState Cool=NSProcessInfoThermalStateNominal;
int main(void){@autoreleasepool {
 FakeFans *b=[FakeFans new];TMFanBoost *m=[[TMFanBoost alloc]initWithBackend:b];
 [m startMinutes:0 percent:100 now:0];assert(!m.active&&!b.journal);
 [m startMinutes:61 percent:100 now:0];assert(!m.active&&!b.journal);
 [m startMinutes:5 percent:40 now:0];assert(!m.active&&!b.journal);
 // Maximum : consigne = maxRPM, déverrouillage avant toute écriture.
 [m startMinutes:5 percent:100 now:100];assert(m.active&&!m.verified&&b.journal.count==2);
 assert([b.rows[0][@"targetRPM"] doubleValue]==6000&&[b.rows[1][@"targetRPM"] doubleValue]==6500);
 [b spin];[m tick:105 thermal:Cool];assert(m.verified);
 [m heartbeat:119];[m tick:120 thermal:Cool];assert(m.active);
 // Sans battement de cœur : retour auto ET Ftst rendu.
 NSInteger relocks=b.relocks;[m tick:140 thermal:Cool];assert(!m.active&&!m.restorationPending&&!b.journal&&b.relocks==relocks+1&&!b.unlocked);
 assert([b.rows[0][@"mode"] integerValue]==0&&[b.rows[1][@"mode"] integerValue]==0);
 // Échéance.
 [m startMinutes:1 percent:100 now:200];[b spin];[m heartbeat:259];[m tick:260 thermal:Cool];assert(!m.active&&!b.journal);
 // Palier partiel : jamais sous la vitesse du moment, et abandon si le Mac chauffe.
 [b setRow:0 mode:0 rpm:4500 target:4500];[b setRow:1 mode:0 rpm:2100 target:2100];
 [m startMinutes:5 percent:60 now:250];assert(m.active&&m.percent==60);
 assert([b.rows[0][@"targetRPM"] doubleValue]==4500&&[b.rows[1][@"targetRPM"] doubleValue]==3900);
 [b spin];[m tick:255 thermal:Cool];assert(m.verified);
 [m tick:256 thermal:NSProcessInfoThermalStateSerious];assert(!m.active&&!b.journal);
 // macOS refuse : restauration complète.
 b.failWrite=YES;[m startMinutes:5 percent:100 now:300];assert(!m.active&&!m.restorationPending&&!b.journal&&!b.unlocked);b.failWrite=NO;
 b.failUnlock=YES;[m startMinutes:5 percent:100 now:310];assert(!m.active&&!m.restorationPending&&!b.journal);b.failUnlock=NO;
 // Restauration en échec : on réessaie au tick suivant.
 [m startMinutes:5 percent:100 now:400];b.failRestore=YES;[m stop:@"stop"];assert(m.restorationPending&&b.journal);
 [m startMinutes:5 percent:100 now:500];assert(!m.active);b.failRestore=NO;[m tick:501 thermal:Cool];assert(!m.restorationPending&&!b.journal);
 // Redémarrage du service pendant un boost.
 [m startMinutes:5 percent:100 now:600];TMFanBoost *restarted=[[TMFanBoost alloc]initWithBackend:b];[restarted recover];assert(!restarted.active&&!restarted.restorationPending&&!b.journal&&!b.unlocked);
 b.failSave=YES;[restarted startMinutes:5 percent:100 now:700];assert(!restarted.active&&!b.journal);b.failSave=NO;
 // Ventilateur resté en manuel : démarrage refusé, signalé, et « Auto Apple » le répare.
 [b setRow:0 mode:1 rpm:4900 target:4931];
 [restarted startMinutes:5 percent:100 now:800];assert(!restarted.active&&!b.journal);
 assert([[restarted snapshot:800][@"manualOutsideBoost"] boolValue]);
 [restarted restoreAll:@"Auto Apple."];assert([b.rows[0][@"mode"] integerValue]==0&&!restarted.restorationPending&&!b.journal);
 assert(![[restarted snapshot:801][@"manualOutsideBoost"] boolValue]);
 // Vitesse jamais atteinte.
 [b setRow:0 mode:0 rpm:0 target:0];[b setRow:1 mode:0 rpm:0 target:0];
 [restarted startMinutes:5 percent:100 now:900];[restarted heartbeat:919];[restarted tick:920 thermal:Cool];assert(!restarted.active&&!b.journal);
 // Reprise par thermalmonitord pendant le boost.
 [restarted startMinutes:5 percent:100 now:1000];[b spin];[b setRow:1 mode:3 rpm:6500 target:6500];
 [restarted tick:1005 thermal:Cool];assert(!restarted.active&&!b.journal);
 // Journal illisible : restauration de tous les ventilateurs.
 b.journal=@[@(-1)];[restarted recover];assert(!restarted.restorationPending&&!b.journal);
 assert([[restarted snapshot:1100][@"version"] isEqual:@(TMFanBoostVersion)]);
 curveTests();
 puts("Fan boost: unlock, levels, ramp, timeout, heartbeat, thermal, partial failure, recovery, stuck manual and takeover passed.");
}return 0;}
