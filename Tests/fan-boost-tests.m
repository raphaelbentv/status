#import "StatusFanBoost.h"
#import <assert.h>
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
 puts("Fan boost: unlock, levels, ramp, timeout, heartbeat, thermal, partial failure, recovery, stuck manual and takeover passed.");
}return 0;}
