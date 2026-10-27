//
//  RPVLoginImpl.hpp
//  iOS
//
//  Created by Matt Clarke on 24/11/2019.
//  Copyright © 2019 Matt Clarke. All rights reserved.
//

#import <Foundation/Foundation.h>

// Error definitions
#define RPVInternalLoginError 5000
#define RPVInternalLogin2FARequiredTrustedDeviceError 4010
#define RPVInternalLogin2FARequiredSecondaryAuthError 4011
#define RPVInternalLoginIncorrect2FACodeError 4012
#define RPVInternalLoginInvalid2FAFormatError 4013
#define RPVInternalLoginPostTwoFactorError 4014

// Block definitions
typedef void (^RPVLoginResultBlock)(NSError *error, NSString *userIdentity, NSString *gsToken, NSString *idmsToken);
typedef void (^RPVTwoFactorResultBlock)(NSError *error);
typedef void (^RPVAnisetteResyncHandler)(NSString *SIM, void (^completion)(NSDictionary *headers, NSError *error));

@interface RPVLoginImpl : NSObject

@property (nonatomic, strong) NSString *clientInfoOverride;
@property (nonatomic, strong) NSDictionary *anisetteDataOverride;
@property (nonatomic, copy) NSString *userAgentOverride;
// Regenerates remote anisette when GrandSlam asks for a resync (hsc 434).
@property (nonatomic, copy) RPVAnisetteResyncHandler anisetteResyncHandler;

// Uses the remote anisette identity exactly as the server describes it.
- (void)applyRemoteAnisetteHeaders:(NSDictionary *)headers userAgent:(NSString *)userAgent;

// Drops remote anisette state so requests use the device's own AuthKit data.
- (void)clearRemoteAnisetteOverrides;

- (void)loginWithUsername:(NSString*)username password:(NSString*)password completion:(RPVLoginResultBlock)completionHandler;

- (void)requestTwoFactorCodeWithUserIdentity:(NSString*)userIdentity idmsToken:(NSString*)token mode:(int)mode andCompletion:(void (^)(NSError *error))completionHandler;

- (void)submitTwoFactorCode:(NSString*)code
           withUserIdentity:(NSString*)userIdentity
                  idmsToken:(NSString*)token
                       mode:(int)mode
              andCompletion:(RPVTwoFactorResultBlock)completionHandler;

@end
