#import <Foundation/Foundation.h>

NSString *TMClaudeProfilePath(NSString *accountId);
NSString *TMClaudeExecutable(void);
NSString *TMShellQuote(NSString *value);
NSDictionary *TMClaudeAuthStatus(NSString *profile);
NSDictionary *TMClaudeBridgePayload(NSString *accountId);
NSArray *TMClaudeBridgeWindows(id rates, NSTimeInterval now);
BOOL TMPrepareClaudeProfile(NSString *accountId, NSString *helper, NSString **commandPath, NSError **error);
int TMCollectClaudeQuota(NSString *accountId, NSString *generation, NSData *input);
BOOL TMLogoutClaudeProfile(NSString *accountId);
void TMRecordClaudeBridgeHistory(NSString *accountId, NSDictionary *payload);
