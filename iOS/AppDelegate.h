//
//  AppDelegate.h
//  ReProvision
//
//  Created by Matt Clarke on 08/01/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import <UIKit/UIKit.h>
#import "RPVApplicationProtocol.h"
#import "RPVApplicationSigning.h"

@interface AppDelegate : UIResponder <UIApplicationDelegate, RPVApplicationSigningProtocol, RPVApplicationProtocol, NSURLSessionDelegate>

@property (strong, nonatomic) UIWindow *window;

- (void)requestDebuggingBackgroundSigning;
- (void)requestDebuggingBackgroundSigningWithCompletion:(void (^)(NSError *error))completionHandler;
- (void)requestPreferencesUpdate;

@end
