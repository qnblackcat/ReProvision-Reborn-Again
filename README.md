## ReProvision Reborn… Again
Re-sign applications on your device.

This project aims at making it easier to (re-)sign iOS and Apple Watch applications on a **jailbroken** iOS device, allowing users to avoid the 7-day limit of free certificates associated with their normal Apple account.

### Maintenance status
As of 2026, this fork is maintained with a conservative scope. The current focus is iOS support on jailbroken devices, issue triage, security-sensitive review, and compatibility fixes that can be verified by maintainers or contributors. Compatibility should be verified before assuming support for a specific iOS version, device, or jailbreak environment.

**ReProvision Reborn… Again** is the rootless iOS 15+ compatibility release maintained by **b4db1r3**, with credit retained for the original ReProvision and ReProvision Reborn developers.

tvOS and macOS are not a current maintenance focus for this fork. Changes in those areas may be accepted if they are well-tested, but users should not assume active support for those platforms.

See [MAINTENANCE.md](MAINTENANCE.md) for the current maintenance scope and triage policy.

### Features
- Automatic re-signing of locally provisioned applications
- Basic settings to configure alerts shown when applications are (re-)signed
- Ability to install any ``.ipa`` file downloaded through Safari from the device
- Support for (re-)signing Apple Watch applications
- 3D Touch menu for starting a new re-signing routine directly from the Homescreen
- URL scheme to install ipa file from URL

Battery optimisations are also in place through the usage of a background daemon to handle automatic signing.

## URL scheme
ReProvision Reborn supports URL scheme.

```
reprovision://install?url=<IPA URL>
```

## Notes
[The original project, ReProvision](https://github.com/Matchstic/ReProvision), reached end of life after Apple changed its application-provisioning services. This fork continues the project for modern jailbroken iOS environments.

Although this is an attempt at resurrecting the project, I ask that you **do not bother** the original developer about specific updates made to **this** fork, since they're no longer behind the project.

### Support
Attempting to maintain this fork comes at the cost of "dropping" tvOS and macOS support, since other viable options, such as [AltStore](https://github.com/rileytestut/AltStore) and AltDeploy are available for their respective platforms; the main focus of this fork is iOS.

Furthermore, while re-distribution of this software is allowed, support for modified versions of this software will not be provided.  

### Account Handling
Like most provisioning software, ReProvision supports free and paid development Apple accounts. While credentials are stored in the device's Keychain for subsequent re-use, they're only sent to Apple's iTunes Connect API for authentication.

### Security-sensitive areas
This project handles several security-sensitive workflows, including Apple account authentication, Keychain-stored credentials, provisioning API calls, code signing, URL scheme IPA installation, and the background signing daemon.

Changes touching these areas should be reviewed carefully and tested against the relevant signing and installation flows. The project does not claim compatibility with untested Apple service changes or platform updates.

### AltStore vs ReProvision
This fork of ReProvision uses the same techniques that AltStore uses to tackle provisioning, and by no means should be considered as a competitor.

### Contributing
Pull requests that add a focused feature, fix a reproducible bug, improve compatibility, or harden security-sensitive behavior are welcome. Check out the [contributing guidelines](CONTRIBUTING.md) for further information.

## Building
As long as you have standard libraries for Xcode projects, the only dependencies you need are [CocoaPods](https://github.com/CocoaPods/CocoaPods), [Git](https://git-scm.com/downloads), and [iOSOpenDev](https://github.com/Matchstic/iOSOpenDev.git). You can build the project with 3 simple steps
1. ``git clone https://github.com/bb91z/ReProvision-Reborn-Again.git``
2. ``pod install`` in the project's root directory
3. Open ``ReProvision.xcworkspace``, and roll from there

For jailbreak packages, ``THEOS=... Scripts/build-rootless.sh`` builds the rootless (``/var/jb``) ``.deb``, and ``THEOS=... Scripts/build-roothide.sh`` additionally repackages the same binaries as a roothide (``iphoneos-arm64e``) ``.deb``. Both land in ``iOS/CydiaPackages``.

## License and Third-Party Libraries
Licensed under the AGPLv3 license. Included third-party libraries are listed and credited in the [open-source notices](iOS/HTML/openSourceLicenses.html).

The software, ReProvision Reborn (and by extension, ``libReprovision`` as found in ``/Shared/``), and all consecutive copies of the software, are provided without warranty and AS-IS. **This project is NOT intended for piracy.**

Special thanks to [Matchstic](https://github.com/Matchstic) for originally developing ReProvision, and [rileytestut](https://github.com/rileytestut) for his amazing work on AltStore.
