#import "StatusClaudeBridge.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc < 3) return 1;
        NSString *mode = @(argv[1]), *account = @(argv[2]);
        if ([mode isEqual:@"prepare"]) {
            NSString *path; NSError *error;
            return TMPrepareClaudeProfile(account, @(argv[0]), &path, &error) ? 0 : 1;
        }
        if ([mode isEqual:@"collect"] && argc == 4)
            return TMCollectClaudeQuota(account, @(argv[3]), [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile]);
        if ([mode isEqual:@"logout"]) return TMLogoutClaudeProfile(account) ? 0 : 1;
        if ([mode isEqual:@"record"]) { TMRecordClaudeBridgeHistory(account, TMClaudeBridgePayload(account)); return 0; }
        if ([mode isEqual:@"read"]) {
            NSData *data = [NSJSONSerialization dataWithJSONObject:TMClaudeBridgePayload(account) options:0 error:nil];
            [NSFileHandle.fileHandleWithStandardOutput writeData:data]; return 0;
        }
        return 1;
    }
}
