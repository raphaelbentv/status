#import "StatusLidMode.h"
#import "StatusLidProtocol.h"
#import <IOKit/ps/IOPowerSources.h>
#import <IOKit/ps/IOPSKeys.h>
#import <sys/stat.h>
#import <fcntl.h>
#import <signal.h>
#import <unistd.h>
#import <errno.h>

static NSString *const JournalDirectory = @"/var/db/com.raphael.status.lid";
static NSString *const JournalPath = @"/var/db/com.raphael.status.lid/restore.plist";
static double Clock(void) { return NSProcessInfo.processInfo.systemUptime; }
static double Battery(void) {
    CFTypeRef raw = IOPSCopyPowerSourcesInfo();
    if (!raw) return -1;
    NSArray *sources = CFBridgingRelease(IOPSCopyPowerSourcesList(raw));
    double percent = -1;
    for (id source in sources) {
        NSDictionary *d = (__bridge NSDictionary *)IOPSGetPowerSourceDescription(raw, (__bridge CFTypeRef)source);
        if (![d[@kIOPSTypeKey] isEqual:@kIOPSInternalBatteryType]) continue;
        NSNumber *current = d[@kIOPSCurrentCapacityKey], *max = d[@kIOPSMaxCapacityKey];
        if ([current isKindOfClass:NSNumber.class] && [max isKindOfClass:NSNumber.class] && max.doubleValue > 0)
            percent = 100.0 * current.doubleValue / max.doubleValue;
    }
    CFRelease(raw); return percent;
}
static NSString *PM(NSArray<NSString *> *arguments) {
    NSTask *task = [NSTask new]; task.executableURL = [NSURL fileURLWithPath:@"/usr/bin/pmset"];
    task.arguments = arguments;
    task.environment = @{@"PATH":@"/usr/bin:/bin:/usr/sbin:/sbin", @"LC_ALL":@"C"};
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    NSPipe *pipe = [NSPipe pipe]; task.standardOutput = pipe;
    if (![task launchAndReturnError:nil]) return nil;
    __block NSMutableData *data = [NSMutableData data];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY,0), ^{
        while (YES) {
            NSData *chunk = [pipe.fileHandleForReading readDataOfLength:4096];
            if (!chunk.length) break;
            if (data.length + chunk.length <= 65536) [data appendData:chunk];
        }
    });
    double deadline = Clock() + 5;
    while (task.running && Clock() < deadline) usleep(10000);
    BOOL timedOut = task.running;
    if (timedOut) kill(task.processIdentifier,SIGKILL);
    [task waitUntilExit]; dispatch_group_wait(group,DISPATCH_TIME_FOREVER);
    return !timedOut && task.terminationStatus == 0 ? [[NSString alloc] initWithData:data encoding:NSUTF8StringEncoding] : nil;
}
static BOOL PrivateDirectory(void) {
    struct stat st;
    if (lstat(JournalDirectory.fileSystemRepresentation,&st) != 0) {
        if (errno != ENOENT || mkdir(JournalDirectory.fileSystemRepresentation,0700) != 0) return NO;
        if (lstat(JournalDirectory.fileSystemRepresentation,&st) != 0) return NO;
    }
    return S_ISDIR(st.st_mode) && st.st_uid == 0 && (st.st_mode & 0077) == 0;
}
@interface TMLidSystemBackend : NSObject <TMLidBackend> @end
@implementation TMLidSystemBackend
- (NSDictionary *)powerSettings {
    NSString *live=PM(@[@"-g"]), *custom=PM(@[@"-g",@"custom"]);
    return live && custom ? TMLidParsePowerSettings([live stringByAppendingFormat:@"\n%@",custom]) : nil;
}
- (BOOL)setSleepDisabled:(BOOL)disabled { return PM(@[@"-a",@"disablesleep",disabled?@"1":@"0"]) != nil; }
- (BOOL)setPowerMode:(NSInteger)mode battery:(BOOL)battery {
    if (mode<0 || mode>2) return NO;
    return PM(@[battery?@"-b":@"-c",@"powermode",[@(mode) stringValue]]) != nil;
}
- (NSDictionary *)loadJournal {
    if (!PrivateDirectory()) return @{@"invalid":@YES};
    int fd=open(JournalPath.fileSystemRepresentation,O_RDONLY|O_NOFOLLOW|O_CLOEXEC);
    if (fd<0) return errno==ENOENT ? nil : @{@"invalid":@YES};
    struct stat st; BOOL valid=fstat(fd,&st)==0 && S_ISREG(st.st_mode) && st.st_uid==0 &&
        (st.st_mode&0077)==0 && st.st_size>0 && st.st_size<4096;
    char bytes[4096]; ssize_t n=valid?read(fd,bytes,sizeof(bytes)):-1; close(fd);
    if (n<=0) return @{@"invalid":@YES};
    id result=[NSPropertyListSerialization propertyListWithData:[NSData dataWithBytes:bytes length:(NSUInteger)n]
        options:NSPropertyListImmutable format:nil error:nil];
    return [result isKindOfClass:NSDictionary.class] ? result : @{@"invalid":@YES};
}
- (BOOL)saveJournal:(NSDictionary *)journal {
    if (!PrivateDirectory()) return NO;
    NSData *data=[NSPropertyListSerialization dataWithPropertyList:journal format:NSPropertyListBinaryFormat_v1_0 options:0 error:nil];
    if (!data) return NO;
    NSString *temp=[JournalDirectory stringByAppendingPathComponent:@"restore.tmp"];
    int fd=open(temp.fileSystemRepresentation,O_WRONLY|O_CREAT|O_TRUNC|O_NOFOLLOW|O_CLOEXEC,0600);
    if (fd<0) return NO;
    BOOL ok=write(fd,data.bytes,data.length)==(ssize_t)data.length && fsync(fd)==0;
    close(fd);
    if (!ok || rename(temp.fileSystemRepresentation,JournalPath.fileSystemRepresentation)!=0) return NO;
    int dir=open(JournalDirectory.fileSystemRepresentation,O_RDONLY|O_DIRECTORY|O_CLOEXEC);
    if (dir>=0) { fsync(dir); close(dir); }
    return YES;
}
- (BOOL)clearJournal { return unlink(JournalPath.fileSystemRepresentation)==0 || errno==ENOENT; }
@end

@interface TMLidServer : NSObject <NSXPCListenerDelegate,TMLidService>
@property TMLidMode *mode;
@property (weak) NSXPCConnection *owner;
@end
@implementation TMLidServer
- (NSDictionary *)snapshot {
    double battery=Battery();
    return @{@"active":@(self.mode.active), @"restorationPending":@(self.mode.restorationPending),
        @"remainingSeconds":@(MAX(0,self.mode.deadline-Clock())), @"message":self.mode.message ?: @"",
        @"batteryPercent":@(battery), @"thermalState":@(NSProcessInfo.processInfo.thermalState)};
}
- (BOOL)listener:(NSXPCListener *)listener shouldAcceptNewConnection:(NSXPCConnection *)connection {
    NSString *requirement=TMLidPeerRequirement(@"com.raphael.status");
    if (!requirement || connection.effectiveUserIdentifier==0) return NO;
    [connection setCodeSigningRequirement:requirement];
    connection.exportedInterface=[NSXPCInterface interfaceWithProtocol:@protocol(TMLidService)];
    connection.exportedObject=self;
    __weak NSXPCConnection *weakConnection=connection;
    connection.invalidationHandler=^{ dispatch_async(dispatch_get_main_queue(), ^{
        if (self.owner==weakConnection) { [self.mode stop:@"Status a été fermé ou déconnecté."]; self.owner=nil; }
    }); };
    connection.interruptionHandler=connection.invalidationHandler;
    [connection resume]; return YES;
}
- (void)statusWithReply:(void (^)(NSDictionary *))reply {
    NSXPCConnection *client=NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        if (self.owner==client) [self.mode heartbeatAt:Clock()];
        reply([self snapshot]);
    });
}
- (void)startMinutes:(NSInteger)minutes reply:(void (^)(NSDictionary *))reply {
    NSXPCConnection *client=NSXPCConnection.currentConnection;
    dispatch_async(dispatch_get_main_queue(), ^{
        [self.mode startMinutes:minutes battery:Battery() thermal:NSProcessInfo.processInfo.thermalState now:Clock()];
        if (self.mode.active && !self.owner) self.owner=client;
        reply([self snapshot]);
    });
}
- (void)stopWithReply:(void (^)(NSDictionary *))reply {
    dispatch_async(dispatch_get_main_queue(), ^{ [self.mode stop:@"Arrêt demandé."]; self.owner=nil; reply([self snapshot]); });
}
@end
int main(int argc,const char *argv[]) {
    @autoreleasepool {
        // Diagnostic explicite, non privilégié et sans journal ni écriture de réglage.
        if (argc==2 && strcmp(argv[1],"--diagnose")==0) {
            NSDictionary *d=@{@"power":[[TMLidSystemBackend new] powerSettings] ?: @{},
                @"batteryPercent":@(Battery()), @"thermalState":@(NSProcessInfo.processInfo.thermalState),
                @"peerRequirement":TMLidPeerRequirement(@"com.raphael.status") ?: @""};
            NSData *json=[NSJSONSerialization dataWithJSONObject:d options:0 error:nil];
            fwrite(json.bytes,1,json.length,stdout); fputc('\n',stdout); return 0;
        }
        if (argc!=1 || geteuid()!=0) return 77;
        TMLidServer *server=[TMLidServer new];
        server.mode=[[TMLidMode alloc] initWithBackend:[TMLidSystemBackend new]];
        [server.mode recover];
        NSXPCListener *listener=[[NSXPCListener alloc] initWithMachServiceName:TMLidServiceName];
        listener.delegate=server; [listener resume];
        [NSTimer scheduledTimerWithTimeInterval:5 repeats:YES block:^(NSTimer *timer) {
            [server.mode tickBattery:Battery() thermal:NSProcessInfo.processInfo.thermalState now:Clock()];
        }];
        signal(SIGTERM,SIG_IGN); signal(SIGINT,SIG_IGN);
        dispatch_source_t term=dispatch_source_create(DISPATCH_SOURCE_TYPE_SIGNAL,SIGTERM,0,dispatch_get_main_queue());
        dispatch_source_set_event_handler(term, ^{ [server.mode stop:@"Service arrêté."]; exit(server.mode.restorationPending?1:0); });
        dispatch_resume(term);
        [[NSRunLoop currentRunLoop] run];
    }
    return 0;
}
