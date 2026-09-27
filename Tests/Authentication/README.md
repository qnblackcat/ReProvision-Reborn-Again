# Authentication regression tests and diagnosis — 2026-09-05

Run on macOS with Xcode command-line tools:

```sh
ruby Tests/Authentication/run.rb
```

The test runner compiles the actual `EEAppleServices.m` with fake AuthKit,
anisette preparation, and an intercepted NSURLSession transport. It also
extracts the five Foundation-only 2FA parser methods verbatim from
`RPVLoginImpl.m`. It does not exercise SRP cryptography or contact Apple.

## Confirmed defects

1. Developer request headers read the singleton's credentials **after** an
   asynchronous anisette fetch. Restoring older saved credentials during that
   wait replaces the token used by the pending request. Post-login team lookup
   also ignored the credentials passed into account setup. The fix binds both
   the initial request and retries to the operation's credentials, and returns
   the locally created credentials from login callbacks.
2. A top-level `ec=0` masked nested failures; only the first service error was
   inspected; nonnumeric strings were interpreted as zero. The parser now
   checks all candidate codes and preserves a nonzero failure.
3. An HTTP error could lose its status code when the body contained `ec=0`.
4. HTTP 200 with an HTML/non-dictionary body could count as a successful code
   request. It now reports an unreadable response. Empty 2xx phone responses
   remain supported.
5. The 2FA UI claimed the code was accepted merely because the one-time session
   no longer existed. That implication was removed. Team-lookup failures now
   explicitly identify the Developer account setup stage. Resending clears
   the previous code from the input field.

## Evidence and limits

Candidate `0.8.4-rootless.26` built successfully for arm64 devices. The package
control/version and rootless payload were inspected; the executable contains
the new authentication paths. SHA-256:
`35b67a40ed7653759918008ff64aefb1a2b560e0765d6f70bd2fc66ae6876b9e`.
The iOS 17.2 simulator build also succeeded, launched to the Apple ID screen,
and remained running. No real Apple login or physical-device installation was
performed during this validation.

The pre-change implementation fails the credential-swap reproduction and
the response-parser cases. The patched implementation passes 25 assertions,
including a delayed request, explicitly supplied login credentials, and an
HTML 503 followed by a successful safe retry with the original token.

The affected reporter's v22 account/iPad has **not** been reproduced. A correct
code can also fail because the current challenge/session differs from the one
that issued it, or because a later Apple service request fails. These tests do
not prove which happened to any particular reporter. In particular, an explicit
Apple `-21669` response remains a verification rejection; this patch does not
turn it into success or bypass verification.

The optional sanitized authentication log now records GrandSlam operation
(`init`, `complete`, `apptokens`), HTTP status, parse success, and numeric Apple
status. It does not record passwords, verification codes, identities, tokens,
or response bodies. Existing debug logging remains opt-in.

For reporter validation, install the candidate, reopen the app, start one
fresh login, and enter the newest code requested by that attempt. If it fails,
record the complete error and whether it appeared before the code, after code
submission, or during Developer account setup. Obtain a sanitized diagnostic
trace before attributing remaining failures to a specific cause. Do not ask
for passwords or codes, or require removing trusted devices/certificates.
