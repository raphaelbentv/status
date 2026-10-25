#import "StatusCodexServer.h"
#import <AppKit/AppKit.h>

static NSError *TMError(NSString *message) {
    return [NSError errorWithDomain:@"Status.CodexAppServer" code:1 userInfo:@{NSLocalizedDescriptionKey: message ?: @"Erreur inconnue"}];
}

NSString *TMCodexExecutablePath(void) {
    NSString *override = NSProcessInfo.processInfo.environment[@"STATUS_CODEX_PATH"];
    if (override.length && [NSFileManager.defaultManager isExecutableFileAtPath:override]) return override;
    // Le nom visible de l'app et la disposition du CLI ont changé. Résoudre aussi son bundle ID
    // permet de la retrouver même si ChatGPT.app est renommée ou installée hors /Applications.
    NSMutableArray<NSString *> *candidates = [NSMutableArray array];
    NSURL *installedApp = [NSWorkspace.sharedWorkspace URLForApplicationWithBundleIdentifier:@"com.openai.codex"];
    for (NSString *appPath in @[@"/Applications/ChatGPT.app", @"/Applications/Codex.app", installedApp.path ?: @""]) {
        if (!appPath.length) continue;
        NSString *resources = [appPath stringByAppendingPathComponent:@"Contents/Resources"];
        [candidates addObjectsFromArray:@[
            [resources stringByAppendingPathComponent:@"codex-cli/CodexCLI.app/Contents/MacOS/codex"],
            [resources stringByAppendingPathComponent:@"codex-cli/bin/codex"],
            [resources stringByAppendingPathComponent:@"codex"]
        ]];
    }
    [candidates addObjectsFromArray:@[
        [NSHomeDirectory() stringByAppendingPathComponent:@".local/bin/codex"],
        @"/opt/homebrew/bin/codex", @"/usr/local/bin/codex"
    ]];
    for (NSString *candidate in candidates) {
        if ([NSFileManager.defaultManager isExecutableFileAtPath:candidate]) return candidate;
    }
    return @"";
}

@interface TMCodexAppServer ()
@property NSTask *task;
@property NSPipe *inputPipe;
@property NSPipe *outputPipe;
@property NSPipe *errorPipe;
@property NSMutableData *readBuffer;
@property NSMutableDictionary<NSNumber *, TMAppServerCompletion> *pending;
@property NSInteger nextRequestID;
@property BOOL initialized;
@property BOOL starting;
@end

@implementation TMCodexAppServer

- (BOOL)isIdle { return !self.starting && self.pending.count == 0; }

- (instancetype)init {
    if ((self = [super init])) {
        _readBuffer = [NSMutableData data];
        _pending = [NSMutableDictionary dictionary];
        _nextRequestID = 1;
    }
    return self;
}

- (void)start:(TMAppServerCompletion)completion {
    if (self.initialized) { if (completion) completion(@{}, nil); return; }
    if (self.starting) {
        dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(0.15 * NSEC_PER_SEC)), dispatch_get_main_queue(), ^{ [self start:completion]; });
        return;
    }
    NSString *path = TMCodexExecutablePath();
    if (!path.length) {
        if (completion) completion(nil, TMError(@"CLI Codex introuvable. Installez l’app ChatGPT ou définissez STATUS_CODEX_PATH."));
        return;
    }
    self.starting = YES;
    self.task = [NSTask new];
    self.task.executableURL = [NSURL fileURLWithPath:path];
    self.task.arguments = @[@"app-server", @"--listen", @"stdio://"];
    if (self.codexHome.length) {
        [NSFileManager.defaultManager createDirectoryAtPath:self.codexHome
                                withIntermediateDirectories:YES
                                                 attributes:@{NSFilePosixPermissions: @0700}
                                                      error:nil];
        NSMutableDictionary *environment = [NSProcessInfo.processInfo.environment mutableCopy];
        environment[@"CODEX_HOME"] = self.codexHome;
        self.task.environment = environment;
    }
    self.inputPipe = [NSPipe pipe];
    self.outputPipe = [NSPipe pipe];
    self.errorPipe = [NSPipe pipe];
    self.task.standardInput = self.inputPipe;
    self.task.standardOutput = self.outputPipe;
    self.task.standardError = self.errorPipe;

    __weak typeof(self) weakSelf = self;
    self.outputPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) {
        NSData *data = handle.availableData;
        if (!data.length) return;
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf consume:data]; });
    };
    // Drain diagnostics so the child process can never block, but never surface auth material.
    self.errorPipe.fileHandleForReading.readabilityHandler = ^(NSFileHandle *handle) { (void)handle.availableData; };
    self.task.terminationHandler = ^(NSTask *task) {
        dispatch_async(dispatch_get_main_queue(), ^{ [weakSelf terminated:task.terminationStatus]; });
    };
    NSError *launchError;
    if (![self.task launchAndReturnError:&launchError]) {
        self.starting = NO;
        if (completion) completion(nil, launchError);
        return;
    }
    NSDictionary *params = @{ @"clientInfo": @{ @"name": @"status_macos", @"title": @"Status", @"version": @"0.1.0" } };
    [self sendRequest:@"initialize" params:params completion:^(id result, NSError *error) {
        self.starting = NO;
        if (!error) {
            self.initialized = YES;
            [self notify:@"initialized" params:@{}];
        }
        if (completion) completion(result, error);
    }];
}

- (void)request:(NSString *)method params:(NSDictionary *)params completion:(TMAppServerCompletion)completion {
    [self start:^(id result, NSError *error) {
        (void)result;
        if (error) { if (completion) completion(nil, error); return; }
        [self sendRequest:method params:params completion:completion];
    }];
}

- (void)sendRequest:(NSString *)method params:(NSDictionary *)params completion:(TMAppServerCompletion)completion {
    NSNumber *requestID = @(self.nextRequestID++);
    NSMutableDictionary *message = [@{ @"method": method, @"id": requestID } mutableCopy];
    if (params) message[@"params"] = params;
    if (completion) self.pending[requestID] = [completion copy];
    [self writeMessage:message];
}

- (void)notify:(NSString *)method params:(NSDictionary *)params {
    NSMutableDictionary *message = [@{ @"method": method } mutableCopy];
    if (params) message[@"params"] = params;
    [self writeMessage:message];
}

- (void)writeMessage:(NSDictionary *)message {
    NSError *error;
    NSData *json = [NSJSONSerialization dataWithJSONObject:message options:0 error:&error];
    if (!json) return;
    NSMutableData *line = [json mutableCopy];
    [line appendBytes:"\n" length:1];
    @try { [self.inputPipe.fileHandleForWriting writeData:line]; }
    @catch (__unused NSException *exception) { [self terminated:-1]; }
}

- (void)consume:(NSData *)data {
    [self.readBuffer appendData:data];
    while (YES) {
        const void *bytes = self.readBuffer.bytes;
        NSUInteger length = self.readBuffer.length;
        const void *newline = memchr(bytes, '\n', length);
        if (!newline) break;
        NSUInteger lineLength = (const uint8_t *)newline - (const uint8_t *)bytes;
        NSData *line = [self.readBuffer subdataWithRange:NSMakeRange(0, lineLength)];
        [self.readBuffer replaceBytesInRange:NSMakeRange(0, lineLength + 1) withBytes:NULL length:0];
        if (!line.length) continue;
        NSDictionary *message = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![message isKindOfClass:NSDictionary.class]) continue;
        NSNumber *requestID = message[@"id"];
        if (requestID) {
            TMAppServerCompletion block = self.pending[requestID];
            [self.pending removeObjectForKey:requestID];
            NSDictionary *rpcError = message[@"error"];
            NSError *error = rpcError ? TMError(rpcError[@"message"] ?: @"Le serveur Codex a refusé la requête.") : nil;
            if (block) block(message[@"result"], error);
        } else {
            NSString *method = message[@"method"];
            NSDictionary *params = [message[@"params"] isKindOfClass:NSDictionary.class] ? message[@"params"] : @{};
            if (method.length && self.notificationHandler) self.notificationHandler(method, params);
        }
    }
}

- (void)terminated:(int)status {
    if (!self.task && !self.starting && !self.initialized) return;
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    self.errorPipe.fileHandleForReading.readabilityHandler = nil;
    self.task = nil;
    self.starting = NO;
    self.initialized = NO;
    NSError *error = TMError(status == 0 ? @"Le serveur Codex s’est arrêté." : @"Le serveur Codex a quitté de façon inattendue.");
    NSArray *callbacks = self.pending.allValues;
    [self.pending removeAllObjects];
    for (TMAppServerCompletion block in callbacks) block(nil, error);
}

- (void)stop {
    self.outputPipe.fileHandleForReading.readabilityHandler = nil;
    self.errorPipe.fileHandleForReading.readabilityHandler = nil;
    if (self.task.running) [self.task terminate];
    self.task = nil;
    self.initialized = NO;
    self.starting = NO;
    [self.readBuffer setLength:0];
}

@end
