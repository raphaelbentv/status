#import "StatusLidProtocol.h"
#import <Security/Security.h>
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
