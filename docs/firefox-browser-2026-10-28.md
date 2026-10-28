# Firefox Guest Integration

## Package Selection

Firefox is the full-featured browser; NetSurf remains installed. Firefox was
chosen for its smaller Alpine aarch64 package footprint, not a measured runtime
RAM advantage. The evaluated edge packages reported 243.0 MiB for Firefox and
296.2 MiB for Chromium, excluding their dependency closures.

Sources: [Alpine Firefox](https://pkgs.alpinelinux.org/package/edge/community/aarch64/firefox)
and [Alpine Chromium](https://pkgs.alpinelinux.org/package/edge/community/aarch64/chromium).

The installed compatible version is **151.0.3-r0 from Alpine v3.24/community**.
The current edge browser/codec combination requires a different x265 SONAME
than Pinecone's pinned platform. The build prefers the stable repository for
Firefox, FFmpeg's codec library and its libvpx ABI, without replacing the
custom graphics stack or removing `.pinecone-platform` constraints. Existing
edge main/community repositories remain; stable community is tagged `@browser`.
This is not a claim that 151 is the newest upstream version. Future browser
updates need the same dependency and runtime checks.

## Runtime Configuration

- `pinecone-launch-firefox` runs in the Phosh Wayland session, with the guest
  Wayland input method, a persistent `/root/.mozilla/pinecone` profile, and an
  HTTPS example page by default. URL arguments cannot become browser options.
- First launch seeds software WebRender and suppresses the welcome/new-tab
  workload and speculative content-process prelaunch. Existing preferences
  are not overwritten. JavaScript and site isolation are not disabled.
- The kernel now enables namespaces (including user/PID/network namespaces)
  and seccomp filters. The launcher refuses kernels missing the prerequisites.
  This does not establish that every Firefox sandbox layer is effective.
- The desktop still runs as root. Treat it as a development guest, not an
  isolated browser for untrusted sites or sensitive accounts. A separate
  unprivileged desktop/browser identity remains security work.
- Real-device RAM defaults were not raised. Simulator testing uses its existing
  1 GiB configuration; no iPhone performance or memory claim is made.

## Build And Migration

Fresh images include Firefox, its launcher/desktop entry, repository, and dock
default. Existing user favorites are not overwritten by the offline installer.
`scripts/install-firefox-guest.sh IMAGE ROOTFS_ASSETS PIXMAN_BRIDGE` runs as root
in the Linux builder against an offline image copy, installs signed APKs under
the existing platform pins, refreshes schemas/desktop metadata and verifies
ext4. Pass a bridge rebuilt by `scripts/build-pinecone-pixman.sh`; older bridges
can deadlock with Firefox's Scudo allocator. Back up the image first.

`mke2fs -d` preserved the Mac builder's UID on `/root`, which Firefox correctly
rejected when the guest ran as root. The fresh-image build now normalizes that
directory to UID/GID 0 and mode 0700 using `scripts/fix-rootfs-home-owner.sh`.
The offline installer makes the same correction without changing home contents.

## Verification

- 20 browser packaging/launcher/image-ownership tests pass.
- 12 graphical-overlay dependency tests pass.
- The real pinned package closure validates with the new browser repository.
- Both upgraded images pass all five ext4 checks; user data is preserved.
- Simulator boots to a shell, reaches Phosh, and tap-to-unlock reaches Home.
- Initial Firefox startup exposed scalar indexed `FMUL` (`0x5fc39963`), now
  implemented in native C, including lane selection and aliased operands.
  The next run exposed `SMOV W7, V23.H[7]` (`0x0e1e2ee7`), also implemented
  natively, with tests for signed byte/halfword/word extraction, W-register
  zero-extension, XZR handling and reserved encodings. Both generic and
  threaded handlers use the same extraction helper.
- A subsequent clean-profile run reached `UADALP V0.2S, V1.4H`
  (`0x2e606820`). Native pairwise widening add now also implements signed and
  unsigned accumulation, with coverage for all widths, aliases and wraparound.
- Firefox subsequently reached scalar `FADDP D1, V1.2D` (`0x7e70d821`).
  Single/double-precision pairwise reductions now reuse the native lane-selected
  arithmetic handler, with destination/source aliasing and V31 regression tests.
- Vector `ABS V0.2S, V0.2S` (`0x0ea0b800`) was the next startup instruction.
  The native unary handler now supports scalar D and all valid vector integer
  ABS widths, preserving modular minimum-signed-value behavior and clearing
  unused destination bits. Tests cover zero, positive, negative and minimum
  signed values, aliases, V31 and reserved 1D vector encoding rejection.
- Full Swift regression suite and Release Simulator builds are rerun after
  each native instruction addition.
- Firefox then reached `SABD V1.2S, V2.2S, V1.2S` (`0x0ea17441`) on vCPU 1.
  Native absolute-difference arithmetic now covers signed/unsigned 8/16/32-bit
  vectors and the accumulating forms, with aliasing, extreme-difference and
  modular-accumulation tests.
- The next startup fault was `SSHL V4.4S, V4.4S, V7.4S` (`0x4ea74484`).
  The native variable-shift handler now supports signed vector and scalar D
  forms, including arithmetic right shifts beyond the element width and
  signed low-byte shift counts. Existing unsigned forms are preserved.
- Vector `FABD V5.4S, V5.4S, V6.4S` (`0x6ea6d4a5`) now uses the native
  absolute-difference handler alongside scalar S/D forms. Tests cover all
  supported arrangements, operand aliases, signed zero, infinity and clearing
  unused destination bits.
- `SQXTUN V0.4H, V0.4S` (`0x2e612800`) exposed saturating narrowing. Native
  SQXTUN/SQXTN/UQXTN now support scalar, vector and upper-half forms, preserve
  aliases and low halves correctly, and set cumulative FPSR.QC on saturation.
  The non-saturating NEON helper explicitly declines these decoded forms.
- Startup also exposed a Pixman interposer deadlock: Firefox's main and font
  threads waited at the address of `pinecone_lock`. Scudo can call public
  `mmap`/`munmap` while bridge bookkeeping allocates under that lock. Private
  allocator calls now use a thread-local reentrancy guard; anonymous mappings
  skip irrelevant graphics tracking. Graphics mappings still use the original
  locking and fence paths. The guard is volatile because optimized allocator
  builtins otherwise removed its intermediate state; emitted ARM64 was checked.
- Bridge regressions pass normally and with undefined-behavior traps, including
  a simulated mmap/munmap-backed allocator under the graphics lock. The optional
  upstream wlroots commit test was not run in this pass (source archive absent).

The Simulator rendered Firefox's actual window and the HTTPS Example Domain
page. The inspected isolated content process reported `Seccomp: 2` with one
filter, and outbound port-443 sockets were established. First startup and page
rendering took minutes under emulation; this is not a responsiveness claim.

Address-bar tapping selected the URL, then a secondary-vCPU fault exposed
`ORR V1.4S, #255, LSL #16` (`0x4f0757e1`). The logical-immediate handler already
supported it, but the earlier SHL decoder rejected the shared encoding when
immh was zero. SHL now excludes modified immediates; tests decode all 6,144
ORR/BIC immediate combinations and execute the exact failing form. After that
fix the HTTPS page rendered again, Squeekboard appeared, and its touch keys
successfully entered `example.org` in Firefox. Plain HTTP navigation to that
address timed out; general HTTP connectivity is not verified by this test.

A later interaction exposed `SQSHRN V0.4H, V0.4S, #14` (`0x0f129400`). The
native saturating-narrow path now also implements shifted and rounded signed,
unsigned and signed-to-unsigned forms. Wide intermediates preserve rounding
carry before saturation; scalar/vector/upper-half, aliasing and QC tests cover
all source widths. Final retest after this addition passed Phosh boot,
tap-to-unlock, Firefox window creation, HTTPS Example Domain rendering,
address-bar focus and Squeekboard display. The final observed native counter
exceeded 7.2 billion with zero fallbacks. Firefox is left open in the Simulator.

Final core regression suite: 663 tests, zero failures. Release Simulator build
and installation pass. Browser startup, input-method appearance and typing
remain slow; HTTP timeout handling/network behavior and real-device memory
validation remain open. This smoke test does not establish arbitrary-site or
complete ARM64 instruction coverage.

The existing parallel-exclusive-spinlock test intermittently reported zero
observed contention during concurrent builds; full reruns without compiler
load passed. This scheduling-sensitive test remains a separate test-quality
issue, not evidence that every possible browser instruction is implemented.
