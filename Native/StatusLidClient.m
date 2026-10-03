#import "StatusLidClient.h"
#import "StatusLidProtocol.h"
#import <ServiceManagement/ServiceManagement.h>
#import <AppKit/AppKit.h>

@implementation TMLidClient {
    NSXPCConnection *_connection;
    NSDictionary *_remote;
    NSString *_error;
    BOOL _refreshing;
    NSUInteger _request;
    id _activity;
}
- (SMAppService *)service { return [SMAppService daemonServiceWithPlistName:TMLidServicePlist]; }
- (instancetype)init {
    if ((self=[super init])) [self retireUnsignedRegistration];
    return self;
}
// Sans signature Apple, un daemon SMAppService ne peut jamais démarrer (contrainte de lancement
// vide) : launchd le relance en boucle et smd le recrée après tout bootout. On le désenregistre.
- (void)retireUnsignedRegistration {
    SMAppService *previous=self.service;
    if (!TMLidSigningReady() && previous.status!=SMAppServiceStatusNotRegistered) [previous unregisterAndReturnError:nil];
}
- (BOOL)authorized { return TMLidInstalledServiceReady() || (TMLidSigningReady() && self.service.status==SMAppServiceStatusEnabled); }
- (NSDictionary *)snapshot {
    SMAppServiceStatus status=self.service.status;
    NSMutableDictionary *result=[(_remote ?: @{@"active":@NO}) mutableCopy];
    if (_remote && ![_remote[@"controlVersion"] isEqual:@4]) {
        result[@"unconfirmed"]=@YES;
        result[@"message"]=@"Ancien service chargé. Arrêtez le mode puis mettez le service à jour.";
    }
    result[@"authorized"]=@(self.authorized);
    result[@"approvalRequired"]=@(status==SMAppServiceStatusRequiresApproval);
    result[@"busy"]=@(_refreshing);
    result[@"installerAvailable"]=@(TMLidInstallerReady());
    result[@"available"]=@(TMLidSigningReady() || TMLidInstallerReady());
    if (!self.authorized && TMLidInstallerReady() && !TMLidSigningReady())
        result[@"message"]=@"Installez le service macOS une fois avec votre autorisation administrateur, puis choisissez la durée.";
    else if (!TMLidSigningReady() && !TMLidInstallerReady())
        result[@"message"]=@"Installateur du service absent ou signature invalide. Réinstallez Status.";
    if (_error.length) { result[@"message"]=_error; result[@"unconfirmed"]=@(self.authorized); }
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
    if (!TMLidSigningReady()) {
        if (!TMLidInstallerReady()) { _error=@"Installateur du service absent ou signature invalide."; [self changed]; return; }
        if ([_remote[@"active"] boolValue] || [_remote[@"restorationPending"] boolValue] || [_remote[@"fanBoost"][@"active"] boolValue] || [_remote[@"fanBoost"][@"restorationPending"] boolValue]) {
            _error=@"Arrêtez et restaurez la session avant de réinstaller le service."; [self changed]; return;
        }
        [self retireUnsignedRegistration];  // Ne bloque plus le paquet (label distinct) : best effort.
        NSURL *package=[NSBundle.mainBundle URLForResource:@"StatusLidService" withExtension:@"pkg"];
        BOOL opened=package && [NSWorkspace.sharedWorkspace openURL:package];
        _error=opened ? @"Terminez l’installation dans la fenêtre macOS. La session reste désactivée." : @"Impossible d’ouvrir l’installateur macOS.";
        [self changed]; return;
    }
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
    if (!self.authorized) return NO;
    if (_connection) return YES;
    NSString *requirement=TMLidPeerRequirement(TMLidHelperIdentifier);
    if (!requirement) return NO;
    NSXPCConnection *connection=[[NSXPCConnection alloc] initWithMachServiceName:(TMLidInstalledServiceReady() ? TMLidInstalledServiceName : TMLidServiceName) options:NSXPCConnectionPrivileged];
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
- (void)request:(NSInteger)kind minutes:(NSInteger)minutes { [self request:kind minutes:minutes percent:100]; }
- (void)request:(NSInteger)kind minutes:(NSInteger)minutes percent:(NSInteger)percent {
    if (_refreshing) return;
    if (kind==1 && ![_remote[@"controlVersion"] isEqual:@4]) {
        _error=@"Connexion au service à vérifier avant le démarrage."; [self changed]; [self refresh]; return;
    }
    if ((kind==3 || kind==4) && ![_remote[@"fanBoost"][@"version"] isEqual:@2]) {
        _error=@"Mettez le service macOS à jour pour contrôler les ventilateurs."; [self changed]; return;
    }
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
            [self keepHeartbeatAwake:!error && ([data[@"active"] boolValue] || [data[@"fanBoost"][@"active"] boolValue])];
            if (changed) [self changed];
        });
    };
    id<TMLidService> remote=[_connection remoteObjectProxyWithErrorHandler:^(NSError *error) {
        complete(nil,@"Impossible de joindre le service. Vérifiez son autorisation dans les réglages macOS.");
    }];
    void (^reply)(NSDictionary *)=^(NSDictionary *data) { complete(data,nil); };
    if (kind==1) [remote startMinutes:minutes reply:reply];
    else if (kind==2) [remote stopWithReply:reply];
    else if (kind==3) [remote startFanBoostMinutes:minutes percent:percent reply:reply];
    else if (kind==4) [remote stopFanBoostWithReply:reply];
    else [remote statusWithReply:reply];
    // Prise de main des ventilateurs : thermalmonitord met 3 à 6 s à céder, puis chaque écriture est relue.
    dispatch_after(dispatch_time(DISPATCH_TIME_NOW,(kind==3||kind==4?35:12)*NSEC_PER_SEC),dispatch_get_main_queue(), ^{
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
- (void)startFanBoostMinutes:(NSInteger)minutes percent:(NSInteger)percent { [self request:3 minutes:minutes percent:percent]; }
- (void)stopFanBoost { [self request:4 minutes:0]; }
- (void)invalidate { self.onChange=nil; _request++; [self keepHeartbeatAwake:NO]; [_connection invalidate]; _connection=nil; }
- (void)dealloc { if (_activity) [NSProcessInfo.processInfo endActivity:_activity]; [_connection invalidate]; }
@end
