//
//  RPVAccount2FAViewController.m
//  iOS
//
//  Created by Matt Clarke on 07/03/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVAccount2FAViewController.h"
#import "RPVAccountTeamIDViewController.h"
#import "RPVAccountFinalController.h"
#import "RPVAccountChecker.h"

@interface RPVAccount2FAViewController ()

@property (nonatomic, strong) NSString *emailAddress;
@property (nonatomic, strong) NSArray *_interimTeamIDArray;
@property (nonatomic, strong) NSURLCredential *credentials;
@property (nonatomic, assign) BOOL requested2FACode;
@property (nonatomic, assign) BOOL authenticationInProgress;
@property (nonatomic, strong) UIButton *requestCodeButton;

@end

@implementation RPVAccount2FAViewController

- (void)viewDidLoad {
    [super viewDidLoad];

    // Rootless builds restore the missing 2FA field in code.
    if (!self.passwordTextField) {
        UITextField *codeTextField = [[UITextField alloc] initWithFrame:CGRectZero];
        codeTextField.translatesAutoresizingMaskIntoConstraints = NO;
        codeTextField.borderStyle = UITextBorderStyleRoundedRect;
        codeTextField.placeholder = @"6-digit verification code";
        codeTextField.keyboardType = UIKeyboardTypeNumberPad;
        codeTextField.textContentType = UITextContentTypeOneTimeCode;
        codeTextField.textAlignment = NSTextAlignmentCenter;
        codeTextField.font = [UIFont monospacedDigitSystemFontOfSize:24.0 weight:UIFontWeightRegular];
        codeTextField.accessibilityLabel = @"Apple verification code";

        [self.view addSubview:codeTextField];
        [NSLayoutConstraint activateConstraints:@[
            [codeTextField.topAnchor constraintEqualToAnchor:self.subtitleLabel.bottomAnchor constant:28.0],
            [codeTextField.leadingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.leadingAnchor constant:16.0],
            [codeTextField.trailingAnchor constraintEqualToAnchor:self.view.layoutMarginsGuide.trailingAnchor constant:-16.0],
            [codeTextField.heightAnchor constraintEqualToConstant:52.0],
        ]];
        self.passwordTextField = codeTextField;
    }

    for (UIView *subview in self.view.subviews) {
        if (![subview isKindOfClass:[UIButton class]]) {
            continue;
        }

        UIButton *button = (UIButton *)subview;
        if ([[button titleForState:UIControlStateNormal] isEqualToString:@"Continue Authentication"]) {
            self.requestCodeButton = button;
            [button setTitle:@"Send New Code" forState:UIControlStateNormal];
            break;
        }
    }

    [self.passwordTextField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    self.confirmBarButtonItem.enabled = NO;
    self.titleLabel.text = @"2-Factor Authentication";
    self.subtitleLabel.text = @"Apple will send a six-digit code using the verification method for this Apple ID. Enter the newest code below.";
    
    // Handle colour
    
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.titleLabel.textColor = [UIColor labelColor];
        self.subtitleLabel.textColor = [UIColor labelColor];
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
        self.titleLabel.textColor = [UIColor blackColor];
        self.subtitleLabel.textColor = [UIColor blackColor];
    }
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self.navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    [self.navigationController.navigationBar setShadowImage:[UIImage new]];
    
    if (!self.requested2FACode && !self.authenticationInProgress) {
        [self requestVerificationCode];
    }
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)presentTeamIDViewControllerIfNecessaryWithTeamIDs:(NSArray*)teamids credentials:(NSURLCredential*)credential {
    self._interimTeamIDArray = teamids;
    self.credentials = credential;
    if ([teamids count] == 1) {
        [self presentFinalController];
    } else {
        [self performSegueWithIdentifier:@"presentTeamIDController" sender:nil];
    }
}

- (void)presentFinalController {
    [self performSegueWithIdentifier:@"presentFinalController" sender:nil];
}

- (void)showNavigationSpinner {
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    spinner.hidesWhenStopped = YES;
    if (@available(iOS 13.0, *)) {
        spinner.color = [UIColor labelColor];
    }
    [spinner startAnimating];
    self.navigationItem.rightBarButtonItem = [[UIBarButtonItem alloc] initWithCustomView:spinner];
}

- (void)restoreNavigationButton {
    self.navigationItem.rightBarButtonItem = self.confirmBarButtonItem;
    [self textFieldDidChange:self.passwordTextField];
}

- (void)requestVerificationCode {
    if (self.authenticationInProgress) {
        return;
    }

    if (![[RPVAccountChecker sharedInstance] hasActiveTwoFactorSession]) {
        self.requestCodeButton.enabled = NO;
        [self changeUIToIncorrectStatus:@"This verification session has already finished. Go back and sign in again."];
        return;
    }

    self.authenticationInProgress = YES;
    // Clear the previous code before requesting a new challenge.
    self.passwordTextField.text = @"";
    self.requestCodeButton.enabled = NO;
    self.confirmBarButtonItem.enabled = NO;
    [self showNavigationSpinner];

    [[RPVAccountChecker sharedInstance] requestLoginCodeWithCompletionHandler:^(NSError *error) {
        dispatch_async(dispatch_get_main_queue(), ^{
            self.authenticationInProgress = NO;
            self.requestCodeButton.enabled = YES;
            [self restoreNavigationButton];

            if (error) {
                self.requested2FACode = NO;
                NSString *message = error.localizedDescription.length > 0
                    ? error.localizedDescription
                    : @"Could not request a verification code. Please try again.";
                [self changeUIToIncorrectStatus:message];
                return;
            }

            self.requested2FACode = YES;
            self.titleLabel.text = @"Verification Code";
            if (@available(iOS 13.0, *)) {
                self.titleLabel.textColor = [UIColor labelColor];
            } else {
                self.titleLabel.textColor = [UIColor blackColor];
            }
            self.subtitleLabel.text = @"Enter the newest six-digit code sent by Apple for this sign-in. Requesting another code invalidates older codes.";
            [self.passwordTextField becomeFirstResponder];
        });
    }];
}

- (IBAction)didTapFallbackButton:(id)sender {
    [self requestVerificationCode];
}

- (IBAction)didTapConfirmButton:(id)sender {
    if (self.authenticationInProgress || self.passwordTextField.text.length != 6) {
        return;
    }

    NSString *code = [self.passwordTextField.text copy];
    self.authenticationInProgress = YES;
    self.passwordTextField.enabled = NO;
    self.requestCodeButton.enabled = NO;
    self.confirmBarButtonItem.enabled = NO;
    [self showNavigationSpinner];

    [[RPVAccountChecker sharedInstance] validateLoginCode:code withCompletionHandler:^(NSString *failureReason, NSString *resultCode, NSArray *teamIDArray, NSURLCredential *credential) {
        dispatch_async(dispatch_get_main_queue(), ^{
            BOOL hasActiveSession = [[RPVAccountChecker sharedInstance] hasActiveTwoFactorSession];
            self.authenticationInProgress = NO;
            self.passwordTextField.enabled = YES;
            self.requestCodeButton.enabled = hasActiveSession;
            [self restoreNavigationButton];

            if (teamIDArray.count > 0 && credential) {
                [self presentTeamIDViewControllerIfNecessaryWithTeamIDs:teamIDArray credentials:credential];
                return;
            }

            NSString *message = failureReason.length > 0
                ? failureReason
                : @"Apple did not accept that verification code. Please request a new code and try again.";
            if (!hasActiveSession &&
                [message rangeOfString:@"accepted the verification code" options:NSCaseInsensitiveSearch].location == NSNotFound) {
                message = [NSString stringWithFormat:@"%@ This verification session is no longer available. Go back and sign in again.", message];
            }
            [self changeUIToIncorrectStatus:message];
        });
    }];
}

- (void)changeUIToIncorrectStatus:(NSString*)statusString {
    self.titleLabel.text = @"Authentication Failed";
    self.titleLabel.textColor = [UIColor systemRedColor];
    self.subtitleLabel.text = statusString.length > 0
        ? statusString
        : @"Authentication could not be completed. Please try again.";

    self.passwordTextField.text = @"";
    self.confirmBarButtonItem.enabled = NO;
}

- (void)setupWithEmailAddress:(NSString*)emailAddress {
    self.emailAddress = emailAddress;
}

////////////////////////////////////////////////////////
// UITextFieldDelegate
////////////////////////////////////////////////////////

- (void)textFieldDidChange:(id)sender {
    NSString *text = self.passwordTextField.text ?: @"";
    NSString *digits = [[text componentsSeparatedByCharactersInSet:[[NSCharacterSet decimalDigitCharacterSet] invertedSet]] componentsJoinedByString:@""];
    if (digits.length > 6) {
        digits = [digits substringToIndex:6];
    }
    if (![digits isEqualToString:text]) {
        self.passwordTextField.text = digits;
    }

    self.confirmBarButtonItem.enabled = digits.length == 6 &&
        !self.authenticationInProgress &&
        [[RPVAccountChecker sharedInstance] hasActiveTwoFactorSession];
}


#pragma mark - Navigation

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([[[segue destinationViewController] class] isEqual:[RPVAccountTeamIDViewController class]]) {
        // If Team ID controller, pass through the interim team ID array.
        RPVAccountTeamIDViewController *teamidController = (RPVAccountTeamIDViewController*)[segue destinationViewController];
        
        [teamidController setupWithDataSource:self._interimTeamIDArray username:self.credentials.user andPassword:self.credentials.password];
    } else if ([[[segue destinationViewController] class] isEqual:[RPVAccountFinalController class]]) {
        // or if the final controller, send everything through!
        
        NSString *teamID = [[self._interimTeamIDArray firstObject] objectForKey:@"teamId"];
        NSString *username = self.credentials.user;
        NSString *password = self.credentials.password;
        
        RPVAccountFinalController *finalController = (RPVAccountFinalController*)[segue destinationViewController];
        
        [finalController setupWithUsername:username password:password andTeamID:teamID];
    }
}

@end
