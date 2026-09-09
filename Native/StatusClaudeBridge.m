#import "StatusClaudeBridge.h"
#import "StatusAccounts.h"
#import "StatusQuota.h"
#include <math.h>
#include <signal.h>
#include <unistd.h>

static NSDictionary *TMReadBridgeJSON(NSString *path) {
    NSData *data = [NSData dataWithContentsOfFile:path];
    id json = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    return [json isKindOfClass:NSDictionary.class] ? json : @{};
}
static BOOL TMWriteBridgeJSON(NSDictionary *json, NSString *path, NSError **error) {
    NSData *data = [NSJSONSerialization dataWithJSONObject:json options:0 error:error];
    if (!data || ![data writeToFile:path options:NSDataWritingAtomic error:error]) return NO;
    return [NSFileManager.defaultManager setAttributes:@{NSFilePosixPermissions:@0600} ofItemAtPath:path error:error];
}
NSString *TMClaudeProfilePath(NSString *accountId) {
    if (!TMIsAccountID(accountId)) return nil;
    return [[TMSupportDirectory() stringByAppendingPathComponent:@"ClaudeCode"] stringByAppendingPathComponent:accountId];
}
NSString *TMShellQuote(NSString *value) {
    return [NSString stringWithFormat:@"'%@'", [value stringByReplacingOccurrencesOfString:@"'" withString:@"'\\''"]];
}
NSString *TMClaudeExecutable(void) {
#ifdef STATUS_BRIDGE_TESTING
    NSString *fixture = NSProcessInfo.processInfo.environment[@"STATUS_TEST_CLAUDE"];
    if (fixture.length) return fixture;
#endif
    for (NSString *path in @[@"~/.local/bin/claude", @"/opt/homebrew/bin/claude", @"/usr/local/bin/claude"]) {
        NSString *expanded = path.stringByExpandingTildeInPath;
        if ([NSFileManager.defaultManager isExecutableFileAtPath:expanded]) return expanded;
    }
    return nil;
}
// An allowlist prevents an inherited API key, gateway or OAuth token from selecting another
// account. Only the unmodified Claude binary manages credentials, in its own scoped Keychain.
static NSDictionary *TMClaudeEnvironment(NSString *profile) {
    NSMutableDictionary *env = [NSMutableDictionary dictionary];
    for (NSString *key in @[@"HOME", @"USER", @"LOGNAME", @"TMPDIR", @"SHELL", @"LANG"]) {
        NSString *value = NSProcessInfo.processInfo.environment[key];
        if (value) env[key] = value;
    }
    env[@"PATH"] = @"/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin";
    env[@"CLAUDE_CONFIG_DIR"] = profile;
    env[@"TERM"] = @"xterm-256color";
    return env;
}
static NSData *TMClaudeAuth(NSString *profile, NSString *verb, int *status) {
    NSString *executable = TMClaudeExecutable();
    *status = -1;
    if (!executable) return nil;
    NSTask *task = [NSTask new];
    task.executableURL = [NSURL fileURLWithPath:executable];
    task.arguments = @[@"auth", verb];
    task.environment = TMClaudeEnvironment(profile);
    task.currentDirectoryURL = [NSURL fileURLWithPath:profile];
    NSPipe *pipe = [NSPipe pipe];
    task.standardOutput = pipe;
    task.standardError = NSFileHandle.fileHandleWithNullDevice;
    task.standardInput = NSFileHandle.fileHandleWithNullDevice;
    if (![task launchAndReturnError:nil]) return nil;
    // Drain concurrently, but bound output, lifetime and memory even if the CLI misbehaves.
    NSMutableData *output = [NSMutableData data];
    dispatch_group_t group = dispatch_group_create();
    dispatch_group_async(group, dispatch_get_global_queue(QOS_CLASS_UTILITY, 0), ^{
        while (YES) {
            NSData *chunk = [pipe.fileHandleForReading readDataOfLength:4096];
            if (!chunk.length) break;
            if (output.length + chunk.length <= 65536) [output appendData:chunk];
        }
    });
    NSDate *deadline = [NSDate dateWithTimeIntervalSinceNow:8];
    while (task.running && deadline.timeIntervalSinceNow > 0) usleep(20000);
    if (task.running) { kill(task.processIdentifier, SIGKILL); [task waitUntilExit]; }
    else *status = task.terminationStatus;
    dispatch_group_wait(group, DISPATCH_TIME_FOREVER);
    return output;
}
NSDictionary *TMClaudeAuthStatus(NSString *profile) {
    int status;
    NSData *data = TMClaudeAuth(profile, @"status", &status);
    id raw = data ? [NSJSONSerialization JSONObjectWithData:data options:0 error:nil] : nil;
    if (status < 0 || ![raw isKindOfClass:NSDictionary.class]) return @{@"error":@"Impossible de vérifier la connexion Claude Code. Réessayez."};
    // Only keep public identity metadata from the official auth status command.
    NSMutableDictionary *result = [NSMutableDictionary dictionary];
    result[@"connected"] = @(status == 0 && [raw[@"loggedIn"] isEqual:@YES] && [raw[@"authMethod"] isEqual:@"claude.ai"]);
    for (NSString *key in @[@"email", @"orgId", @"subscriptionType"]) {
        result[key] = [raw[key] isKindOfClass:NSString.class] ? raw[key] : @"";
    }
    return result;
}
NSArray *TMClaudeBridgeWindows(id rates, NSTimeInterval now) {
    if (![rates isKindOfClass:NSDictionary.class]) return @[];
    NSMutableArray *windows = [NSMutableArray array];
    for (NSString *key in @[@"five_hour", @"seven_day"]) {
        id rate = rates[key];
        if (![rate isKindOfClass:NSDictionary.class]) continue;
        id used = rate[@"used_percentage"], reset = rate[@"resets_at"];
        if (![used isKindOfClass:NSNumber.class] || ![reset isKindOfClass:NSNumber.class] ||
            CFGetTypeID((__bridge CFTypeRef)used) == CFBooleanGetTypeID() ||
            CFGetTypeID((__bridge CFTypeRef)reset) == CFBooleanGetTypeID()) continue;
        double percent = [used doubleValue], timestamp = [reset doubleValue];
        if (!isfinite(percent) || percent < 0 || percent > 100 || !isfinite(timestamp) || timestamp <= now) continue;
        [windows addObject:@{@"windowId":key, @"label":TMClaudeWindowLabel(key),
                            @"usedPercent":@(percent), @"remainingPercent":@(100 - percent), @"resetsAt":@(timestamp)}];
    }
    return windows;
}
BOOL TMPrepareClaudeProfile(NSString *accountId, NSString *helper, NSString **commandPath, NSError **error) {
    NSString *profile = TMClaudeProfilePath(accountId), *claude = TMClaudeExecutable();
    if (!profile || !claude || ![NSFileManager.defaultManager isExecutableFileAtPath:helper]) return NO;
    NSFileManager *fm = NSFileManager.defaultManager;
    if (![fm createDirectoryAtPath:profile withIntermediateDirectories:YES attributes:@{NSFilePosixPermissions:@0700} error:error]) return NO;
    [fm setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:profile error:nil];
    NSString *settingsPath = [profile stringByAppendingPathComponent:@"settings.json"];
    // This is a Status-owned profile. Preserve unrelated settings, fail closed on malformed JSON.
    NSDictionary *existing = TMReadBridgeJSON(settingsPath);
    if ([fm fileExistsAtPath:settingsPath] && !existing.count) return NO;
    NSString *generation = NSUUID.UUID.UUIDString;
    NSString *collector = [NSString stringWithFormat:@"%@ %@ %@", TMShellQuote(helper), TMShellQuote(accountId), TMShellQuote(generation)];
    NSMutableDictionary *settings = [existing mutableCopy];
    settings[@"statusLine"] = @{@"type":@"command", @"command":collector};
    settings[@"forceLoginMethod"] = @"claudeai";
    if (!TMWriteBridgeJSON(settings, settingsPath, error)) return NO;
    if (!TMWriteBridgeJSON(@{@"accountId":accountId, @"generation":generation}, [profile stringByAppendingPathComponent:@"bridge.json"], error)) return NO;
    [fm removeItemAtPath:[profile stringByAppendingPathComponent:@"quota-snapshot.json"] error:nil];
    // No AppleScript, credential capture, prompt or paid model call. Terminal runs official login.
    NSMutableString *prefix = [NSMutableString stringWithString:@"/usr/bin/env -i"];
    NSDictionary *env = TMClaudeEnvironment(profile);
    for (NSString *key in [[env allKeys] sortedArrayUsingSelector:@selector(compare:)])
        [prefix appendFormat:@" %@", TMShellQuote([NSString stringWithFormat:@"%@=%@", key, env[key]])];
    [prefix appendFormat:@" %@", TMShellQuote(claude)];
    NSString *script = [NSString stringWithFormat:
        @"#!/bin/zsh\nset -e\numask 077\ncd %@\necho 'Connexion officielle Claude Code pour ce compte Status.'\n%@ auth login\necho 'Connexion terminée. Les quotas apparaîtront après votre première réponse Claude Code.'\necho 'Cette fenêtre utilise uniquement le profil de ce compte.'\n%@\n", TMShellQuote(profile), prefix, prefix];
    *commandPath = [profile stringByAppendingPathComponent:@"Connexion Claude.command"];
    if (![script writeToFile:*commandPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    if (![fm setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:*commandPath error:error]) return NO;
    NSString *sessionScript = [NSString stringWithFormat:@"#!/bin/zsh\nset -e\numask 077\ncd %@\nexec %@\n", TMShellQuote(profile), prefix];
    NSString *sessionPath = [profile stringByAppendingPathComponent:@"Ouvrir Claude.command"];
    if (![sessionScript writeToFile:sessionPath atomically:YES encoding:NSUTF8StringEncoding error:error]) return NO;
    return [fm setAttributes:@{NSFilePosixPermissions:@0700} ofItemAtPath:sessionPath error:error];
}
int TMCollectClaudeQuota(NSString *accountId, NSString *generation, NSData *input) {
    NSString *profile = TMClaudeProfilePath(accountId);
    if (!profile || input.length > 1024 * 1024) return 1;
    NSString *markerPath = [profile stringByAppendingPathComponent:@"bridge.json"];
    NSDictionary *marker = TMReadBridgeJSON(markerPath);
    if (![marker[@"generation"] isEqual:generation]) return 1;
    id raw = [NSJSONSerialization JSONObjectWithData:input options:0 error:nil];
    if (![raw isKindOfClass:NSDictionary.class] || ![raw[@"rate_limits"] isKindOfClass:NSDictionary.class]) return 0;
    NSDictionary *auth = TMClaudeAuthStatus(profile);
    if (![auth[@"connected"] boolValue] || ![auth[@"email"] length]) return 1;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    NSArray *windows = TMClaudeBridgeWindows(raw[@"rate_limits"], now);
    NSMutableDictionary *rates = [NSMutableDictionary dictionary];
    for (NSDictionary *window in windows) rates[window[@"windowId"]] = @{@"used_percentage":window[@"usedPercent"], @"resets_at":window[@"resetsAt"]};
    // Recheck after the child exits: disconnect/reconnect invalidates in-flight collectors.
    if (![TMReadBridgeJSON(markerPath)[@"generation"] isEqual:generation]) return 1;
    NSDictionary *snapshot = @{@"accountId":accountId, @"generation":generation, @"capturedAt":@(now),
                              @"email":auth[@"email"], @"orgId":auth[@"orgId"], @"rate_limits":rates};
    return TMWriteBridgeJSON(snapshot, [profile stringByAppendingPathComponent:@"quota-snapshot.json"], nil) ? 0 : 1;
}
NSDictionary *TMClaudeBridgePayload(NSString *accountId) {
    NSString *profile = TMClaudeProfilePath(accountId);
    NSMutableDictionary *out = [@{@"source":@"claude_code_statusline", @"connected":@NO, @"windows":@[],
        @"capturedAt":@0, @"stale":@NO, @"liveSource":@NO, @"error":@""} mutableCopy];
    if (!profile) return out;
    if (!TMClaudeExecutable()) { out[@"error"] = @"Installez Claude Code pour connecter ce compte."; return out; }
    if (![NSFileManager.defaultManager fileExistsAtPath:[profile stringByAppendingPathComponent:@"bridge.json"]]) return out;
    NSDictionary *auth = TMClaudeAuthStatus(profile);
    [out addEntriesFromDictionary:auth];
    if (![auth[@"connected"] boolValue]) return out;
    NSDictionary *snapshot = TMReadBridgeJSON([profile stringByAppendingPathComponent:@"quota-snapshot.json"]);
    NSDictionary *marker = TMReadBridgeJSON([profile stringByAppendingPathComponent:@"bridge.json"]);
    if (![snapshot[@"accountId"] isEqual:accountId] || ![snapshot[@"generation"] isEqual:marker[@"generation"]] ||
        ![snapshot[@"email"] isEqual:auth[@"email"]] || ![snapshot[@"orgId"] isEqual:auth[@"orgId"]]) return out;
    NSTimeInterval now = NSDate.date.timeIntervalSince1970;
    id timestamp = snapshot[@"capturedAt"];
    if (![timestamp isKindOfClass:NSNumber.class]) return out;
    double captured = [timestamp doubleValue];
    if (!isfinite(captured) || captured <= 0 || captured > now + 5) return out;
    out[@"windows"] = TMClaudeBridgeWindows(snapshot[@"rate_limits"], now);
    out[@"capturedAt"] = timestamp;
    out[@"stale"] = @(now - captured > 1800);
    return out;
}
BOOL TMLogoutClaudeProfile(NSString *accountId) {
    NSString *profile = TMClaudeProfilePath(accountId);
    if (!profile) return NO;
    [NSFileManager.defaultManager removeItemAtPath:[profile stringByAppendingPathComponent:@"bridge.json"] error:nil];
    [NSFileManager.defaultManager removeItemAtPath:[profile stringByAppendingPathComponent:@"quota-snapshot.json"] error:nil];
    int status; TMClaudeAuth(profile, @"logout", &status);
    return status == 0;
}

void TMRecordClaudeBridgeHistory(NSString *accountId, NSDictionary *payload) {
    if (!TMIsAccountID(accountId) || ![payload[@"connected"] boolValue]) return;
    long long captured = [payload[@"capturedAt"] longLongValue];
    if (captured <= 0) return;
    NSArray *windows = payload[@"windows"];
    if (![windows isKindOfClass:NSArray.class] || !windows.count) return;
    NSMutableDictionary *points = [NSMutableDictionary dictionary];
    NSArray *history = TMLoadHistory();
    for (NSDictionary *window in windows) {
        NSString *key = TMHistoryKey(TMProviderClaude, accountId, window[@"windowId"]);
        BOOL seen = NO;
        for (NSDictionary *row in history) {
            if ([row[@"t"] longLongValue] >= captured && row[@"p"][key]) { seen = YES; break; }
        }
        if (!seen) points[key] = @((long)([window[@"usedPercent"] doubleValue] + .5));
    }
    if (!points.count) return;
    NSMutableArray *rows = [history mutableCopy];
    [rows addObject:@{@"t":@(captured), @"p":points}];
    [rows sortUsingComparator:^NSComparisonResult(NSDictionary *a, NSDictionary *b) { return [a[@"t"] compare:b[@"t"]]; }];
    while (rows.count > 2000) [rows removeObjectAtIndex:0];
    NSData *data = [NSJSONSerialization dataWithJSONObject:rows options:0 error:nil];
    [data writeToFile:TMHistoryPath() atomically:YES];
}
