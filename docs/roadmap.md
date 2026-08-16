# Roadmap

## Milestone 1: Dependency-Free Toy Guest

- Pure Swift package with no runtime dependency on QEMU.
- Software AArch64 backend with a small instruction subset.
- RAM, MMIO bus, UART, framebuffer, touch, block, network, interrupt, snapshot,
  and boot configuration abstractions.
- Toy guest boot adapter that emits text over virtual UART.

## Milestone 2: Emulator Fidelity

- Keep the proprietary guest boundary in metadata-only mode while generic VM
  capabilities are developed and tested against open guests.
- Keep the JavaScript MobileOS track disabled as archived reference code.
- Add decode/execute coverage for more AArch64 integer, branch, load/store, and
  system instructions.
- Extend the implemented exception levels, vector routing, banked timer state,
  PSCI v1.1 CPU lifecycle, and cooperative SMP scheduler toward host-parallel
  vCPU execution after memory and MMIO synchronization is complete.
- Harden binary FDT generation and Linux handoff validation.
- Expand the initial instruction trace support with memory watchpoints and
  coverage maps.

## Milestone 3: Open Linux Bring-Up

- Extend the native Linux `Image` boot adapter from artifact preparation to
  first-instruction execution of legally obtained open-source kernels.
- Expand the initial synchronous exception, IRQ, GIC-style, timer,
  system-register, and MMU support into Linux-grade priority/nesting behavior,
  attribute checks, TLB maintenance, PL011 FIFO/control fidelity, and virtio
  descriptor-ring execution for block, network, input, and display behavior.
- Keep firmware-free direct kernel boot as the first Linux target.
- Add conformance tests that compare architectural state against documented ARM
  behavior.

## Milestone 4: Acceleration Backends

- Add an HVF backend for macOS hosts.
- Add a KVM backend for Linux hosts.
- Keep the existing software backend as the deterministic debug backend.
- Preserve backend-independent device models and snapshot metadata.

## Milestone 5: Research Tooling

- Policy report export and immutable audit summaries for guest-adapter review.
- Linux handoff reports, FDT inspection, and deterministic boot-trace replay.
- Deterministic replay.
- Snapshot diffing.
- Device trace export.
- MMIO fuzz harnesses for open device models.
- Debug adapter protocol bridge for source-level and register-level inspection.

## Optional QEMU Role

QEMU is not a dependency. It can optionally be used outside the framework as a
comparison target for open Linux or toy-guest behavior once equivalent device
models exist.
