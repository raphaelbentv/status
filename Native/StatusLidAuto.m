#import "StatusLidAuto.h"
#import <math.h>
#import <sys/stat.h>

const double TMLidAutoGraceSeconds = 5 * 60, TMLidAutoCooldownSeconds = 10 * 60;
const NSInteger TMLidAutoChunkMinutes = 30, TMLidAutoCapMinutes = 240;
// Un tour peut attendre longtemps un outil (compilation, tests) sans rien écrire ; au-delà, on le croit abandonné.
static const double TMClaudeTurnMaxAge = 45 * 60, TMClaudeUnknownMaxAge = 120;
static const NSUInteger TMClaudeTailBytes = 256 * 1024;

TMClaudeTurn TMClaudeTranscriptTurn(NSData *tail, double *timestamp) {
    const char *bytes = tail.bytes;
    NSUInteger end = tail.length;
    while (end > 0) {
        NSUInteger start = end;
        while (start > 0 && bytes[start - 1] != '\n') start--;
        NSData *line = [tail subdataWithRange:NSMakeRange(start, end - start)];
        end = start ? start - 1 : 0;
        if (!line.length) continue;
        // La première ligne peut être tronquée par la lecture partielle : illisible, elle est ignorée.
        NSDictionary *d = [NSJSONSerialization JSONObjectWithData:line options:0 error:nil];
        if (![d isKindOfClass:NSDictionary.class] || [d[@"isSidechain"] isEqual:@YES] || [d[@"isMeta"] isEqual:@YES]) continue;
        NSDictionary *message = d[@"message"];
        BOOL assistant = [d[@"type"] isEqual:@"assistant"];
        if ((!assistant && ![d[@"type"] isEqual:@"user"]) || ![message isKindOfClass:NSDictionary.class]) continue;
        if (timestamp && [d[@"timestamp"] isKindOfClass:NSString.class]) {
            NSISO8601DateFormatter *format = [NSISO8601DateFormatter new];
            format.formatOptions = NSISO8601DateFormatWithInternetDateTime | NSISO8601DateFormatWithFractionalSeconds;
            NSDate *date = [format dateFromString:d[@"timestamp"]];
            if (date) *timestamp = date.timeIntervalSince1970;
        }
        // Réponse terminée : end_turn, stop_sequence, max_tokens… Sans raison d'arrêt, elle est encore en cours.
        if (assistant) {
            id stop = message[@"stop_reason"];
            return [stop isKindOfClass:NSString.class] && ![@[@"tool_use", @"pause_turn"] containsObject:stop]
                ? TMClaudeTurnIdle : TMClaudeTurnWorking;
        }
        id content = message[@"content"];
        NSString *text = [content isKindOfClass:NSString.class] ? content : nil;
        if ([content isKindOfClass:NSArray.class])
            for (NSDictionary *part in content)
                if ([part isKindOfClass:NSDictionary.class] && [part[@"type"] isEqual:@"text"] && [part[@"text"] isKindOfClass:NSString.class]) {
                    text = part[@"text"]; break;
                }
        // Interruption ou commande locale (/model, /clear…) : aucune réponse ne suit.
        for (NSString *prefix in @[@"[Request interrupted by user", @"<command-name>", @"<local-command-"])
            if ([text hasPrefix:prefix]) return TMClaudeTurnIdle;
        return TMClaudeTurnWorking;  // invite envoyée ou résultat d'outil : le modèle répond
    }
    return TMClaudeTurnUnknown;
}

BOOL TMClaudeCodeWorking(NSArray<NSString *> *roots, double now) {
    NSFileManager *fm = NSFileManager.defaultManager;
    for (NSString *root in roots)
        for (NSString *project in [fm contentsOfDirectoryAtPath:root error:nil]) {
            NSString *dir = [root stringByAppendingPathComponent:project];
            for (NSString *name in [fm contentsOfDirectoryAtPath:dir error:nil]) {
                if (![name.pathExtension isEqual:@"jsonl"]) continue;
                NSString *path = [dir stringByAppendingPathComponent:name];
                struct stat st;
                if (stat(path.fileSystemRepresentation, &st) != 0 || !S_ISREG(st.st_mode)) continue;
                double modified = st.st_mtimespec.tv_sec + st.st_mtimespec.tv_nsec / 1e9;
                if (now - modified > TMClaudeTurnMaxAge) continue;
                NSFileHandle *file = [NSFileHandle fileHandleForReadingAtPath:path];
                unsigned long long size = (unsigned long long)st.st_size;
                if (!file || ![file seekToOffset:size > TMClaudeTailBytes ? size - TMClaudeTailBytes : 0 error:nil]) continue;
                NSData *tail = [file readDataUpToLength:TMClaudeTailBytes error:nil];
                [file closeAndReturnError:nil];
                double at = modified;
                TMClaudeTurn turn = TMClaudeTranscriptTurn(tail, &at);
                if (turn == TMClaudeTurnWorking && now - at <= TMClaudeTurnMaxAge && at - now < 300) return YES;
                // Format inattendu : seule une écriture toute récente compte comme du travail.
                if (turn == TMClaudeTurnUnknown && now - modified <= TMClaudeUnknownMaxAge) return YES;
            }
        }
    return NO;
}

@implementation TMLidAutoPilot {
    BOOL _starting, _stopping, _userStop, _suppressed, _wasActive, _working, _legacy;
    double _lastWork, _episodeStart, _cooldownUntil, _lastExtend;
    NSInteger _strikes;
    NSString *_state;
}
- (double)capLeft:(double)now {
    return (_episodeStart ? _episodeStart - now : 0) + TMLidAutoCapMinutes * 60;
}
// Arrêt de sécurité ou démarrage refusé : délai avant tout nouvel essai, et pause après trois échecs.
- (void)failedAt:(double)now {
    _cooldownUntil = now + TMLidAutoCooldownSeconds;
    if (++_strikes >= 3) _suppressed = YES;
}
- (void)userStopped { _userStop = YES; }
// L'app ne consulte plus le pilote une fois l'option coupée : à la réactivation, oublier la session vue alors.
- (void)setEnabled:(BOOL)enabled {
    if (enabled && !_enabled && !_owns) _wasActive = NO;
    _enabled = enabled;
}
- (TMLidAutoCommand)decideWithService:(NSDictionary *)lid working:(BOOL)working
                                  now:(double)now minutes:(NSInteger *)minutes {
    *minutes = 0;
    _working = working;
    if (working) _lastWork = now;
    if ([lid[@"busy"] boolValue]) return TMLidAutoNone;  // réponse du service attendue
    BOOL active = [lid[@"active"] boolValue] && ![lid[@"unconfirmed"] boolValue];
    BOOL idle = !working && (!_lastWork || now - _lastWork >= TMLidAutoGraceSeconds);
    // Démarrage demandé : on attend une réponse confirmée pour savoir si la session est la nôtre.
    if (_starting && ![lid[@"unconfirmed"] boolValue]) {
        _starting = NO;
        if (active) _owns = YES; else [self failedAt:now];
    }
    if (_wasActive && !active && ![lid[@"unconfirmed"] boolValue]) {
        if (_stopping) {}
        else if (_userStop) _suppressed = YES;
        else if ([lid[@"message"] isEqual:@"Durée terminée."]) { if (_owns && [self capLeft:now] < 60) _suppressed = YES; }
        else [self failedAt:now];
        _owns = NO; _stopping = NO;
    }
    if (!active) _userStop = NO;
    if (![lid[@"unconfirmed"] boolValue]) _wasActive = active;
    _legacy = ![lid[@"extendSupported"] boolValue];
    // Fin de l'épisode de travail : les pauses et le plafond repartent de zéro.
    if (idle && !(_owns && active)) { _suppressed = NO; _strikes = 0; _episodeStart = 0; }

    if (!_enabled) {
        _state = @"off";
        if (_owns && active) { _stopping = YES; return TMLidAutoStop; }
        return TMLidAutoNone;
    }
    if (active && !_owns) { _state = @"manual"; return TMLidAutoNone; }  // lancée à la main : jamais touchée
    if (active) {
        if (idle) { _stopping = YES; _state = @"idle"; return TMLidAutoStop; }
        _state = working ? @"running" : @"stopping";
        double remaining = [lid[@"remainingSeconds"] doubleValue], want = MIN(TMLidAutoChunkMinutes * 60, [self capLeft:now]);
        if (working && !_legacy && ![lid[@"constant"] boolValue] && remaining < 600 && want > remaining + 60 && now - _lastExtend >= 60) {
            _lastExtend = now; *minutes = (NSInteger)floor(want / 60);
            return TMLidAutoExtend;
        }
        return TMLidAutoNone;
    }
    if ([lid[@"unconfirmed"] boolValue] || [lid[@"restorationPending"] boolValue] || ![lid[@"authorized"] boolValue] ||
        ![lid[@"controlVersion"] isEqual:@4]) { _state = @"unavailable"; return TMLidAutoNone; }
    if (!working) { _state = @"idle"; return TMLidAutoNone; }
    if (_suppressed) { _state = @"paused"; return TMLidAutoNone; }
    if (now < _cooldownUntil) { _state = @"cooldown"; return TMLidAutoNone; }
    // Causes d'arrêt encore présentes : marge de 5 points au-dessus du seuil batterie du service.
    double battery = [lid[@"batteryPercent"] isKindOfClass:NSNumber.class] ? [lid[@"batteryPercent"] doubleValue] : NAN;
    NSInteger thermal = [lid[@"thermalState"] integerValue];
    BOOL hot = [lid[@"fanlessMac"] boolValue] ? thermal >= NSProcessInfoThermalStateCritical : thermal != NSProcessInfoThermalStateNominal;
    if (!isfinite(battery) || battery < 35 || battery > 100 || hot) { _state = @"waiting"; return TMLidAutoNone; }
    double capLeft = [self capLeft:now];
    if (capLeft < 60) { _suppressed = YES; _state = @"paused"; return TMLidAutoNone; }
    if (!_episodeStart) _episodeStart = now;
    *minutes = (NSInteger)MIN(_legacy ? TMLidAutoCapMinutes : TMLidAutoChunkMinutes, floor(capLeft / 60));
    _starting = YES; _state = @"starting";
    return TMLidAutoStart;
}
- (NSDictionary *)snapshot:(double)now {
    return @{@"enabled":@(_enabled), @"state":_enabled ? (_state ?: @"idle") : @"off", @"working":@(_working),
             @"legacy":@(_legacy), @"stopInSeconds":@(MAX(0, _lastWork + TMLidAutoGraceSeconds - now)),
             @"cooldownSeconds":@(MAX(0, _cooldownUntil - now))};
}
@end
