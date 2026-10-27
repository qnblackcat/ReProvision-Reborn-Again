//
//  RPVAccountViewController.m
//  iOS
//
//  Created by Matt Clarke on 07/03/2018.
//  Copyright © 2018 Matt Clarke. All rights reserved.
//

#import "RPVAccountViewController.h"
#import "RPVAccount2FAViewController.h"
#import "RPVAccountTeamIDViewController.h"
#import "RPVAccountFinalController.h"
#import "RPVAccountChecker.h"
#import "EEAppleServices.h"
#import "RPVRemoteAnisetteProvider.h"

@interface RPVAccountViewController ()

@property (nonatomic, strong) NSArray *_interimTeamIDArray;
@property (nonatomic, strong) NSURLCredential *credentials;
@property (nonatomic, strong) UIButton *anisetteServerButton;
@end

@implementation RPVAccountViewController

- (void)viewDidLoad {
    [super viewDidLoad];
    // Do any additional setup after loading the view.
    
    self.confirmButtonItem.enabled = NO;
    [self.passwordTextField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    [self.emailTextField addTarget:self action:@selector(textFieldDidChange:) forControlEvents:UIControlEventEditingChanged];
    
    // Handle colour
    
    if (@available(iOS 13.0, *)) {
        self.view.backgroundColor = [UIColor systemBackgroundColor];
        self.titleLabel.textColor = [UIColor labelColor];
        self.subtitleLabel.textColor = [UIColor labelColor];
        self.emailTextField.textColor = [UIColor labelColor];
        self.passwordTextField.textColor = [UIColor labelColor];
        self.emailTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.emailTextField.placeholder ?: @""
                                                                                       attributes:@{ NSForegroundColorAttributeName: [UIColor tertiaryLabelColor] }];
        self.passwordTextField.attributedPlaceholder = [[NSAttributedString alloc] initWithString:self.passwordTextField.placeholder ?: @""
                                                                                          attributes:@{ NSForegroundColorAttributeName: [UIColor tertiaryLabelColor] }];

        for (UIView *subview in self.view.subviews) {
            if ([subview isKindOfClass:[UILabel class]] &&
                [((UILabel *)subview).text isEqualToString:@"Your details are only sent to Apple"]) {
                ((UILabel *)subview).textColor = [UIColor secondaryLabelColor];
            }
        }
    } else {
        self.view.backgroundColor = [UIColor whiteColor];
        self.titleLabel.textColor = [UIColor blackColor];
        self.subtitleLabel.textColor = [UIColor blackColor];
    }

    [self _addAnisetteServerButton];
}

#pragma mark - Anisette server

// Remote anisette is only used on iOS 17 and newer.
- (BOOL)_usesRemoteAnisette {
    NSOperatingSystemVersion version = {17, 0, 0};
    return [[NSProcessInfo processInfo] isOperatingSystemAtLeastVersion:version];
}

// Lets the user switch servers here, since a failing server can block sign-in
// before they ever reach Settings.
- (void)_addAnisetteServerButton {
    if (![self _usesRemoteAnisette])
        return;

    UIButton *button = [UIButton buttonWithType:UIButtonTypeSystem];
    button.translatesAutoresizingMaskIntoConstraints = NO;
    button.titleLabel.font = [UIFont systemFontOfSize:15];
    button.titleLabel.adjustsFontSizeToFitWidth = YES;
    button.titleLabel.minimumScaleFactor = 0.7;
    [button addTarget:self action:@selector(_didTapAnisetteServerButton:) forControlEvents:UIControlEventTouchUpInside];
    [self.view addSubview:button];
    self.anisetteServerButton = button;

    // Sit directly above the storyboard's Privacy Policy button.
    UIView *anchor = nil;
    for (UIView *subview in self.view.subviews) {
        if ([subview isKindOfClass:[UIButton class]] && subview != button) {
            NSString *title = [(UIButton *)subview titleForState:UIControlStateNormal];
            if ([title isEqualToString:@"Privacy Policy"]) {
                anchor = subview;
                break;
            }
        }
    }

    NSMutableArray *constraints = [NSMutableArray arrayWithArray:@[
        [button.centerXAnchor constraintEqualToAnchor:self.view.centerXAnchor],
        [button.leadingAnchor constraintGreaterThanOrEqualToAnchor:self.view.leadingAnchor constant:16],
        [button.trailingAnchor constraintLessThanOrEqualToAnchor:self.view.trailingAnchor constant:-16],
    ]];
    if (anchor) {
        [constraints addObject:[button.bottomAnchor constraintEqualToAnchor:anchor.topAnchor constant:-4]];
    } else if (@available(iOS 11.0, *)) {
        [constraints addObject:[button.bottomAnchor constraintEqualToAnchor:self.view.safeAreaLayoutGuide.bottomAnchor constant:-48]];
    } else {
        [constraints addObject:[button.bottomAnchor constraintEqualToAnchor:self.view.bottomAnchor constant:-48]];
    }
    [NSLayoutConstraint activateConstraints:constraints];

    [self _updateAnisetteServerButtonTitle];
}

- (void)_updateAnisetteServerButtonTitle {
    NSString *title = [NSString stringWithFormat:@"Anisette Server: %@", [RPVRemoteAnisetteProvider currentServerTitle]];
    [self.anisetteServerButton setTitle:title forState:UIControlStateNormal];
}

- (void)_didTapAnisetteServerButton:(UIButton *)sender {
    UIAlertController *sheet = [UIAlertController alertControllerWithTitle:@"Anisette Server"
                                                                   message:@"Try another server if sign-in keeps failing. If none of the servers work, use Device (AuthKit)."
                                                            preferredStyle:UIAlertControllerStyleActionSheet];

    for (NSDictionary *option in [RPVRemoteAnisetteProvider serverOptions]) {
        NSString *value = option[@"value"];
        NSString *title = option[@"title"];
        UIAlertAction *action = [UIAlertAction actionWithTitle:title style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
            if ([value isEqualToString:RPVAnisetteCustomServerValue]) {
                [self _promptForCustomAnisetteServer];
            } else {
                [RPVRemoteAnisetteProvider selectServerValue:value customHost:nil];
                [self _updateAnisetteServerButtonTitle];
            }
        }];
        [sheet addAction:action];
    }

    [sheet addAction:[UIAlertAction actionWithTitle:@"Reset Anisette" style:UIAlertActionStyleDestructive handler:^(UIAlertAction *a) {
        [RPVRemoteAnisetteProvider resetStoredStateForCurrentServer];
    }]];
    [sheet addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];

    // iPad presents action sheets as popovers.
    sheet.popoverPresentationController.sourceView = sender;
    sheet.popoverPresentationController.sourceRect = sender.bounds;
    [self presentViewController:sheet animated:YES completion:nil];
}

- (void)_promptForCustomAnisetteServer {
    UIAlertController *alert = [UIAlertController alertControllerWithTitle:@"Custom Anisette Server"
                                                                   message:@"Enter the server address."
                                                            preferredStyle:UIAlertControllerStyleAlert];
    [alert addTextFieldWithConfigurationHandler:^(UITextField *textField) {
        textField.placeholder = @"ani.yourserver.com";
        textField.keyboardType = UIKeyboardTypeURL;
        textField.autocapitalizationType = UITextAutocapitalizationTypeNone;
        textField.autocorrectionType = UITextAutocorrectionTypeNo;
        textField.text = [[NSUserDefaults standardUserDefaults] stringForKey:RPVAnisetteCustomServerPreferenceKey];
    }];
    [alert addAction:[UIAlertAction actionWithTitle:@"Cancel" style:UIAlertActionStyleCancel handler:nil]];
    [alert addAction:[UIAlertAction actionWithTitle:@"Use Server" style:UIAlertActionStyleDefault handler:^(UIAlertAction *a) {
        NSString *host = alert.textFields.firstObject.text;
        if ([RPVRemoteAnisetteProvider selectServerValue:RPVAnisetteCustomServerValue customHost:host]) {
            [self _updateAnisetteServerButtonTitle];
        } else {
            UIAlertController *invalid = [UIAlertController alertControllerWithTitle:@"Invalid Address"
                                                                             message:@"Enter a server address such as ani.yourserver.com."
                                                                      preferredStyle:UIAlertControllerStyleAlert];
            [invalid addAction:[UIAlertAction actionWithTitle:@"OK" style:UIAlertActionStyleDefault handler:nil]];
            [self presentViewController:invalid animated:YES completion:nil];
        }
    }]];
    [self presentViewController:alert animated:YES completion:nil];
}

- (void)viewWillAppear:(BOOL)animated {
    [super viewWillAppear:animated];
    
    [self.navigationController.navigationBar setBackgroundImage:[UIImage new] forBarMetrics:UIBarMetricsDefault];
    [self.navigationController.navigationBar setShadowImage:[UIImage new]];

    [self _updateAnisetteServerButtonTitle];
}

- (void)didReceiveMemoryWarning {
    [super didReceiveMemoryWarning];
    // Dispose of any resources that can be recreated.
}

- (void)present2FAViewController {
    [self performSegueWithIdentifier:@"present2FA" sender:nil];
    
    // Reset in case of a previous failure
    self.titleLabel.text = @"Apple ID";
    
    if (@available(iOS 13.0, *)) {
        self.titleLabel.textColor = [UIColor labelColor];
    } else {
        self.titleLabel.textColor = [UIColor blackColor];
    }
    
    self.subtitleLabel.text = @"Sign in with your Apple ID";
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

- (IBAction)didTapConfirmButton:(id)sender {
    // Check with Apple whether this email/password combo is correct.
    //  -- from output status, handle. i.e., segue to 2FA, show incorrect, or success handler.
    
    // Set right bar item to a spinning wheel
    UIActivityIndicatorView *spinner = [[UIActivityIndicatorView alloc] initWithActivityIndicatorStyle:UIActivityIndicatorViewStyleGray];
    spinner.hidesWhenStopped = YES;
    if (@available(iOS 13.0, *)) {
        spinner.color = [UIColor labelColor];
    }
    [spinner startAnimating];
    
    [self.navigationItem setRightBarButtonItem:[[UIBarButtonItem alloc] initWithCustomView:spinner]];
    
    [[RPVAccountChecker sharedInstance] checkUsername:self.emailTextField.text withPassword:self.passwordTextField.text andCompletionHandler:^(NSString *failureReason, NSString *resultCode, NSArray *teamIDArray, NSURLCredential* credentials) {
       
        if (teamIDArray) {
            // Handle the Team ID array. If one element, no worries. Otherwise we need to ask the user
            // which team to use.
            
            dispatch_async(dispatch_get_main_queue(), ^{
                [self presentTeamIDViewControllerIfNecessaryWithTeamIDs:teamIDArray credentials:credentials];
            });
            
        } else if ([resultCode isEqualToString:@"appSpecificRequired"]) {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self present2FAViewController];
            });
        } else {
            dispatch_async(dispatch_get_main_queue(), ^{
                [self changeUIToIncorrectStatus:failureReason];
            });
        }
        
        // Stop using a spinner.
        dispatch_async(dispatch_get_main_queue(), ^{
            [self.navigationItem setRightBarButtonItem:self.confirmButtonItem];
        });
    }];
}

- (void)changeUIToIncorrectStatus:(NSString*)statusString {
    self.titleLabel.text = @"Failure";
    self.titleLabel.textColor = [UIColor redColor];
    
    self.subtitleLabel.text = statusString != nil ? statusString : @"Unknown error";
    
    // Reset password field
    self.passwordTextField.text = @"";
    [self.passwordTextField becomeFirstResponder];
    
    // And disable button
    self.confirmButtonItem.enabled = NO;
}

////////////////////////////////////////////////////////
// UITextFieldDelegate
////////////////////////////////////////////////////////

- (void)textFieldDidChange:(id)sender {
    if (self.passwordTextField.text.length > 0) {
        self.confirmButtonItem.enabled = YES;
    } else {
        self.confirmButtonItem.enabled = NO;
    }
}

////////////////////////////////////////////////////////
// Segue Navigation
////////////////////////////////////////////////////////

// In a storyboard-based application, you will often want to do a little preparation before navigation
- (void)prepareForSegue:(UIStoryboardSegue *)segue sender:(id)sender {
    if ([[[segue destinationViewController] class] isEqual:[RPVAccount2FAViewController class]]) {
        
        // Setup 2FA controller with the current email address
        // TODO: 2FA support as required
        
        //RPVAccount2FAViewController *twofaController = (RPVAccount2FAViewController*)[segue destinationViewController];
        //[twofaController setupWithEmailAddress:self.emailTextField.text];
        
    } else if ([[[segue destinationViewController] class] isEqual:[RPVAccountTeamIDViewController class]]) {
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
