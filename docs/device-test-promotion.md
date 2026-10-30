# Current Physical-Device Test Build

Promoted at the user's request on 2026-10-29. This is a test configuration,
not a claim that the UI latency or rendering acceptance gates are complete.

## Defaults

- iOS primary and secondary backends enable the precompiled assembly subset.
  Other instructions remain in the established native C executor. Swift
  fallback remains prohibited by the app's native-only policy.
- Two parallel vCPUs. Physical-device guest RAM remains 384 MiB; Simulator
  default remains 1024 MiB.
- Service/bounded chaining, older threaded execution/memory experiments, and
  profiling remain off by default. Explicit diagnostic environment overrides
  remain available; no executor environment is needed for normal app launches.
- Rootfs staging defaults to musl r10 and includes the scoped Phosh icon-shadow
  removal. `PINECONE_MUSL_PACKAGE_VERSION=1.2.6-r8` selects the previous loader
  package for comparison builds.

## Built And Verified

- Full Alpine/Phosh rootfs rebuilt with verified package registration and caches,
  not an unregistered loader replacement. Image: 1488 MiB; staged files: 1096 MiB.
- Rootfs SHA-256:
  `691ab2cac8380fe017f3d54130b1e6985eadbcfa63605adfb4d498fcf0bde642`.
- Verified the image's APK database and platform pin select `musl=1.2.6-r10`,
  its loader matches the signed r10 package, and its GTK CSS matches the source.
- Release iPhoneOS build succeeded with the project's existing signing team;
  strict signature verification passed. Bundle ID: `me.gmoran.pinecone`.
  Verified actual embedded rootfs bytes and the bundled checksum.
- Nine native assembly integration tests passed with the ordinary macOS default,
  and nine with assembly explicitly enabled. Fourteen overlay-selection tests
  passed, including the explicit r8 comparison and invalid-version rejection.
- Simulator boot at 384 MiB reached shell and Phosh, then accepted tap-to-unlock
  and rendered Home. Both vCPUs reported assembly enabled, chaining off, and
  zero fallback at readiness. No executor-selection override was supplied.
  This is a smoke test under competing host load, not a timing benchmark.

## Disk Preservation

The previous implementation named a backup in `FileManager.replaceItemAt` but
omitted `.withoutDeletingBackupItem`, so Foundation deleted it after replacement.
The app now explicitly retains `rootfs.previous.ext4`.

Regression verified the actual Simulator app path: cleanly stopped its guest,
added a marker file to the disposable disk, changed its stored image fingerprint,
installed the corrected build, and launched it. The previous disk remained with
the marker intact, the current fingerprint matched the new image, and Linux
booted the new disk. Only one previous image is retained; uninstalling the app
removes its data. No physical-device data or original user VM disk was modified.

## Handoff

Device app:
`Apps/iOS/MobileOSHost/.DerivedData-device/Build/Products/Release-iphoneos/Pinecone.app`.
Open `Apps/iOS/MobileOSHost/MobileOSHost.xcodeproj`, select the MobileOSHost
scheme, Release, and the iPhone, then Run. Both registered physical devices were
unavailable, so on-device launch and performance have not been verified here.
The Simulator build is installed on C20024A2-E866-468D-BDC6-C44E6F01E0A3.

Known limitations remain: slow interactions and intermittent missing Settings
title bar, also observed on the previous runtime. See
`docs/phosh-graphics-priority-profile.md` for the measured gains and limitations.
