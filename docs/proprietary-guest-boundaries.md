# Proprietary Guest Boundaries

This repository does not provide instructions, tools, or materials for booting
any proprietary mobile operating system. It also does not provide or request OS
images, IPSWs, firmware blobs, boot ROM code, device keys, certificates, SEP
secrets, activation material, attestation bypasses, APNs/iMessage integration,
or service impersonation.

At a high level, any lawful proprietary mobile OS guest effort would need to
account for these component categories:

- Legal right to use the guest operating system in a virtualized environment.
- Lawfully obtained guest OS image and update materials.
- Lawfully obtained boot chain materials required by that OS and license.
- A compatible virtual hardware contract for CPU, memory, interrupts, timers,
  storage, display, input, and networking.
- Guest-specific boot configuration metadata and kernel command-line policy.
- Device tree, ACPI, or equivalent platform description expected by the guest.
- Peripheral models for every device the guest requires during boot and use.
- Secure storage or trusted-execution abstractions if the guest requires them.
- Legitimately provisioned identity, entitlement, activation, or service
  credentials when required by license and service terms.
- Compliance review for redistribution, logging, telemetry, privacy, and export
  constraints.

This document intentionally does not explain how to obtain, extract, bypass, or
substitute any protected material or service.

## Repository Enforcement

The codebase includes a `BoundaryOnlyProprietaryGuestAdapter` and
`ProprietaryGuestManifest` validator. This is a policy boundary, not a boot
path. It can record a lawful research purpose and high-level metadata for
non-restricted materials, but it refuses categories that this repository does
not handle:

- IPSW archives or proprietary OS images.
- Firmware blobs.
- Boot ROM or proprietary bootloader code.
- Device keys, certificates, SEP secrets, activation material, or attestation
  material.
- External service access for proprietary mobile ecosystems.

The default policy file is `arm64viz.preferences.json`. It keeps
`boundaryMode` set to `metadataOnly`, requires research purpose and
authorization metadata, denies external service access, and denies known
restricted material categories and package identifiers. The loader rejects
preference files that try to remove the built-in restricted material kinds,
denied package suffixes, denied metadata terms, or external-service block.

Validate a metadata-only manifest with:

```sh
swift run arm64viz validate-manifest examples/research-guest-manifest.json --preferences arm64viz.preferences.json
```

Inspect the effective preferences with:

```sh
swift run arm64viz policy-show --preferences arm64viz.preferences.json
```

The validator does not read, extract, decrypt, or boot proprietary packages.

## Drag-And-Drop UI

`ui/boot-lab.html` is a local static UI for staging boot artifacts. It uses
browser file metadata only: file name and size. It does not upload files and
does not read boot-image contents. The UI mirrors the same conservative
classification rules used by `BootArtifactClassifier`, including restricted
package suffix checks.
