#import <Foundation/Foundation.h>

NS_ASSUME_NONNULL_BEGIN

/**
 Provides a persistent macOS ADI identity through the SideStore anisette v3
 protocol. The provider receives only ADI provisioning material and a random
 local UUID; Apple ID credentials and service tokens are never sent to it.
 */
@interface RPVRemoteAnisetteProvider : NSObject

/**
 Prevents automatic ADI reprovisioning while an Apple authentication session
 or GS token is using the current machine identity. A fresh manual sign-in may
 unpin the identity before GrandSlam begins.
 */
@property (nonatomic, assign, getter=isIdentityPinned) BOOL identityPinned;

/**
 User-Agent the anisette server pairs with its client info. GrandSlam rejects
 logins (-80045) when these do not match the identity the server emulates.
 */
@property (nonatomic, copy, readonly, nullable) NSString *userAgent;

- (void)fetchAnisetteDataWithCompletion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                                   NSError * _Nullable error))completion;

/**
 Regenerates headers for the current identity after GrandSlam asks for an
 anisette resync (hsc 434), passing back the X-Apple-I-MD-DATA it returned.
 */
- (void)resyncAnisetteDataWithSIM:(NSString *)SIM
                       completion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                            NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
