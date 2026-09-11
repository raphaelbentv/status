#import "StatusClaudeBridge.h"
int main(int argc, const char *argv[]) {
    @autoreleasepool {
        if (argc != 3) return 1;
        NSData *input = [NSFileHandle.fileHandleWithStandardInput readDataToEndOfFile];
        return TMCollectClaudeQuota(@(argv[1]), @(argv[2]), input);
    }
}
