#import "StatusLidProtocol.h"
#import <Security/Security.h>
#import <sys/stat.h>
#import <CommonCrypto/CommonDigest.h>
NSString *TMLidPeerRequirement(NSString *identifier) {
    SecCodeRef code = NULL; CFDictionaryRef info = NULL;
    if (SecCodeCopySelf(kSecCSDefaultFlags, &code) != errSecSuccess) return nil;
    OSStatus result = SecCodeCopySigningInformation(code, kSecCSSigningInformation, &info);
    CFRelease(code);
    if (result != errSecSuccess || !info) return nil;
    NSDictionary *signing = CFBridgingRelease(info);
    NSArray *certs = signing[(__bridge NSString *)kSecCodeInfoCertificates];
    if (!certs.count) return nil;  // Signature ad hoc : aucune autorité à épingler, refus fermé.
    NSData *der = CFBridgingRelease(SecCertificateCopyData((__bridge SecCertificateRef)certs.firstObject));
    unsigned char digest[CC_SHA1_DIGEST_LENGTH];
    CC_SHA1(der.bytes, (CC_LONG)der.length, digest);
    NSMutableString *hex = [NSMutableString string];
    for (unsigned i=0; i<sizeof(digest); i++) [hex appendFormat:@"%02x", digest[i]];
    return [NSString stringWithFormat:@"identifier \"%@\" and certificate leaf = H\"%@\"", identifier, hex];
}

BOOL TMLidSigningReady(void) {
    static BOOL ready=NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSString *peer=TMLidPeerRequirement(TMLidHelperIdentifier);
        if (!peer) return;
        NSURL *app=NSBundle.mainBundle.bundleURL;
        NSURL *helper=[app URLByAppendingPathComponent:@"Contents/Library/LaunchServices/com.raphael.status.lid-helper"];
        NSArray *urls=@[app,helper];
        NSArray *requirements=@[@"anchor apple generic", [peer stringByAppendingString:@" and anchor apple generic"]];
        for (NSUInteger i=0;i<urls.count;i++) {
            SecStaticCodeRef code=NULL; SecRequirementRef requirement=NULL;
            OSStatus result=SecStaticCodeCreateWithPath((__bridge CFURLRef)urls[i],kSecCSDefaultFlags,&code);
            if (result!=errSecSuccess) return;
            result=SecRequirementCreateWithString((__bridge CFStringRef)requirements[i],kSecCSDefaultFlags,&requirement);
            if (result==errSecSuccess) result=SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement);
            if (requirement) CFRelease(requirement);
            CFRelease(code);
            if (result!=errSecSuccess) return;
        }
        ready=YES;
    });
    return ready;
}

static BOOL ValidCode(NSURL *url, NSString *required) {
    if (!required) return NO;
    SecStaticCodeRef code=NULL; SecRequirementRef requirement=NULL;
    OSStatus result=SecStaticCodeCreateWithPath((__bridge CFURLRef)url,kSecCSDefaultFlags,&code);
    if (result!=errSecSuccess) return NO;
    result=SecRequirementCreateWithString((__bridge CFStringRef)required,kSecCSDefaultFlags,&requirement);
    if (result==errSecSuccess) result=SecStaticCodeCheckValidity(code,kSecCSStrictValidate,requirement);
    if (requirement) CFRelease(requirement);
    CFRelease(code);
    return result==errSecSuccess;
}
BOOL TMLidInstallerReady(void) {
    static BOOL ready=NO;
    static dispatch_once_t once;
    dispatch_once(&once, ^{
        NSURL *app=NSBundle.mainBundle.bundleURL;
        NSURL *helper=[app URLByAppendingPathComponent:@"Contents/Library/LaunchServices/com.raphael.status.lid-helper"];
        NSURL *package=[app URLByAppendingPathComponent:@"Contents/Resources/StatusLidService.pkg"];
        ready=[[NSFileManager defaultManager] fileExistsAtPath:package.path] &&
            ValidCode(app,TMLidPeerRequirement(@"com.raphael.status")) &&
            ValidCode(helper,TMLidPeerRequirement(TMLidHelperIdentifier));
    });
    return ready;
}
BOOL TMLidInstalledServiceReady(void) {
    // Un binaire installé appartient à root. Ne jamais joindre un service substitué
    // par un utilisateur, même si le fichier final possède une signature valable.
    NSArray *paths=@[@"/Library", @"/Library/PrivilegedHelperTools",
        TMLidInstalledHelperPath, @"/Library/LaunchDaemons", TMLidInstalledPlistPath];
    for (NSString *path in paths) {
        struct stat st;
        if (lstat(path.fileSystemRepresentation,&st)!=0 || st.st_uid!=0 || (st.st_mode&0022)!=0 ||
            (!S_ISDIR(st.st_mode) && !S_ISREG(st.st_mode))) return NO;
    }
    return ValidCode([NSURL fileURLWithPath:paths[2]],TMLidPeerRequirement(TMLidHelperIdentifier));
}
