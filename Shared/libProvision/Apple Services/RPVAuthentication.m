//
//  RPVAuthentication.m
//  iOS
//
//  Created by Matt Clarke on 11/11/2019.
//  Copyright © 2019 Matt Clarke. All rights reserved.
//

#import "RPVAuthentication.h"
#import "AuthKit.h"
#include "RPVLoginImpl.h"
#include "RPVLoginFallbackImpl.h"
#import "RPVRemoteAnisetteProvider.h"
#import <TargetConditionals.h>

@interface RPVAuthentication ()

@property (nonatomic, strong) AKAppleIDSession* appleIDSession;
@property (nonatomic, strong) RPVLoginImpl *loginImpl;
@property (nonatomic, strong) RPVLoginFallbackImpl *fallbackImpl;
@property (nonatomic, strong) RPVRemoteAnisetteProvider *remoteAnisetteProvider;

@property (nonatomic, strong) NSString *cachedIdmsTokenFor2FA;
@property (nonatomic, strong) NSString *cachedUserIdentityFor2FA;
@property (nonatomic, strong) NSString *cachedUserPasswordFor2FA;
@property (nonatomic, readwrite) int requested2FAMode;

@end

@implementation RPVAuthentication

// iOS 17+ gets anisette from a server, unless the user chose the device's own
// AuthKit anisette in settings.
- (BOOL)_usesRemoteAnisette {
#if TARGET_OS_SIMULATOR
    return NO;
#else
    NSOperatingSystemVersion remoteAnisetteVersion = {17, 0, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:remoteAnisetteVersion] &&
           ![RPVRemoteAnisetteProvider usesDeviceAnisette];
#endif
}

- (void)_clearTwoFactorSession {
    self.cachedUserIdentityFor2FA = nil;
    self.cachedIdmsTokenFor2FA = nil;
    self.cachedUserPasswordFor2FA = nil;
    self.requested2FAMode = 0;
}

- (void)_authenticateWithUsername:(NSString *)username
                         password:(NSString *)password
            allowIdentityRecovery:(BOOL)allowIdentityRecovery
                   withCompletion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion {

#if !TARGET_OS_SIMULATOR
    if ([self _usesRemoteAnisette]) {
        if (allowIdentityRecovery) {
            // A user-initiated login may replace stale ADI state before GrandSlam.
            [self _clearTwoFactorSession];
            self.remoteAnisetteProvider.identityPinned = NO;
        }

        [self prepareAnisetteWithCompletion:^(NSError *anisetteError) {
            if (anisetteError) {
                completion(anisetteError, nil, nil);
                return;
            }

            // Keep one ADI identity for login, 2FA, token issuance, and portal calls.
            self.remoteAnisetteProvider.identityPinned = YES;

            dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self.loginImpl loginWithUsername:[username lowercaseString]
                                         password:password
                                       completion:^(NSError *error, NSString *userIdentity, NSString *gsToken, NSString *idmsToken) {
                    if (allowIdentityRecovery &&
                        (error.code == RPVInternalLogin2FARequiredSecondaryAuthError ||
                         error.code == RPVInternalLogin2FARequiredTrustedDeviceError)) {
                        self.cachedIdmsTokenFor2FA = idmsToken;
                        self.cachedUserIdentityFor2FA = userIdentity;
                        self.cachedUserPasswordFor2FA = password;
                        self.requested2FAMode = (int)error.code;
                    }
                    completion(error, userIdentity, gsToken);
                }];
            });
        }];
        return;
    }
#endif

    // Device anisette: drop anything left over from a previous remote server.
    [self.loginImpl clearRemoteAnisetteOverrides];

    // Use fallback impl on iOS 9 only, due to missing corecrypto functionality
    NSOperatingSystemVersion version = {10, 0, 0};
    if (![[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version]) {
        [self.fallbackImpl loginWithUsername:username password:password completion:completion];
        return;
    }

    if (allowIdentityRecovery) {
        [self _clearTwoFactorSession];
    }

    dispatch_async(dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
        [self.loginImpl loginWithUsername:[username lowercaseString]
                                 password:password
                               completion:^(NSError *error, NSString *userIdentity, NSString *gsToken, NSString *idmsToken) {
            if (allowIdentityRecovery &&
                (error.code == RPVInternalLogin2FARequiredSecondaryAuthError ||
                 error.code == RPVInternalLogin2FARequiredTrustedDeviceError)) {
                self.cachedIdmsTokenFor2FA = idmsToken;
                self.cachedUserIdentityFor2FA = userIdentity;
                self.cachedUserPasswordFor2FA = password;
                self.requested2FAMode = (int)error.code;
            }
            completion(error, userIdentity, gsToken);
        }];
    });
}

- (instancetype)init {
    self = [super init];

    if (self) {
        self.loginImpl = [[RPVLoginImpl alloc] init];
        self.fallbackImpl = [[RPVLoginFallbackImpl alloc] initWithClientInfoOverride:self.loginImpl.clientInfoOverride];
        self.remoteAnisetteProvider = [[RPVRemoteAnisetteProvider alloc] init];

        RPVRemoteAnisetteProvider *provider = self.remoteAnisetteProvider;
        self.loginImpl.anisetteResyncHandler = ^(NSString *SIM, void (^completion)(NSDictionary *, NSError *)) {
            [provider resyncAnisetteDataWithSIM:SIM completion:completion];
        };
    }

    return self;
}

- (void)authenticateWithUsername:(NSString*)username password:(NSString*)password withCompletion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion {
    [self _authenticateWithUsername:username
                           password:password
              allowIdentityRecovery:YES
                     withCompletion:completion];
}

- (void)prepareAnisetteWithCompletion:(void(^)(NSError *error))completion {
#if !TARGET_OS_SIMULATOR
    if ([self _usesRemoteAnisette]) {
        [self.remoteAnisetteProvider fetchAnisetteDataWithCompletion:^(NSDictionary<NSString *,NSString *> *headers, NSError *error) {
            if (headers.count > 0 && !error) {
                [self.loginImpl applyRemoteAnisetteHeaders:headers
                                                 userAgent:self.remoteAnisetteProvider.userAgent];
            }
            completion(error);
        }];
        return;
    }
#endif
    // Device anisette: drop anything left over from a previous remote server.
    [self.loginImpl clearRemoteAnisetteOverrides];
    completion(nil);
}

- (void)requestLoginCodeWithCompletion:(void(^)(NSError*))completionHandler {
    [self prepareAnisetteWithCompletion:^(NSError *anisetteError) {
        if (anisetteError) {
            completionHandler(anisetteError);
            return;
        }

        [self.loginImpl requestTwoFactorCodeWithUserIdentity:self.cachedUserIdentityFor2FA
                                                   idmsToken:self.cachedIdmsTokenFor2FA
                                                        mode:self.requested2FAMode
                                               andCompletion:completionHandler];
    }];
}

- (BOOL)hasActiveTwoFactorSession {
    return self.cachedUserIdentityFor2FA.length > 0 &&
           self.cachedIdmsTokenFor2FA.length > 0 &&
           self.cachedUserPasswordFor2FA.length > 0 &&
           (self.requested2FAMode == RPVInternalLogin2FARequiredSecondaryAuthError ||
            self.requested2FAMode == RPVInternalLogin2FARequiredTrustedDeviceError);
}

- (void)_finishTwoFactorLoginWithUsername:(NSString *)username
                                  password:(NSString *)password
                          remainingRetries:(NSUInteger)remainingRetries
                                completion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion {
    [self _authenticateWithUsername:username
                           password:password
              allowIdentityRecovery:NO
                     withCompletion:^(NSError *error, NSString *userIdentity, NSString *gsToken) {
        BOOL hasCompleteCredentials = error == nil && userIdentity.length > 0 && gsToken.length > 0;
        if (hasCompleteCredentials) {
            [self _clearTwoFactorSession];
            completion(nil, userIdentity, gsToken);
            return;
        }

        // Trusted state can lag behind code acceptance, so retry the follow-up login.
        if (remainingRetries > 0) {
            NSTimeInterval delay = remainingRetries == 2 ? 0.75 : 1.5;
            dispatch_after(dispatch_time(DISPATCH_TIME_NOW, (int64_t)(delay * NSEC_PER_SEC)),
                           dispatch_get_global_queue(DISPATCH_QUEUE_PRIORITY_DEFAULT, 0), ^{
                [self _finishTwoFactorLoginWithUsername:username
                                               password:password
                                       remainingRetries:remainingRetries - 1
                                             completion:completion];
            });
            return;
        }

        // The accepted IDMS context cannot be reused.
        [self _clearTwoFactorSession];
        NSMutableDictionary *userInfo = [@{
            NSLocalizedDescriptionKey: @"Apple accepted the verification code, but did not finish creating the trusted login session. Please go back and sign in again."
        } mutableCopy];
        if (error) {
            userInfo[NSUnderlyingErrorKey] = error;
        }
        NSError *finalError = [NSError errorWithDomain:NSCocoaErrorDomain
                                                   code:RPVInternalLoginPostTwoFactorError
                                               userInfo:userInfo];
        completion(finalError, nil, nil);
    }];
}

- (void)validateLoginCode:(NSString*)code withCompletion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion {
    if (![self hasActiveTwoFactorSession]) {
        NSError *error = [NSError errorWithDomain:NSCocoaErrorDomain
                                             code:RPVInternalLoginError
                                         userInfo:@{NSLocalizedDescriptionKey: @"The Apple authentication session is incomplete. Please go back and sign in again."}];
        completion(error, nil, nil);
        return;
    }

    [self prepareAnisetteWithCompletion:^(NSError *anisetteError) {
        if (anisetteError) {
            completion(anisetteError, nil, nil);
            return;
        }

        // Refresh one-time anisette headers before validating the code.
        [self.loginImpl submitTwoFactorCode:code
                           withUserIdentity:self.cachedUserIdentityFor2FA
                                  idmsToken:self.cachedIdmsTokenFor2FA
                                       mode:self.requested2FAMode
                              andCompletion:^(NSError *error) {
            if (error) {
                completion(error, nil, nil);
            } else {
                // The verification context is consumed; finish with a bounded login retry.
                NSString *username = [self.cachedUserIdentityFor2FA componentsSeparatedByString:@"|"].lastObject;
                NSString *password = [self.cachedUserPasswordFor2FA copy];
                [self _finishTwoFactorLoginWithUsername:username
                                               password:password
                                       remainingRetries:2
                                             completion:completion];
            }
        }];
    }];
}

- (void)fallback2FACodeRequest:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completionHandler {

    NSString *username = [self.cachedUserIdentityFor2FA componentsSeparatedByString:@"|"].lastObject;
    
    [self.fallbackImpl loginWithUsername:username password:self.cachedUserPasswordFor2FA completion:^(NSError *error, NSString *userIdentity, NSString *gsToken) {
        if (!error) {
            // Do real login again now that 2FA is dealt with
            [self authenticateWithUsername:username password:self.cachedUserPasswordFor2FA withCompletion:completionHandler];
        } else {
            completionHandler(error, nil, nil);
        }
    }];
}

- (NSDictionary*)appleIDHeadersForRequest:(NSURLRequest*)request {
    if (self.loginImpl.anisetteDataOverride.count > 0) {
        NSMutableDictionary *remoteHeaders = [self.loginImpl.anisetteDataOverride mutableCopy];
        remoteHeaders[@"X-Apple-App-Info"] = @"com.apple.gs.xcode.auth";
        remoteHeaders[@"X-MMe-Client-Info"] = self.loginImpl.clientInfoOverride;
        return remoteHeaders;
    }

    if (!self.appleIDSession){
        self.appleIDSession = [[AKAppleIDSession alloc] initWithIdentifier:@"com.apple.gs.xcode.auth"];
    }

    NSMutableDictionary *result = nil;

#if !TARGET_OS_SIMULATOR
    NSOperatingSystemVersion legacyAnisetteVersion = {17, 0, 0};
    if ([[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:legacyAnisetteVersion]) {
        // Build the legacy anisette set from AuthKit's native controller.
        NSError *anisetteError = nil;
        AKAnisetteProvisioningController *controller = [self.appleIDSession _nativeAnisetteController];
        id anisetteData = [controller anisetteDataWithError:&anisetteError];
        NSDictionary *anisetteHeaders = anisetteData ? [NSMutableURLRequest ak_anisetteHeadersWithData:anisetteData] : nil;

        if (!anisetteError && anisetteHeaders.count > 0) {
            result = [[self.appleIDSession _genericAppleIDHeadersDictionaryForRequest:request] mutableCopy];
            if (!result) {
                result = [NSMutableDictionary dictionary];
            }
            [result addEntriesFromDictionary:anisetteHeaders];
        }
    }
#endif

    // Fall back to the original implementation when native generation is unavailable.
    if (!result) {
        result = [[self.appleIDSession appleIDHeadersForRequest:request] mutableCopy];
    }
    if (!result) {
        result = [NSMutableDictionary dictionary];
    }
    
    // Override some auth parameters
    [result setObject:@"com.apple.gs.xcode.auth" forKey:@"X-Apple-App-Info"];
    [result setObject:self.loginImpl.clientInfoOverride forKey:@"X-MMe-Client-Info"];
    
    return result;
}

@end
