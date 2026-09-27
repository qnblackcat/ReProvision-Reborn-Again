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

- (void)fetchAnisetteDataWithCompletion:(void (^)(NSDictionary<NSString *, NSString *> * _Nullable headers,
                                                   NSError * _Nullable error))completion;

@end

NS_ASSUME_NONNULL_END
