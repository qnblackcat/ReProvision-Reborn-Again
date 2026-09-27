# Changelog

## v0.8.4-rootless.28

### Changes

- Fixed a cause of **HTTP 503** errors at the start of Apple ID sign-in.
- Updated authentication compatibility while preserving existing account and certificate data.
- Disabled test diagnostic logging in the regular release.

### Note

Regression tests pass; full login on the affected reporter's device still needs confirmation.

## v0.8.4-rootless.27

### Changes

- Fixed Apple ID login failing with **HTTP 503** after authentication.
- Improved recovery from temporary Apple authentication service errors.
- Fixed a bug that could interrupt signing when the device was locked.
- Improved background signing reliability when ReProvision reconnects to its daemon.

### Note

The login fix has been confirmed by a tester. Locked-device background signing
passed local regression tests but still needs physical-device confirmation.
For scheduled signing, enable **Automatically Re-sign** and **True Background Signing**.

## v0.8.4-rootless.26 - 2026-09-05

### Changes

- Fixed a race that could replace a new login's credentials with an older
  session while contacting Apple, including during retries.
- Improved handling of failed or unreadable Apple verification responses.
- Clarified when sign-in succeeds but Developer account setup fails, instead
  of implying that the verification code was wrong.
- Clear the previous verification code when requesting a new one.

### Testing note

Authentication regression tests pass, but the affected reporter's account and
iPad have not been tested. This is a candidate fix, not confirmation that every
**Session expired** or **Incorrect 2FA code** report is resolved.

## v0.8.4-rootless.25 - 2026-09-04

### Changes

- Fixed signing failing with **Apple returned an unreadable Developer Services
  response** when the device was locked immediately after pressing **Sign**.
- ReProvision now keeps an active signing operation alive through the lock
  transition and preserves the Apple authentication identity for the full
  signing pass.
- Added automatic recovery for temporary Apple response failures caused by the
  Wi-Fi/background transition.
- Removed the duplicate generic error notification after an app-specific
  signing error had already been shown.

## v0.8.4-rootless.24 - 2026-09-04

### Changes

- Fixed **Initiate Background Signing** doing nothing when the daemon was
  disconnected or no applications needed signing.
- The button now runs a real background-signing check and reports whether it
  succeeded, found no apps to sign, needs login, or could not reach the daemon.
- Added a lock-screen notification for the test result so background signing
  can be verified after locking the device.
- Prevented repeated taps and overlapping background wakes from starting
  duplicate signing operations.

## v0.8.4-rootless.23 - 2026-09-04

### Changes

- Fixed successful 2FA verification sometimes requiring the user to cancel
  and sign in a second time before the account was accepted.
- Added automatic retries while Apple finishes creating the trusted login
  session after accepting a verification code.
- Prevented an already-consumed verification session from being reused by
  **Confirm** or **Send New Code**.
- Removed duplicate Developer account requests that could turn a successful
  Apple login into **Your session has expired**.
- Improved compatibility with account-specific Apple authentication response
  formats and incomplete account metadata.
- Fixed automatic re-signing not starting when the device was locked or asleep.
- Migrated existing saved credentials so they remain available to automatic
  signing after the first unlock.
- Added a native background-fetch fallback and combined duplicate wake requests
  into one signing pass.
- Fixed the daemon reading background-signing switches from the wrong settings
  domain.

## v0.8.4-rootless.22 - 2026-09-01

### Changes

- Fixed **Apple did not return a usable trusted phone number** even when the
  verification SMS was delivered successfully.
- Improved SMS and voice verification by using the trusted phone identifier
  and delivery method returned for the Apple account.
- Fixed a valid verification code sometimes appearing to fail after Apple had
  already accepted it.
- Removed the duplicate account-team check after 2FA and added a retry when
  Apple temporarily fails to return the account's developer team.
- Prevented expired or already-consumed verification sessions from being used
  again by **Send New Code** or **Confirm**.

### Login notice

- Apple may accept the verification code and cache the trusted session before
  ReProvision finishes loading the developer account. If the first attempt
  then reports **Your session has expired**, **Apple authentication session is
  incomplete**, or returns to the login screen, fully close ReProvision from
  the App Switcher, reopen it, and sign in again. Apple may reuse the cached
  trusted session, so a second verification code might not be requested.
- If several codes were requested, only the newest code is valid. Do not keep
  submitting an older code.
- The corrected SMS flow was confirmed on a physical iOS 16.7.15 device, but
  Apple's private authentication service can behave differently between
  accounts and iOS versions. A successful login on one account does not
  guarantee identical behavior for every account.

## v0.8.4-rootless.21 - 2026-09-01

### Fixed

- Fixed automatic re-sign timers being recreated on inactive XPC and Darwin-
  notification worker run loops, which silently prevented later checks from
  firing until the display was turned on again.
- Background wake scheduling now defaults on for automatic re-signing and is
  rebuilt immediately when its switch, check interval, or automatic re-sign
  preference changes.
- Fixed Low Power Mode skips permanently stopping the one-shot signing timer;
  the next check is now scheduled even when the current check is deferred.
- Fixed app-side and daemon-side XPC invalidation races where an old
  connection callback could destroy a newly established replacement.
- Added bounded retries for locked-device SpringBoard launches and delayed
  process registration, with an unlock fallback only after background launch
  retries are exhausted.
- Added a suspended-launch compatibility fallback when modern SpringBoard
  rejects the legacy background-fetch activation-options dictionary.

### Compatibility

- Renamed the advanced option to **Wake for Background Re-sign** and enabled
  it by default for new installations while preserving an explicit user choice
  to disable it.
- Built and launch-tested on an iOS 18.5 simulator. Hardware wake and locked-
  device assertion behavior still require validation with the rootless package
  installed on a physical device.

## v0.8.4-rootless.20 - 2026-08-31

### Fixed

- Fixed valid Apple verification codes being rejected for accounts whose
  trusted phone-number identifier is not `1`.
- ReProvision now reads Apple's current trusted-phone metadata and uses the
  account's actual phone-number identifier and `sms` or `voice` delivery mode.
- Phone-delivered codes are now submitted through Apple's phone-verification
  endpoint instead of the incompatible trusted-device validation endpoint.
- Verification-code requests now validate the HTTP status and Apple error
  response instead of displaying a code-entry screen after a rejected request.
- Localized decimal digits from iOS keyboards and one-time-code AutoFill are
  normalized to the six ASCII digits required by Apple's authentication API.
- Clarified that requesting another verification code invalidates older codes.

### Compatibility

- Built and launch-tested on both iPhone and iPad iOS 18.5 simulators. Apple
  account authentication still requires confirmation on a physical device.

## v0.8.4-rootless.19 - 2026-08-31

### Fixed

- Fixed the **Loading...** and progress interfaces sometimes remaining visible
  after an app was installed, signed, or re-signed successfully.
- Prevented duplicate signing-completion callbacks from starting competing
  dismissal animations or leaving the application-detail panel on screen.
- Installation-interface cleanup now completes correctly even when UIKit
  interrupts its dismissal animation during an installer transition.
- Removed the unnecessary **Loading...** alert from local IPA and share imports
  and fixed the presentation race in the remote IPA download flow.

## v0.8.4-rootless.18 - 2026-08-31

### Fixed

- Fixed scheduled automatic re-sign checks being cancelled whenever the
  display turned off. The persistent daemon now keeps its timer armed and can
  launch ReProvision in the background while the device remains locked.

### Compatibility

- Rebuilt and launch-tested the current source on an iOS 18.5 simulator.
- A daemon-scheduled re-sign completed on the jailbroken iPhone VM while the
  device was locked and ReProvision was terminated before the timer fired.

## v0.8.4-rootless.17 - 2026-08-31

### Fixed

- Fixed intermittent **2FA code is incorrect** and **Your session has expired**
  failures caused by changing the remote ADI identity between GrandSlam login,
  verification-code submission, token issuance, and Developer Services calls.
- Transient anisette failures now retry with the identity already bound to the
  active session instead of silently reprovisioning it. A stale identity can
  still be replaced safely before a new manual sign-in begins.
- Added the iOS 26 `InstallCoordination` installation path and required
  platform entitlement, replacing the unsupported `LSApplicationWorkspace`
  install call that failed with `NSOSStatusErrorDomain` code `-4`.
- Dopamine and other re-signed applications now wait for the real asynchronous
  installation result before ReProvision reports success or removes the old
  working copy.
- Fixed failed installs incorrectly producing a second **Signed** success
  notification.
- Fixed the install/re-sign progress overlay remaining locked after the iOS 26
  asynchronous installer had already completed.

### Compatibility

- The new installation path is used on iOS 26 and later. iOS 15 through iOS 18
  retain the existing MobileInstallation-compatible path.

## v0.8.4-rootless.16 - 2026-08-27

### Added

- Added complete adaptive dark-mode styling across the app, including the
  dashboard, account flow, settings, detail screens, alerts, cells, and Add
  and Sign controls.

### Fixed

- Fixed apps that installed successfully on iOS 18 but were rejected when
  launched. The embedded signer now creates valid DER entitlements with
  variable-width lengths and correctly handles the value types used by modern
  entitlement dictionaries.
- Replaced obsolete bundle resource-sealing rules with the modern iOS
  `CodeResources` format accepted by strict code-signature validation.
- Preserved each extension and Watch app's own entitlements while sealing its
  parent application instead of applying the main app's entitlements to every
  nested executable.
- Corrected executable-segment flags and standards-compliant ad-hoc signature
  metadata used by simulator validation.

### Compatibility

- The signing and launch path was verified with native builds on iOS 16.4 and
  iOS 18.5 simulators. iOS 26 is not yet claimed as tested support and still
  requires verification on a compatible physical rootless-jailbroken device.

## v0.8.4-rootless.15 - 2026-08-27

### Fixed

- Fixed **Multiple .app bundles with the bundle ID** after an earlier signing
  attempt left stale application bundles in a shared extraction directory.
  Every signing operation now uses a clean, unique workspace and validates
  that the IPA contains exactly one top-level application bundle.
- Fixed direct IPA installation failures caused by passing the app's original
  bundle identifier to MobileInstallation after signing changed it to the
  Personal Team identifier.
- ReProvision no longer removes an existing app before its signed replacement
  installs successfully. A failed replacement now leaves the working app in
  place.
- Replaced **NULL** installation alerts with the original installer
  description, error domain and code, plus the original and signed bundle IDs
  when they differ.
- Fixed the fallback IPA-signing API reusing extraction directories and
  repacking a path other than the one it had actually unpacked.

## v0.8.4-rootless.14 - 2026-08-27

### Fixed

- Fixed Apple rejecting signing with **You currently already have a current
  development certificate or a pending certificate request** after an upgrade
  or reinstall changed ReProvision's locally stored machine UUID.
- ReProvision now verifies an existing certificate against the private key in
  its keychain. A cryptographically matching, unexpired certificate is reused
  even if its old machine UUID differs, and the local UUID is reconciled for
  subsequent signing operations.
- Certificate recovery does not revoke unrelated AltStore, Xcode, or
  ReProvision certificates belonging to another device.

## v0.8.4-rootless.13 - 2026-08-27

This release is branded **ReProvision Reborn… Again** and brings ReProvision
to rootless jailbreaks on iOS 15 and newer. The complete sign-in, 2FA,
certificate, signing, installation, and re-signing flow was tested on a
physical iOS 17.2 device.

### Added

- Added a complete rootless package layout under `/var/jb` for the app, share
  extension, launch daemon, and maintainer scripts.
- Added rootless daemon loading and automatic background-signing support.
- Restored trusted-device two-factor authentication with an in-app six-digit
  code field, Confirm action, and resend support.
- Added a persistent per-installation anisette identity with connection
  timeouts and retry handling.
- Added an iOS 17.2 Simulator build and launch-validation workflow.
- Added `b4db1r3` as a maintainer while retaining the original author credits
  and package identifier for upgrade compatibility.

### Fixed

- Fixed apps signed by ReProvision installing successfully but being rejected
  before launch on iOS 17. The embedded signer now emits SHA-256 as the primary
  CodeDirectory and retains SHA-1 as a compatibility alternate.
- Updated the packaged app, extension, and daemon to modern CodeDirectory
  signatures accepted by iOS 17.
- Fixed the ReProvision startup crash caused by obsolete Firebase crash
  handling on modern iOS.
- Fixed the **Could not connect to daemon** condition that disabled automatic
  background signing on rootless jailbreaks.
- Fixed repeated **Your session has expired** failures after successful Apple
  account authentication.
- Fixed transient anisette WebSocket failures reported as **Socket is not
  connected (57)**.
- Fixed the inactive **Continue Authentication** action and missing trusted-
  device verification-code interface.
- Fixed apps whose bundle identifiers already contained a Personal Team
  suffix, preventing malformed double-suffixed App IDs and profiles.
- Fixed successfully signed apps incorrectly appearing under **Expiring
  Soon** instead of **Recently Signed** on modern iOS.
- Removed the obsolete exact Debian-receipt check that caused an immediate
  exit when a repository rewrote the package identifier.
- Hardened provisioning-profile parsing and removed sensitive authentication
  logging.

### Important

- Apps signed by revision 12 or older must be signed again after upgrading;
  updating ReProvision does not replace an app's existing invalid signature.
- Free Apple accounts remain subject to Apple's active-certificate and
  provisioning limits.
- No Apple credentials, session tokens, Team IDs, or device-specific values
  are embedded in the package.
- iOS 15 and iOS 16 meet the build target but have not received the same full
  physical-device validation as iOS 17.2.

## v0.8.4 - 2026-06-05

Repository maintenance release. No application binary is attached to this release.

- Documented the current conservative maintenance scope.
- Added security reporting guidance for sensitive workflows.
- Added structured issue templates for reproducible bug reports and non-sensitive security hardening suggestions.
- Added a best-effort DevSkim security scanning baseline.
