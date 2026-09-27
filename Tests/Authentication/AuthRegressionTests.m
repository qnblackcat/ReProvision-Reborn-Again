#import <Foundation/Foundation.h>
#import <objc/runtime.h>
#import "EEAppleServices.h"
#import "RPVAuthentication.h"
#import "AuthKit.h"

// Also compile against the old source to demonstrate the regressions.
@interface EEAppleServices (TestLoginBindingDeclaration)
- (void)listTeamsWithCredentials:(NSURLCredential *)credentials completionHandler:(void (^)(NSError *, NSDictionary *))completionHandler;
@end

static int failures;
static void Check(BOOL condition, NSString *name) {
    printf("%s %s\n", condition ? "PASS" : "FAIL", name.UTF8String);
    if (!condition) failures++;
}

// Real production parser methods; stub only logging and error construction.
#define RPVInternalLoginError 5000
#define RPVInternalLoginIncorrect2FACodeError 4012
#define RPV2FADiagnosticLog(...) ((void)0)
@interface Parser : NSObject
@end
@implementation Parser
- (NSError *)createError:(NSString *)message :(int)code {
    return [NSError errorWithDomain:@"test.auth" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
}
#include "ParserMethods.inc"
@end

@implementation AKDevice
+ (id)currentDevice { return [self new]; }
- (NSString *)uniqueDeviceIdentifier { return @"test-device"; }
@end

static void (^pendingPreparation)(NSError *);
static BOOL holdPreparation;
@implementation RPVAuthentication
- (void)prepareAnisetteWithCompletion:(void (^)(NSError *))completion {
    if (holdPreparation) pendingPreparation = [completion copy];
    else completion(nil);
}
- (NSDictionary *)appleIDHeadersForRequest:(NSURLRequest *)request { return @{}; }
@end

static NSMutableArray<NSURLRequest *> *requests;
static BOOL failFirstResponse;
@interface FakeAppleProtocol : NSURLProtocol
@end
@implementation FakeAppleProtocol
+ (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
+ (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
- (void)startLoading {
    BOOL fail;
    @synchronized(requests) {
        [requests addObject:self.request];
        fail = failFirstResponse && requests.count == 1;
    }
    NSData *data = fail ? [@"<html>temporarily unavailable</html>" dataUsingEncoding:NSUTF8StringEncoding]
        : [NSPropertyListSerialization dataWithPropertyList:@{@"resultCode":@0, @"teams":@[]}
            format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
    NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL
        statusCode:fail ? 503 : 200 HTTPVersion:@"HTTP/1.1"
        headerFields:@{@"Content-Type":fail ? @"text/html" : @"text/x-xml-plist"}];
    [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
    [self.client URLProtocol:self didLoadData:data];
    [self.client URLProtocolDidFinishLoading:self];
}
- (void)stopLoading {}
@end

@interface NSURLSessionConfiguration (TestTransport)
+ (NSURLSessionConfiguration *)test_ephemeralSessionConfiguration;
@end
@implementation NSURLSessionConfiguration (TestTransport)
+ (NSURLSessionConfiguration *)test_ephemeralSessionConfiguration {
    NSURLSessionConfiguration *config = [self test_ephemeralSessionConfiguration];
    config.protocolClasses = @[FakeAppleProtocol.class];
    return config;
}
@end

static NSURLCredential *Credential(NSString *token) {
    return [NSURLCredential credentialWithUser:@"123|test" password:token persistence:NSURLCredentialPersistenceNone];
}

static void TestCredentialRace(BOOL explicitLogin, BOOL retry) {
    requests = [NSMutableArray new];
    failFirstResponse = retry;
    holdPreparation = YES;
    pendingPreparation = nil;
    EEAppleServices *services = [EEAppleServices new];
    [services setValue:Credential(explicitLogin ? @"older-token" : @"new-token") forKey:@"credentials"];
    dispatch_semaphore_t done = dispatch_semaphore_create(0);
    __block NSError *resultError;
    void (^completion)(NSError *, NSDictionary *) = ^(NSError *error, NSDictionary *plist) {
        resultError = error;
        dispatch_semaphore_signal(done);
    };
    if (explicitLogin) {
        if (![services respondsToSelector:@selector(listTeamsWithCredentials:completionHandler:)]) {
            Check(NO, @"explicit login credential binding (method absent in old code)");
            return;
        }
        [services listTeamsWithCredentials:Credential(@"new-token") completionHandler:completion];
    } else {
        [services listTeamsWithCompletionHandler:completion];
    }
    // Reproduce a background refresh restoring older saved credentials while
    // the fresh login's request is waiting for its anisette response.
    [services setValue:Credential(@"expired-background-token") forKey:@"credentials"];
    Check(pendingPreparation != nil, @"request waited for anisette");
    holdPreparation = NO;
    if (pendingPreparation) pendingPreparation(nil);
    Check(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 8 * NSEC_PER_SEC)) == 0,
          @"request completed");
    Check(resultError == nil, @"mock portal response succeeded");
    @synchronized(requests) {
        Check(requests.count == (retry ? 2 : 1), @"expected number of portal requests");
        for (NSURLRequest *request in requests) {
            Check([[request valueForHTTPHeaderField:@"X-Apple-GS-Token"] isEqualToString:@"new-token"],
                  retry ? @"retry retains original credentials" : @"request retains original credentials");
        }
    }
}

int main(void) { @autoreleasepool {
    Parser *parser = [Parser new];
    Check([[parser _twoFactorErrorCodeFromResponseDictionary:@{@"ec":@0, @"Response":@{@"Status":@{@"ec":@(-21669)}}}] isEqual:@(-21669)], @"nested failure overrides outer success");
    Check([[parser _twoFactorErrorCodeFromResponseDictionary:@{@"service_errors":@[@{@"code":@0}, @{@"code":@(-21669)}]}] isEqual:@(-21669)], @"all service errors inspected");
    Check([parser _twoFactorErrorCodeFromResponseDictionary:@{@"code":@"not-a-number"}] == nil, @"nonnumeric code is not success");
    Check([[parser _twoFactorErrorCodeFromResponseDictionary:@{@"Response":@{@"Status":@{@"ec":@0}}}] isEqual:@0], @"valid structured success preserved");
    Check([parser _twoFactorErrorCodeFromResponseDictionary:nil] == nil, @"missing response handled");
    NSURL *url = [NSURL URLWithString:@"https://example.invalid/auth"];
    NSHTTPURLResponse *(^response)(NSInteger) = ^(NSInteger status) {
        return [[NSHTTPURLResponse alloc] initWithURL:url statusCode:status HTTPVersion:@"HTTP/1.1" headerFields:nil];
    };
    NSError *error = [parser _twoFactorServerErrorForData:[@"{\"ec\":0}" dataUsingEncoding:NSUTF8StringEncoding] response:response(401) transportError:nil];
    Check(error.code == 401, @"HTTP failure not masked by ec=0");
    error = [parser _twoFactorServerErrorForData:[@"<html>Login</html>" dataUsingEncoding:NSUTF8StringEncoding] response:response(200) transportError:nil];
    Check(error != nil, @"HTTP 200 HTML cannot report code request success");
    Check([parser _twoFactorServerErrorForData:[NSData data] response:response(204) transportError:nil] == nil, @"empty phone success still accepted");
    error = [parser _twoFactorServerErrorForData:[@"{\"ec\":-21669}" dataUsingEncoding:NSUTF8StringEncoding] response:response(200) transportError:nil];
    Check(error.code == 4012, @"explicit Apple wrong-code error retained");
    Method original = class_getClassMethod(NSURLSessionConfiguration.class, @selector(ephemeralSessionConfiguration));
    Method replacement = class_getClassMethod(NSURLSessionConfiguration.class, @selector(test_ephemeralSessionConfiguration));
    method_exchangeImplementations(original, replacement);
    TestCredentialRace(NO, NO);
    TestCredentialRace(YES, NO);
    TestCredentialRace(YES, YES);
    method_exchangeImplementations(original, replacement);
    printf("Failures: %d\n", failures);
    return failures ? 1 : 0;
} }
