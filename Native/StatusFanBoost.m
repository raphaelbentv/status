#import "StatusFanBoost.h"
#import <IOKit/IOKitLib.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <unistd.h>
#import <errno.h>
#import <math.h>
// Seuls les modes et consignes des ventilateurs découverts, et Ftst (prise de main sur
// thermalmonitord exigée par les M3/M4 Pro/Max), sont écrits. Aucune clé SMC arbitraire n'est
// exposée via XPC ; Ftst est toujours rendu (0) au retour en Auto Apple.
typedef struct {
    uint32_t key;
    struct { uint8_t major,minor,build,reserved; uint16_t release; } vers;
    struct { uint16_t version,length; uint32_t cpu,gpu,mem; } limits;
    struct { uint32_t size,type; uint8_t attributes; } info;
    uint8_t result,status,command; uint32_t value; uint8_t bytes[32];
} FanParam;
static uint32_t Key(NSString *key) { const unsigned char *s=(const unsigned char *)key.UTF8String; return s[0]<<24|s[1]<<16|s[2]<<8|s[3]; }
static NSString *FanKey(NSInteger i,NSString *suffix) { return [NSString stringWithFormat:@"F%ld%@",(long)i,suffix]; }
@implementation TMFanSMCBackend { io_connect_t _connection; }
- (instancetype)init {
    if ((self=[super init])) {
        io_service_t s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"));
        if(s) { IOServiceOpen(s,mach_task_self(),0,&_connection); IOObjectRelease(s); }
    } return self;
}
- (void)dealloc { if(_connection)IOServiceClose(_connection); }
- (BOOL)call:(FanParam *)in out:(FanParam *)out {
    size_t size=sizeof(*out);
    return _connection && IOConnectCallStructMethod(_connection,2,in,sizeof(*in),out,&size)==KERN_SUCCESS && size==sizeof(*out) && out->result==0;
}
- (BOOL)info:(NSString *)key out:(FanParam *)out { FanParam in={0}; in.key=Key(key); in.command=9; return [self call:&in out:out] && out->info.size>0 && out->info.size<=32; }
- (double)read:(NSString *)key {
    FanParam info={0},in={0},out={0}; if(![self info:key out:&info])return NAN;
    in.key=Key(key); in.info.size=info.info.size; in.command=5;
    if(![self call:&in out:&out])return NAN;
    if(info.info.type==Key(@"flt ") && info.info.size==4) { float f; memcpy(&f,out.bytes,4); return isfinite(f)?f:NAN; }
    if(info.info.type==Key(@"ui8 ") && info.info.size==1)return out.bytes[0];
    if(info.info.type==Key(@"fpe2") && info.info.size==2)return (out.bytes[0]*256+out.bytes[1])/4.0;
    return NAN;
}
- (BOOL)write:(NSString *)key value:(double)value {
    if(geteuid()!=0 || !isfinite(value))return NO;
    FanParam info={0},in={0},out={0}; if(![self info:key out:&info])return NO;
    in.key=Key(key); in.info.size=info.info.size; in.command=6;
    if(info.info.type==Key(@"flt ") && info.info.size==4) { float f=value; memcpy(in.bytes,&f,4); }
    else if(info.info.type==Key(@"ui8 ") && info.info.size==1 && value>=0 && value<=255)in.bytes[0]=(uint8_t)value;
    else if(info.info.type==Key(@"fpe2") && info.info.size==2 && value>=0 && value<16384) { uint16_t v=(uint16_t)round(value*4); in.bytes[0]=v>>8; in.bytes[1]=v&255; }
    else return NO;
    return [self call:&in out:&out];
}
- (BOOL)hasKey:(NSString *)key { FanParam info={0}; return [self info:key out:&info]; }
- (NSString *)modeKey:(NSInteger)i { NSString *key=FanKey(i,@"Md"); return [self hasKey:key]?key:FanKey(i,@"md"); }
- (NSInteger)count { double n=[self read:@"FNum"]; return isfinite(n)&&n>=1&&n<=8&&floor(n)==n?(NSInteger)n:0; }
// Les écritures SMC ne sont jamais crues sur parole : une erreur peut avoir été appliquée et un
// succès être annulé aussitôt par thermalmonitord. Seule la relecture fait foi.
- (BOOL)poll:(double)seconds until:(BOOL (^)(void))done {
    for (double waited=0;;waited+=0.1) { if (done()) return YES; if (waited>=seconds) return NO; usleep(100000); }
}
- (NSArray *)fans {
    NSInteger count=[self count]; if(!count)return @[];
    NSMutableArray *fans=[NSMutableArray new];
    for(NSInteger i=0;i<count;i++) {
        double actual=[self read:FanKey(i,@"Ac")],max=[self read:FanKey(i,@"Mx")],min=[self read:FanKey(i,@"Mn")],mode=[self read:[self modeKey:i]],target=[self read:FanKey(i,@"Tg")];
        if(!isfinite(actual)||actual<0||!isfinite(max)||max<=0||max>20000||!isfinite(mode)||!isfinite(target))return @[];
        [fans addObject:@{@"index":@(i),@"rpm":@(actual),@"maxRPM":@(max),@"minRPM":@(isfinite(min)?min:0),@"mode":@(mode),@"targetRPM":@(target)}];
    } return fans;
}
- (BOOL)unlock {
    if(![self hasKey:@"Ftst"])return YES;  // M1, M5 : écriture directe du mode
    // Ftst ne se relit pas fidèlement : seul le code retour de l'écriture compte ici. La preuve
    // du déverrouillage est l'écriture du mode, que setManual réessaie le temps que
    // thermalmonitord cède (3 à 6 s, jusqu'à 10 s).
    if(![self write:@"Ftst" value:1])return NO;
    usleep(500000);
    return YES;
}
- (BOOL)setManual:(NSInteger)i rpm:(double)rpm {
    if(i<0||i>=8||!isfinite(rpm)||rpm<=0)return NO;
    NSString *mode=[self modeKey:i],*target=FanKey(i,@"Tg");
    return [self poll:10 until:^BOOL{
        if([self read:mode]!=1)[self write:mode value:1];
        if(fabs([self read:target]-rpm)>=2)[self write:target value:rpm];
        return [self read:mode]==1 && fabs([self read:target]-rpm)<2;
    }];
}
- (BOOL)setAutomatic:(NSInteger)i {
    if(i<0||i>=8)return NO;
    NSString *key=[self modeKey:i];
    BOOL (^automatic)(void)=^BOOL{ double m=[self read:key]; return m==0||m==3; };
    // Toujours réécrire, puis revérifier après un temps de pose : sur M4, le firmware peut
    // basculer en manuel juste après la lecture, et un « déjà en auto » lu trop tôt mentait.
    BOOL done=[self poll:2 until:^BOOL{ if(!automatic())[self write:key value:0]; return automatic(); }];
    if(!done)return NO;
    usleep(500000);
    return automatic() || [self poll:1 until:^BOOL{ [self write:key value:0]; return automatic(); }];
}
- (BOOL)relock {
    if(![self hasKey:@"Ftst"])return YES;
    // Écrit sans condition : la relecture de Ftst n'est pas fiable dans le sens 1.
    return [self poll:1 until:^BOOL{ return [self write:@"Ftst" value:0] && [self read:@"Ftst"]==0; }];
}
static NSString *const Dir=@"/var/db/com.raphael.status.lid";
static NSString *const Path=@"/var/db/com.raphael.status.lid/fans.plist";
- (BOOL)privateDirectory {
    struct stat st; if(lstat(Dir.fileSystemRepresentation,&st)!=0) {
        if(errno!=ENOENT||mkdir(Dir.fileSystemRepresentation,0700)!=0)return NO;
        if(lstat(Dir.fileSystemRepresentation,&st)!=0)return NO;
    } return S_ISDIR(st.st_mode)&&st.st_uid==0&&(st.st_mode&0077)==0;
}
- (BOOL)savePending:(NSArray *)indices {
    if(![self privateDirectory])return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:indices format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    NSString *temp=[Path stringByAppendingString:@".tmp"];
    int fd=open(temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_CLOEXEC,0600); if(fd<0)return NO;
    BOOL ok=write(fd,data.bytes,data.length)==data.length && fsync(fd)==0; close(fd);
    if(!ok||rename(temp.fileSystemRepresentation,Path.fileSystemRepresentation)!=0)return NO;
    int dir=open(Dir.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC); if(dir<0)return NO;
    ok=fsync(dir)==0; close(dir); return ok;
}
- (NSArray *)loadPending {
    if(![self privateDirectory])return @[@(-1)];
    int fd=open(Path.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if(fd<0)return errno==ENOENT?nil:@[@(-1)];
    struct stat st; BOOL valid=fstat(fd,&st)==0 && S_ISREG(st.st_mode)&&st.st_uid==0&&(st.st_mode&0077)==0&&st.st_size>0&&st.st_size<4096;
    char bytes[4096]; ssize_t n=valid?read(fd,bytes,sizeof(bytes)):-1; close(fd);
    if(n<=0)return @[@(-1)];
    id result=[NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:bytes length:n] options:NSPropertyListImmutable format:nil error:nil];
    return [result isKindOfClass:NSArray.class]?result:@[@(-1)];
}
- (BOOL)clearPending { return unlink(Path.fileSystemRepresentation)==0||errno==ENOENT; }
@end
@implementation TMFanBoost {
    id<TMFanBackend> _backend; NSArray *_indices; NSDictionary *_targets; double _heartbeat,_started;
}
- (instancetype)initWithBackend:(id<TMFanBackend>)backend { if((self=[super init]))_backend=backend; return self; }
- (void)recover {
    _indices=[_backend loadPending];
    if(_indices) { _restorationPending=YES; [self stop:@"Retour à Auto Apple après redémarrage du service."]; }
}
- (void)startMinutes:(NSInteger)minutes percent:(NSInteger)percent now:(double)now {
    if(_active||_restorationPending) { _message=@"Arrêtez le boost précédent avant de recommencer."; return; }
    if(minutes<1||minutes>60) { _message=@"Choisissez une durée de 1 à 60 minutes."; return; }
    if(percent<50||percent>100) { _message=@"Choisissez une vitesse de 50 à 100 %."; return; }
    NSArray *fans=[_backend fans];
    if(!fans.count) { _message=@"Ventilateurs non disponibles sur ce Mac."; return; }
    NSMutableArray *indices=[NSMutableArray new];
    for(NSDictionary *f in fans) {
        if([f[@"mode"] integerValue]==1) { _message=@"Un ventilateur est déjà en manuel. Cliquez « Auto Apple » pour le rendre à macOS, puis relancez."; return; }
        [indices addObject:f[@"index"]];
    }
    if(![_backend savePending:indices]) { _message=@"Impossible de préparer le retour automatique."; return; }
    _indices=indices; _restorationPending=YES;
    if(![_backend unlock]) { [self stop:@"macOS n’a pas cédé le contrôle des ventilateurs. Retour à Auto Apple."]; return; }
    NSMutableDictionary *targets=[NSMutableDictionary new];
    for(NSDictionary *f in fans) {
        // Jamais plus lent que la vitesse du moment : un boost ne doit pas refroidir moins bien.
        double max=[f[@"maxRPM"] doubleValue],target=MIN(max,MAX(round(max*percent/100.0),[f[@"rpm"] doubleValue]));
        if(![_backend setManual:[f[@"index"] integerValue] rpm:target]) { [self stop:@"macOS refuse le boost sur ce Mac. Retour à Auto Apple."]; return; }
        targets[f[@"index"]]=@(target);
    }
    _targets=targets; _percent=percent;
    _active=YES; _verified=NO; _started=now; _heartbeat=now; _deadline=now+minutes*60;
    _message=@"Montée en vitesse · vérification en cours…";
}
- (void)heartbeat:(double)now { if(_active)_heartbeat=now; }
- (void)tick:(double)now thermal:(NSProcessInfoThermalState)thermal {
    if(!_active) { if(_restorationPending)[self stop:_message]; return; }
    if(now>=_deadline) { [self stop:@"Boost terminé · Auto Apple."]; return; }
    if(now-_heartbeat>20) { [self stop:@"Status ne répond plus · retour à Auto Apple."]; return; }
    // Un palier partiel peut devenir insuffisant si la charge monte : macOS reprend la main.
    if(_percent<100 && thermal>=NSProcessInfoThermalStateSerious) { [self stop:@"Mac chaud · retour à Auto Apple."]; return; }
    NSArray *fans=[_backend fans]; BOOL valid=fans.count==_indices.count,fast=valid;
    for(NSDictionary *f in fans) {
        double target=[_targets[f[@"index"]] doubleValue];
        if(!_targets[f[@"index"]]||[f[@"mode"] integerValue]!=1||fabs([f[@"targetRPM"] doubleValue]-target)>2)valid=NO;
        if([f[@"rpm"] doubleValue]<0.8*target)fast=NO;
    }
    if(!valid||(!fast&&now-_started>=20)) { [self stop:@"Boost non confirmé par les ventilateurs · retour à Auto Apple."]; return; }
    _verified=fast; _message=fast?@"Boost actif · vitesse vérifiée.":@"Montée en vitesse · vérification en cours…";
}
- (void)stop:(NSString *)reason {
    _active=NO; _verified=NO; _deadline=0; _targets=nil;
    BOOL ok=YES;
    NSMutableArray *indices=[NSMutableArray new];
    for(id index in _indices) {
        if([index isKindOfClass:NSNumber.class]&&[index integerValue]>=0&&[index integerValue]<8)[indices addObject:index];
        else for(NSDictionary *f in [_backend fans])[indices addObject:f[@"index"]];  // journal illisible : tous
    }
    for(NSNumber *index in [NSOrderedSet orderedSetWithArray:indices])if(![_backend setAutomatic:index.integerValue])ok=NO;
    if(_indices&&![_backend relock])ok=NO;
    if(_indices&&ok) {
        // Ftst relâché : revérifier qu'aucun ventilateur n'est resté en manuel.
        for(NSDictionary *f in [_backend fans])if([f[@"mode"] integerValue]==1&&![_backend setAutomatic:[f[@"index"] integerValue]])ok=NO;
    }
    if(ok && _indices)ok=[_backend clearPending];
    _restorationPending=!ok;
    if(ok)_indices=nil;
    _message=ok?reason:@"Retour à Auto Apple à vérifier · le service réessaie.";
}
- (void)restoreAll:(NSString *)reason {
    NSMutableArray *indices=[NSMutableArray arrayWithArray:_indices?:@[]];
    for(NSDictionary *f in [_backend fans])[indices addObject:f[@"index"]];
    _indices=indices; [self stop:reason];
}
- (NSDictionary *)snapshot:(double)now {
    NSArray *fans=[_backend fans]?:@[];
    NSString *message=_message?:@"Auto Apple";
    BOOL manual=NO;
    if (!_active && !_restorationPending)
        for (NSDictionary *fan in fans) if ([fan[@"mode"] integerValue]==1) {
            manual=YES; message=@"Un ventilateur est resté en manuel · cliquez « Auto Apple » pour le rendre à macOS."; break;
        }
    return @{@"version":@(TMFanBoostVersion),@"active":@(_active),@"verified":@(_verified),@"restorationPending":@(_restorationPending),
        @"manualOutsideBoost":@(manual),@"percent":@(_active?_percent:0),
        @"remainingSeconds":@(MAX(0,_deadline-now)),@"message":message,@"fans":fans};
}
@end
