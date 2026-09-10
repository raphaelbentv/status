#import "StatusLidClient.h"
#import "StatusLidProtocol.h"
#import <ServiceManagement/ServiceManagement.h>

@implementation TMLidClient {
    NSXPCConnection *_connection;
    NSDictionary *_remote;
    NSString *_error;
    BOOL _refreshing;
    NSUInteger _request;
    id _activity;
}
- (SMAppService *)service { return [SMAppService daemonServiceWithPlistName:TMLidServicePlist]; }
- (NSDictionary *)snapshot {
    SMAppServiceStatus status=self.service.status;
    NSMutableDictionary *result=[(_remote ?: @{@"active":@NO}) mutableCopy];
    result[@"authorized"]=@(status==SMAppServiceStatusEnabled);
    result[@"approvalRequired"]=@(status==SMAppServiceStatusRequiresApproval);
    result[@"busy"]=@(_refreshing);
    result[@"available"]=@(TMLidPeerRequirement(TMLidServiceName)!=nil);
    if (_error.length) { result[@"message"]=_error; result[@"unconfirmed"]=@(status==SMAppServiceStatusEnabled); }
    return result;
}
- (void)changed { if (self.onChange) self.onChange(); }
- (void)keepHeartbeatAwake:(BOOL)active {
    if (active && !_activity)
        _activity=[NSProcessInfo.processInfo beginActivityWithOptions:NSActivityUserInitiatedAllowingIdleSystemSleep
            reason:@"Surveillance de la session capot fermé"];
    if (!active && _activity) { [NSProcessInfo.processInfo endActivity:_activity]; _activity=nil; }
}
- (void)requestAuthorization {
    if (!TMLidPeerRequirement(TMLidServiceName)) { _error=@"Une signature stable est nécessaire pour ce mode."; [self changed]; return; }
    SMAppService *service=self.service;
    NSError *error=nil;
    if (service.status!=SMAppServiceStatusEnabled && service.status!=SMAppServiceStatusRequiresApproval)
        [service registerAndReturnError:&error];
    _error=error.localizedDescription;
    if (service.status==SMAppServiceStatusRequiresApproval) {
        _error=@"Autorisez le service Status dans Ouverture et extensions, puis revenez ici pour démarrer.";
        [SMAppService openSystemSettingsLoginItems];
    }
    [self changed]; [self refresh];  // Jamais de démarrage automatique après l'autorisation.
}
- (BOOL)connect {
    if (self.service.status!=SMAppServiceStatusEnabled) return NO;
    if (_connection) return YES;
    NSString *requirement=TMLidPeerRequirement(TMLidServiceName);
    if (!requirement) return NO;
    NSXPCConnection *connection=[[NSXPCConnection alloc] initWithMachServiceName:TMLidServiceName options:NSXPCConnectionPrivileged];
    [connection setCodeSigningRequirement:requirement];
    connection.remoteObjectInterface=[NSXPCInterface interfaceWithProtocol:@protocol(TMLidService)];
    __weak typeof(self) weakSelf=self;
    __weak NSXPCConnection *weakConnection=connection;
    connection.invalidationHandler=^{ dispatch_async(dispatch_get_main_queue(), ^{
        typeof(self) self=weakSelf; if (!self) return;
        if (self->_connection!=weakConnection) return;
        self->_request++;
        self->_connection=nil; self->_refreshing=NO;
        [self keepHeartbeatAwake:NO];
        self->_error=@"Service indisponible. Le service restaure les réglages après perte de contact.";
        [self changed];
    }); };
    connection.interruptionHandler=^{ [weakConnection invalidate]; };
    _connection=connection; [connection resume]; return YES;
}
- (void)request:(NSInteger)kind minutes:(NSInteger)minutes {
    if (_refreshing) return;
    if (![self connect]) return;
    _refreshing=YES;
    NSUInteger request=++_request;
    __weak typeof(self) weakSelf=self;
    void (^complete)(NSDictionary *,NSString *)=^(NSDictionary *data,NSString *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            typeof(self) self=weakSelf; if (!self || request!=self->_request) return;
            BOOL changed = kind!=0 || ![self->_remote isEqual:data] || ![(self->_error ?: @"") isEqual:(error ?: @"")];
            self->_refreshing=NO; self->_error=error;
            if (data) self->_remote=data;
            [self keepHeartbeatAwake:!error && [data[@"active"] boolValue]];
            if (changed) [self changed];
        });
    };
    id<TMLidService> remote=[_connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        complete(nil,@"Impossible de joindre le service. Vérifiez son autorisation dans les réglages macOS.");
    }];
    void (^reply)(NSDictionary *)=^(NSDictionary *data) { complete(data,nil); };
    if (kind==1) [remote startMinutes:minutes reply:reply];
    else if (kind==2) [remote stopWithReply:reply];
    else [remote statusWithReply:reply];
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,12*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
        typeof(self) self=weakSelf;
        if (self && self->_refreshing && request==self->_request) {
            self->_refreshing=NO; self->_request++;
            self->_error=@"Le service ne répond pas ; état non confirmé.";
            [self->_connection invalidate]; [self changed];
        }
    });
}
- (void)refresh { [self request:0 minutes:0]; }
- (void)startMinutes:(NSInteger)minutes { [self request:1 minutes:minutes]; }
- (void)stop { [self request:2 minutes:0]; }
- (void)invalidate { self.onChange=nil; _request++; [self keepHeartbeatAwake:NO]; [_connection invalidate]; _connection=nil; }
- (void)dealloc { if (_activity) [NSProcessInfo.processInfo endActivity:_activity]; [_connection invalidate]; }
@end
