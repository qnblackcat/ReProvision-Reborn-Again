//
//  RPVAuthentication.h
//  iOS
//
//  Created by Matt Clarke on 11/11/2019.
//  Copyright © 2019 Matt Clarke. All rights reserved.
//

#import <Foundation/Foundation.h>

@interface RPVAuthentication : NSObject

/**
 * Authenticates against gsa.apple.com with the given username and password
 */
- (void)authenticateWithUsername:(NSString*)username password:(NSString*)password withCompletion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion;

/**
 Validates a login code for the current authentication context
 */
- (void)validateLoginCode:(NSString*)code withCompletion:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completion;

/**
 Requests a login code for the current authentication content
 */
- (void)requestLoginCodeWithCompletion:(void(^)(NSError*))completionHandler;

/**
 Returns whether the current one-time 2FA context can still request or submit
 a verification code.
 */
- (BOOL)hasActiveTwoFactorSession;

/**
 Requests a login code via direct AuthKit calls
 */
- (void)fallback2FACodeRequest:(void(^)(NSError *error, NSString *userIdentity, NSString *gsToken))completionHandler;

- (NSDictionary*)appleIDHeadersForRequest:(NSURLRequest*)request;

/**
 Fetches a fresh OTP for the persistent macOS ADI identity used on iOS 17+.
 */
- (void)prepareAnisetteWithCompletion:(void(^)(NSError *error))completion;

@end
