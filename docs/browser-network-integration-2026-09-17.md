# Phosh Browser and Networking

## Implementation

- Bundle Alpine/aarch64 NetSurf GTK3 and CA certificates in the Phosh image.
  Preserve existing package pins while resolving newly requested dependencies.
- Add a Wayland launcher, persistent NetSurf choices, app-grid entry, and favorite.
- Keep early static Ethernet available; start NetworkManager through system
  D-Bus when Phosh starts. Serialize configuration ownership with a boot-local
  lock and adopt the matching static `Pinecone Internet` profile.
- Include Alpine's separate D-Bus activation helper, restoring its required
  root:messagebus ownership and 4750 mode before activation.
- Coldplug the net subsystem after udev starts. NetworkManager reports reason
  71 for links without udev initialization; a configured address alone is not
  sufficient. See [NetworkManager state reasons](https://www.networkmanager.dev/docs/api/latest/nm-dbus-types.html).
- Remove cloud-network discovery hooks from this non-cloud static guest.
- Keep diagnostic status available through the NetworkManager D-Bus API without
  requiring the optional `nmcli` package or upgrading pinned libraries.
- Stop fabricating gateway DNS answers on resolution failure and stop redirecting
  Alpine's public hostname to an HTTP-only proxy. The explicit gateway package
  proxy remains available. Clean up host sockets when the guest resets TCP flows.

## Validation

- 531 Swift tests passed, including 16 focused networking tests.
- 15 browser packaging/launcher tests passed.
- 19 network ownership tests and the C session-launcher tests passed.
- Release Simulator build and rootfs filesystem validation passed.
- Live guest resolved public DNS and downloaded a valid HTTPS page; an expired
  certificate was rejected, with no TLS-verification bypass.
- NetSurf rendered Example Domain and followed its link to IANA over HTTPS.
- NetworkManager reported Ethernet managed/connected (state 100), and a further
  HTTPS download succeeded after ownership transfer.
- Simulator testing used two native vCPUs, with zero observed fallback instructions.

Two final-image boots emitted early ext4 buddy/bitmap warnings before the Phosh
command. The pristine image passed `e2fsck -fn` and exactly matched the bundled
SHA-256. The stopped runtime disk and UART are preserved at
`/tmp/pinecone-network-fs-warning.ext4` and
`/tmp/pinecone-network-fs-warning-uart.log`. Journal-only recovery on a separate
diagnostic copy removed bitmap/inode discrepancies; free-count summary differences
remained. This does not establish the runtime warning's cause or a storage fix.
The second boot explicitly reseeded the pristine image and reproduced the warning.
It nevertheless reached unlocked Phosh, automatically reported managed/connected
Ethernet, and rendered Example Domain in NetSurf. Evidence:
`/tmp/pinecone-browser-final.png`, `/tmp/pinecone-browser-final-uart.log`, and
`/tmp/pinecone-browser-final-metrics.json`.

The focused read-only audit found bitmap blocks 159-161 byte-identical in the
pristine and stopped warned disks. Each kernel warning count matches treating
bits 0-895 as allocated. Linux then subtracts the groups' free clusters after
marking them corrupt, exactly explaining the 19504 superblock summary value.
The offending runtime operation is not proven. Instrumenting those three block
reads and the ext4 bitmap memcpy is the next bounded diagnostic; the native
memcpy accelerator is a candidate, not a confirmed cause. No filesystem-geometry
workaround or unrelated CPU change was made to hide this warning.

## Boundaries

This is an initial connectivity browser, not a modern web-app compatibility
promise. JavaScript defaults off. NetSurf has no renderer sandbox, and the demo
desktop runs as root: use trusted pages only and do not enter sensitive credentials.
No package-manager UI, browser-performance tuning, CPU decoder, or graphics
pipeline changes are part of this work. The custom IPv4 bridge is not a complete
replacement for a mature virtual network stack. Physical-device Wi-Fi/cellular
handover was not tested; this verification used the iOS Simulator.
