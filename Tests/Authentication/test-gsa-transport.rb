#!/usr/bin/env ruby
# Execute the actual GSA transport and parser against NSURLProtocol fixtures.
# No credentials, Apple requests, device, or external provider are required.
require 'tmpdir'
require 'fileutils'

root = File.expand_path('../..', __dir__)
source = File.read(ARGV[0] || File.join(root, 'Shared/libProvision/Apple Services/RPVLoginImpl.m'))
helpers = source[source.index('static NSString * const RPV2FADiagnosticsEnabledKey')...source.index('struct ccrng_state *ccDRBGGetRngState')]
methods = %w[defaultRequestHeaders makeRequestWithParameters _makeRequestWithParameters _newGrandSlamSessionWithTimeout _performGrandSlamRequest].map do |name|
  start = source.index(/^\- \([^\n]+\)#{name}\b/)
  abort "Missing #{name}" unless start
  source[start..source.index(/^\}/, start)]
end.join("\n")
Dir.mktmpdir('repro-gsa-tests-') do |build|
  File.write(File.join(build, 'Production.inc'), helpers)
  File.write(File.join(build, 'Methods.inc'), methods)
  File.write(File.join(build, 'main.m'), <<~'OBJC')
    #import <Foundation/Foundation.h>
    #import <objc/runtime.h>
    #define RPVInternalLogin2FARequiredTrustedDeviceError 4010
    #define RPVInternalLogin2FARequiredSecondaryAuthError 4011
    #define RPVInternalLoginError 5000
    #define log_debug(...) ((void)0)
    #include "Production.inc"
    #define CHECK(condition, message) do { if (!(condition)) { fprintf(stderr, "FAIL: %s\n", message); exit(1); } } while(0)
    @interface Probe : NSObject
    @property(nonatomic, copy) NSString *clientInfoOverride;
    @end
    @implementation Probe
    - (NSError *)createError:(NSString *)message :(int)code {
      return [NSError errorWithDomain:@"test.auth" code:code userInfo:@{NSLocalizedDescriptionKey:message}];
    }
    #include "Methods.inc"
    @end
    static NSArray<NSNumber *> *statuses;
    static NSMutableArray<NSURLRequest *> *requests;
    static NSMutableArray<NSData *> *bodies;
    static NSMutableArray<NSURLSession *> *sessions;
    static NSMutableSet *invalidated;
    static NSString *bodyKind;
    static NSString *retryAfter;
    static BOOL useTransportError;
    @interface FakeApple : NSURLProtocol @end
    @implementation FakeApple
    + (BOOL)canInitWithRequest:(NSURLRequest *)request { return YES; }
    + (NSURLRequest *)canonicalRequestForRequest:(NSURLRequest *)request { return request; }
    - (void)startLoading {
      NSUInteger index;
      @synchronized (requests) {
        index = requests.count;
        [requests addObject:self.request];
        NSData *body = self.request.HTTPBody;
        if (!body && self.request.HTTPBodyStream) {
          NSInputStream *stream = self.request.HTTPBodyStream;
          [stream open];
          NSMutableData *data = [NSMutableData data];
          uint8_t buffer[4096]; NSInteger count;
          while ((count = [stream read:buffer maxLength:sizeof(buffer)]) > 0) [data appendBytes:buffer length:count];
          [stream close]; body = data;
        }
        [bodies addObject:body ?: NSData.data];
      }
      if (useTransportError) {
        [self.client URLProtocol:self didFailWithError:[NSError errorWithDomain:NSURLErrorDomain code:NSURLErrorTimedOut userInfo:nil]];
        return;
      }
      NSInteger code = [statuses[MIN(index, statuses.count - 1)] integerValue];
      BOOL html = [bodyKind isEqual:@"html"] || (code >= 500 && [bodyKind isEqual:@"normal"]);
      id appleCode = [bodyKind isEqual:@"apple-error"] ? @"-20101" : @0;
      NSData *data = html ? [@"<html>PRIVATE_TEST_BODY</html>" dataUsingEncoding:NSUTF8StringEncoding] :
        [NSPropertyListSerialization dataWithPropertyList:@{@"Response":@{@"Status":@{@"ec":appleCode}, @"token":@"PRIVATE_TOKEN"}}
          format:NSPropertyListXMLFormat_v1_0 options:0 error:nil];
      NSMutableDictionary *headers = [@{@"Content-Type": html ? @"text/html" : @"text/x-xml-plist"} mutableCopy];
      if (retryAfter) headers[@"Retry-After"] = retryAfter;
      NSHTTPURLResponse *response = [[NSHTTPURLResponse alloc] initWithURL:self.request.URL statusCode:code HTTPVersion:@"HTTP/1.1" headerFields:headers];
      [self.client URLProtocol:self didReceiveResponse:response cacheStoragePolicy:NSURLCacheStorageNotAllowed];
      [self.client URLProtocol:self didLoadData:data];
      [self.client URLProtocolDidFinishLoading:self];
    }
    - (void)stopLoading {}
    @end
    @interface NSURLSession (Test)
    + (NSURLSession *)testSession:(NSURLSessionConfiguration *)configuration;
    - (void)testFinish;
    @end
    @implementation NSURLSession (Test)
    + (NSURLSession *)testSession:(NSURLSessionConfiguration *)configuration {
      CHECK(configuration.URLCache == nil, "cache must be disabled");
      CHECK(configuration.URLCredentialStorage == nil, "credential store must be disabled");
      CHECK(configuration.HTTPCookieStorage == NSHTTPCookieStorage.sharedHTTPCookieStorage, "cookie semantics preserved");
      CHECK(configuration.requestCachePolicy == NSURLRequestReloadIgnoringLocalCacheData, "request cache policy");
      CHECK(configuration.timeoutIntervalForResource <= 10, "bounded session resource timeout");
      configuration.protocolClasses = @[FakeApple.class];
      NSURLSession *session = [self testSession:configuration];
      @synchronized (sessions) { [sessions addObject:session]; }
      return session;
    }
    - (void)testFinish {
      @synchronized (invalidated) { [invalidated addObject:self]; }
      [self testFinish];
    }
    @end
    static void Reset(NSArray *codes, NSString *kind, NSString *retry, BOOL transport) {
      statuses = codes; bodyKind = kind; retryAfter = retry; useTransportError = transport;
      requests = NSMutableArray.new; bodies = NSMutableArray.new;
      sessions = NSMutableArray.new; invalidated = NSMutableSet.new;
    }
    static void CheckTransport(NSUInteger expected) {
      CHECK(requests.count == expected, "unexpected request/retry count");
      CHECK(sessions.count == expected, "one new session per attempt");
      CHECK([NSSet setWithArray:sessions].count == expected, "sessions must be distinct");
      CHECK(invalidated.count == expected, "every session must be invalidated");
      for (NSUInteger i = 0; i < expected; ++i) {
        NSURLRequest *request = requests[i];
        CHECK([[request valueForHTTPHeaderField:@"User-Agent"] isEqual:RPVGrandSlamUserAgent], "modern UA on wire");
        CHECK([request.URL.absoluteString isEqual:@"https://gsa.apple.com/grandslam/GsService2"], "Apple endpoint unchanged");
        CHECK([request.HTTPMethod isEqual:@"POST"], "method preserved");
        CHECK(request.timeoutInterval <= 10.0, "bounded request timeout");
        CHECK(bodies[i].length > 0 && [bodies[i] isEqual:bodies[0]], "retries preserve exact SRP body/identity");
      }
    }
    static void Run(Probe *probe, NSString *name, NSArray *codes, NSString *kind, NSString *retry, BOOL transport,
                    NSUInteger expected, BOOL expectsError) {
      Reset(codes, kind, retry, transport);
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      __block NSUInteger callbacks = 0;
      __block NSError *resultError;
      __block NSDictionary *result;
      [probe makeRequestWithParameters:@{@"o":@"apptokens", @"u":@"PRIVATE_ID", @"t":@"PRIVATE_TOKEN",
        @"c":[@"PRIVATE_CONTEXT" dataUsingEncoding:NSUTF8StringEncoding], @"checksum":[NSMutableData dataWithLength:32],
        @"app":@[@"com.apple.gs.xcode.auth"], @"cpd":@{@"X-Apple-I-MD":@"PRIVATE_OTP", @"X-Apple-I-MD-LU":@"PRIVATE_LU"}}
        completion:^(NSError *error, NSDictionary *response) { ++callbacks; resultError = error; result = response; dispatch_semaphore_signal(done); }];
      CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 10*NSEC_PER_SEC)) == 0, "completion timed out");
      CHECK((resultError != nil) == expectsError, "unexpected completion result");
      CHECK(callbacks == 1, "single completion");
      if (!expectsError) CHECK(result != nil, "successful response preserved");
      CheckTransport(expected);
      printf("PASS %s\n", name.UTF8String);
    }
    int main(void) { @autoreleasepool {
      CHECK(!RPV2FADiagnosticsEnabled(), "test logs must be disabled");
      Method realFactory = class_getClassMethod(NSURLSession.class, @selector(sessionWithConfiguration:));
      Method testFactory = class_getClassMethod(NSURLSession.class, @selector(testSession:));
      Method realFinish = class_getInstanceMethod(NSURLSession.class, @selector(finishTasksAndInvalidate));
      Method testFinish = class_getInstanceMethod(NSURLSession.class, @selector(testFinish));
      method_exchangeImplementations(realFactory, testFactory);
      method_exchangeImplementations(realFinish, testFinish);
      Probe *probe = [Probe new]; probe.clientInfoOverride = @"PRIVATE_CLIENT_INFO";
      Run(probe, @"success without retry", @[@200], @"normal", nil, NO, 1, NO);
      Run(probe, @"503 then 502 then success with identical body and isolated sessions", @[@503,@502,@200], @"normal", nil, NO, 3, NO);
      Run(probe, @"persistent 503 stops after three attempts", @[@503], @"normal", nil, NO, 3, YES);
      for (NSNumber *code in @[@400,@401,@403,@429])
        Run(probe, [NSString stringWithFormat:@"HTTP %@ is not retried", code], @[code], @"html", nil, NO, 1, YES);
      Run(probe, @"Apple credential rejection in HTTP 503 is not retried", @[@503], @"apple-error", nil, NO, 1, YES);
      Run(probe, @"Apple application error in HTTP 200 is passed to caller", @[@200], @"apple-error", nil, NO, 1, NO);
      Run(probe, @"HTML 200 is a parse failure, not a retry", @[@200], @"html", nil, NO, 1, YES);
      Run(probe, @"transport timeout is preserved without replay", @[@200], @"normal", nil, YES, 1, YES);
      Run(probe, @"Retry-After beyond budget stops immediately", @[@503], @"normal", @"30", NO, 1, YES);
      Run(probe, @"HTTP-date Retry-After beyond budget stops immediately", @[@503], @"normal", @"Wed, 01 Jan 2031 00:00:00 GMT", NO, 1, YES);
      Run(probe, @"invalid Retry-After uses bounded backoff", @[@503,@200], @"normal", @"not-a-delay", NO, 2, NO);
      Reset(@[@503], @"normal", nil, NO);
      NSMutableURLRequest *request = [NSMutableURLRequest requestWithURL:[NSURL URLWithString:@"https://gsa.apple.com/grandslam/GsService2"]];
      request.HTTPMethod = @"POST"; request.HTTPBody = [@"fixture" dataUsingEncoding:NSUTF8StringEncoding];
      [request setValue:RPVGrandSlamUserAgent forHTTPHeaderField:@"User-Agent"];
      dispatch_semaphore_t done = dispatch_semaphore_create(0);
      [probe _performGrandSlamRequest:request attempt:1 deadline:NSProcessInfo.processInfo.systemUptime + 0.5 diagnostics:@{}
        completion:^(NSData *data, NSURLResponse *response, NSError *error) { dispatch_semaphore_signal(done); }];
      CHECK(dispatch_semaphore_wait(done, dispatch_time(DISPATCH_TIME_NOW, 2*NSEC_PER_SEC)) == 0, "short deadline completion");
      CheckTransport(1);
      printf("PASS insufficient remaining budget prevents retry\n");
      Reset(@[@200], @"normal", nil, NO);
      __block BOOL timedOut = NO;
      [probe _performGrandSlamRequest:request attempt:1 deadline:NSProcessInfo.processInfo.systemUptime - 1 diagnostics:@{}
        completion:^(NSData *data, NSURLResponse *response, NSError *error) { timedOut = error.code == NSURLErrorTimedOut; }];
      CHECK(timedOut && sessions.count == 0, "expired budget must not start request");
      printf("PASS expired budget creates no session\n");
      method_exchangeImplementations(realFactory, testFactory);
      method_exchangeImplementations(realFinish, testFinish);
      return 0;
    } }
  OBJC
  binary = File.join(build, 'gsa-tests')
  abort 'Compile failed' unless system('xcrun', '--sdk', 'macosx', 'clang', '-fobjc-arc', '-fblocks',
    '-Wno-incompatible-pointer-types', '-I', build, File.join(build, 'main.m'), '-framework', 'Foundation', '-o', binary)
  abort 'Transport tests failed' unless system(binary)
end
