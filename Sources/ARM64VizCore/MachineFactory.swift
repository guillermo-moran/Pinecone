public enum ARM64VizMachineLayout {
    public static let ramBase: GuestAddress = 0x4000_0000
    public static let ramSize: Int = 64 * 1024 * 1024
    public static let toyEntryPoint: GuestAddress = ramBase + 0x0008_0000

    public static let gicBase: GuestAddress = 0x0800_0000
    public static let virtioBlockBase: GuestAddress = 0x0a00_0000
    public static let virtioNetworkBase: GuestAddress = 0x0a00_1000
    public static let virtioInputBase: GuestAddress = 0x0a00_2000
    public static let virtioDisplayBase: GuestAddress = 0x0a00_3000
    public static let virtioKeyboardBase: GuestAddress = 0x0a00_4000
    public static let virtioSecondaryBlockBase: GuestAddress = 0x0a00_5000
    public static let pciECAMBase: GuestAddress = 0x3000_0000
    public static let pciECAMSize: UInt64 = 0x0010_0000
    public static let pciMMIOBase: GuestAddress = 0x3100_0000
    public static let pciMMIOSize: UInt64 = 0x0100_0000
    public static let virtioPCIBarSize: UInt64 = 0x0000_4000
    public static let uartBase: GuestAddress = 0x0900_0000
    public static let framebufferBase: GuestAddress = 0x1000_0000
    public static let framebufferWidth = 480
    public static let framebufferHeight = 1024
    public static let framebufferBytesPerPixel = 4
    public static let touchBase: GuestAddress = 0x101e_0000
    public static let blockBase: GuestAddress = 0x1020_0000
    public static let networkBase: GuestAddress = 0x1031_0000
}

public struct ResearchMachine {
    public let vm: VirtualMachine
    public let gic: VirtualGIC
    public let uart: VirtualUART
    public let virtioBlock: VirtualVirtIODevice
    public let virtioSecondaryBlock: VirtualVirtIODevice?
    public let virtioNetwork: VirtualVirtIODevice
    public let virtioInput: VirtualVirtIODevice
    public let virtioDisplay: VirtualVirtIODevice
    public let virtioKeyboard: VirtualVirtIODevice
    public let pciHost: VirtualPCIExpressHost?
    public let virtioPCITransports: [VirtIOPCIModernTransport]
    public let framebuffer: VirtualFramebuffer
    public let touch: VirtualTouchInput
    public let block: VirtualBlockDevice
    public let network: VirtualNetworkDevice
    public let parallelVCPUCluster: ParallelVCPUCluster?

    public init(
        vm: VirtualMachine,
        gic: VirtualGIC,
        uart: VirtualUART,
        virtioBlock: VirtualVirtIODevice,
        virtioSecondaryBlock: VirtualVirtIODevice? = nil,
        virtioNetwork: VirtualVirtIODevice,
        virtioInput: VirtualVirtIODevice,
        virtioDisplay: VirtualVirtIODevice,
        virtioKeyboard: VirtualVirtIODevice,
        pciHost: VirtualPCIExpressHost? = nil,
        virtioPCITransports: [VirtIOPCIModernTransport] = [],
        framebuffer: VirtualFramebuffer,
        touch: VirtualTouchInput,
        block: VirtualBlockDevice,
        network: VirtualNetworkDevice,
        parallelVCPUCluster: ParallelVCPUCluster? = nil
    ) {
        self.vm = vm
        self.gic = gic
        self.uart = uart
        self.virtioBlock = virtioBlock
        self.virtioSecondaryBlock = virtioSecondaryBlock
        self.virtioNetwork = virtioNetwork
        self.virtioInput = virtioInput
        self.virtioDisplay = virtioDisplay
        self.virtioKeyboard = virtioKeyboard
        self.pciHost = pciHost
        self.virtioPCITransports = virtioPCITransports
        self.framebuffer = framebuffer
        self.touch = touch
        self.block = block
        self.network = network
        self.parallelVCPUCluster = parallelVCPUCluster
    }
}

public enum ResearchMachineDevicePublication: Equatable {
    case full
    case linuxConsole
}

public enum ResearchMachineVirtIOTransport: Equatable {
    case mmio
    case pci
}

public enum MachineFactory {
    public static func makeResearchMachine(
        memorySize: Int = ARM64VizMachineLayout.ramSize,
        blockStorageSize: Int = 1024 * 1024,
        blockStorage: VirtIOBlockStorage? = nil,
        secondaryBlockStorage: VirtIOBlockStorage? = nil,
        backend: VirtualMachineBackend = SoftwareARM64Backend(),
        virtualCPUCount: Int = 1,
        parallelVCPUExecution: Bool = false,
        parallelCounterTicksPerHostSecond: UInt32 = 24_000_000,
        parallelActiveCounterTicksPerHostSecond: UInt32 = 24_000_000,
        virtioTransport: ResearchMachineVirtIOTransport = .mmio,
        enableVirGL: Bool = false,
        publishedDevices: ResearchMachineDevicePublication = .full
    ) throws -> ResearchMachine {
        let memory = PhysicalMemory(base: ARM64VizMachineLayout.ramBase, size: memorySize)
        let interruptController = SimpleInterruptController()
        let vm = VirtualMachine(
            memory: memory,
            interruptController: interruptController,
            backend: backend,
            virtualCPUCount: virtualCPUCount
        )

        let gic = VirtualGIC(
            base: ARM64VizMachineLayout.gicBase,
            interruptController: interruptController,
            virtualCPUCount: virtualCPUCount
        )
        gic.setCurrentVCPUIDProvider { [weak mmio = vm.mmio] in
            mmio?.currentVCPUID ?? 0
        }
        let uart = VirtualUART(
            base: ARM64VizMachineLayout.uartBase,
            interruptLine: 33,
            interruptController: interruptController
        )
        let virtioBlock = VirtualVirtIODevice(
            name: "virtio_mmio0",
            kind: .block,
            base: ARM64VizMachineLayout.virtioBlockBase,
            interruptLine: 68,
            interruptController: interruptController,
            memory: memory,
            storageSize: blockStorageSize,
            blockStorage: blockStorage
        )
        let virtioNetwork = VirtualVirtIODevice(
            name: "virtio_mmio1",
            kind: .network,
            base: ARM64VizMachineLayout.virtioNetworkBase,
            interruptLine: 69,
            interruptController: interruptController,
            memory: memory
        )
        let virtioInput = VirtualVirtIODevice(
            name: "virtio_mmio2",
            kind: .input,
            base: ARM64VizMachineLayout.virtioInputBase,
            interruptLine: 70,
            interruptController: interruptController,
            memory: memory,
            inputMaximumX: UInt32(ARM64VizMachineLayout.framebufferWidth - 1),
            inputMaximumY: UInt32(ARM64VizMachineLayout.framebufferHeight - 1)
        )
        let virtioDisplay = VirtualVirtIODevice(
            name: "virtio_mmio3",
            kind: .gpu,
            base: ARM64VizMachineLayout.virtioDisplayBase,
            interruptLine: 71,
            interruptController: interruptController,
            memory: memory,
            displayWidth: ARM64VizMachineLayout.framebufferWidth,
            displayHeight: ARM64VizMachineLayout.framebufferHeight,
            enableVirGL: enableVirGL
        )
        let virtioKeyboard = VirtualVirtIODevice(
            name: "virtio_mmio4",
            kind: .input,
            base: ARM64VizMachineLayout.virtioKeyboardBase,
            interruptLine: 72,
            interruptController: interruptController,
            memory: memory,
            inputRole: .keyboard
        )
        let virtioSecondaryBlock = secondaryBlockStorage.map { storage in
            VirtualVirtIODevice(
                name: "virtio_mmio5",
                kind: .block,
                base: ARM64VizMachineLayout.virtioSecondaryBlockBase,
                interruptLine: 73,
                interruptController: interruptController,
                memory: memory,
                storageSize: storage.count,
                blockStorage: storage
            )
        }
        let pciHost: VirtualPCIExpressHost?
        let virtioPCITransports: [VirtIOPCIModernTransport]
        if virtioTransport == .pci {
            let host = VirtualPCIExpressHost(
                base: ARM64VizMachineLayout.pciECAMBase,
                length: ARM64VizMachineLayout.pciECAMSize
            )
            var devices: [(slot: UInt8, device: VirtualVirtIODevice)] = [
                (1, virtioBlock),
                (3, virtioNetwork),
                (4, virtioInput),
                (5, virtioDisplay),
                (6, virtioKeyboard)
            ]
            if let virtioSecondaryBlock {
                devices.append((2, virtioSecondaryBlock))
            }
            var transports: [VirtIOPCIModernTransport] = []
            for entry in devices.sorted(by: { $0.slot < $1.slot }) {
                let barBase = ARM64VizMachineLayout.pciMMIOBase
                    + UInt64(entry.slot - 1) * ARM64VizMachineLayout.virtioPCIBarSize
                let transport = VirtIOPCIModernTransport(
                    name: "virtio_pci\(entry.slot)",
                    base: barBase,
                    device: entry.device
                )
                let endpoint = VirtIOPCIEndpoint(
                    deviceNumber: entry.slot,
                    barAddress: barBase,
                    barSize: UInt32(ARM64VizMachineLayout.virtioPCIBarSize),
                    transport: transport
                )
                host.addEndpoint(endpoint)
                transports.append(transport)
            }
            pciHost = host
            virtioPCITransports = transports
        } else {
            pciHost = nil
            virtioPCITransports = []
        }
        let framebuffer = VirtualFramebuffer(
            base: ARM64VizMachineLayout.framebufferBase,
            width: ARM64VizMachineLayout.framebufferWidth,
            height: ARM64VizMachineLayout.framebufferHeight,
            bytesPerPixel: ARM64VizMachineLayout.framebufferBytesPerPixel
        )
        let touch = VirtualTouchInput(base: ARM64VizMachineLayout.touchBase)
        let block = VirtualBlockDevice(
            base: ARM64VizMachineLayout.blockBase,
            storageSize: min(blockStorageSize, 1024 * 1024)
        )
        let network = VirtualNetworkDevice(base: ARM64VizMachineLayout.networkBase)

        try vm.mmio.register(gic)
        try vm.mmio.register(uart)
        try vm.mmio.register(virtioBlock)
        try vm.mmio.register(virtioNetwork)
        try vm.mmio.register(virtioInput)
        try vm.mmio.register(virtioDisplay)
        try vm.mmio.register(virtioKeyboard)
        if let virtioSecondaryBlock {
            try vm.mmio.register(virtioSecondaryBlock)
        }
        if let pciHost {
            try vm.mmio.register(pciHost)
            for transport in virtioPCITransports {
                try vm.mmio.register(transport)
            }
        }
        try vm.mmio.register(framebuffer)
        try vm.mmio.register(touch)
        try vm.mmio.register(block)
        try vm.mmio.register(network)

        let requiredLinuxDevices = [
            BootDeviceDescriptor(
                name: "intc",
                compatible: ["arm,gic-400", "arm,cortex-a15-gic"],
                base: gic.range.start,
                size: gic.range.length,
                registerRanges: [
                    BootRegisterRange(base: gic.range.start, size: gic.cpuInterfaceOffset),
                    BootRegisterRange(
                        base: gic.range.start + gic.cpuInterfaceOffset,
                        size: gic.range.length - gic.cpuInterfaceOffset
                    )
                ],
                properties: [
                    "#interrupt-cells": "<3>",
                    "interrupt-controller": "",
                    "phandle": "<1>",
                    "linux,phandle": "<1>"
                ]
            ),
            BootDeviceDescriptor(
                name: "timer",
                compatible: ["arm,armv8-timer"],
                base: 0,
                size: 0,
                interrupts: [
                    1, 13, 4,
                    1, 14, 4,
                    1, 11, 4,
                    1, 10, 4
                ],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: "uart0",
                compatible: ["arm,pl011", "arm,primecell"],
                base: uart.range.start,
                size: uart.range.length,
                interrupts: [0, 1, 4],
                properties: [
                    "clock-frequency": "<24000000>",
                    "clock-names": "\"uartclk\", \"apb_pclk\"",
                    "clocks": "<2 2>",
                    "interrupt-parent": "<1>"
                ]
            )
        ]

        let optionalResearchDevices = [
            BootDeviceDescriptor(
                name: virtioBlock.name,
                compatible: ["virtio,mmio"],
                base: virtioBlock.range.start,
                size: virtioBlock.range.length,
                interrupts: [0, 36, 4],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: virtioNetwork.name,
                compatible: ["virtio,mmio"],
                base: virtioNetwork.range.start,
                size: virtioNetwork.range.length,
                interrupts: [0, 37, 4],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: virtioInput.name,
                compatible: ["virtio,mmio"],
                base: virtioInput.range.start,
                size: virtioInput.range.length,
                interrupts: [0, 38, 4],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: virtioDisplay.name,
                compatible: ["virtio,mmio"],
                base: virtioDisplay.range.start,
                size: virtioDisplay.range.length,
                interrupts: [0, 39, 4],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: virtioKeyboard.name,
                compatible: ["virtio,mmio"],
                base: virtioKeyboard.range.start,
                size: virtioKeyboard.range.length,
                interrupts: [0, 40, 4],
                properties: ["interrupt-parent": "<1>"]
            ),
            BootDeviceDescriptor(
                name: "touch0",
                compatible: ["arm64viz,touch"],
                base: touch.range.start,
                size: touch.range.length
            ),
            BootDeviceDescriptor(
                name: "block0",
                compatible: ["arm64viz,block"],
                base: block.range.start,
                size: block.range.length,
                interrupts: [0, 2, 4],
                properties: [
                    "block-size": "<\(block.blockSize)>",
                    "interrupt-parent": "<1>"
                ]
            ),
            BootDeviceDescriptor(
                name: "net0",
                compatible: ["arm64viz,net"],
                base: network.range.start,
                size: network.range.length,
                interrupts: [0, 3, 4],
                properties: ["interrupt-parent": "<1>"]
            )
        ]
        let secondaryBlockDevices = virtioSecondaryBlock.map { device in
            [
                BootDeviceDescriptor(
                    name: device.name,
                    compatible: ["virtio,mmio"],
                    base: device.range.start,
                    size: device.range.length,
                    interrupts: [0, 41, 4],
                    properties: ["interrupt-parent": "<1>"]
                )
            ]
        } ?? []
        let pciHostDevice = pciHost.map { host in
            BootDeviceDescriptor(
                name: "pcie",
                compatible: ["pci-host-ecam-generic"],
                base: host.range.start,
                size: host.range.length,
                properties: [
                    "#address-cells": "<3>",
                    "#interrupt-cells": "<1>",
                    "#size-cells": "<2>",
                    "bus-range": "<0 0>",
                    "device_type": "\"pci\"",
                    "dma-coherent": "",
                    "interrupt-map-mask": "<0xf800 0 0 7>",
                    "interrupt-map": pciInterruptMap(hasSecondaryBlock: virtioSecondaryBlock != nil),
                    "linux,pci-domain": "<0>",
                    "ranges": "<0x02000000 0 0x31000000 0 0x31000000 0 0x01000000>"
                ]
            )
        }
        switch publishedDevices {
        case .full:
            if let pciHostDevice {
                vm.bootDevices = requiredLinuxDevices
                    + optionalResearchDevices.filter { !$0.name.hasPrefix("virtio_mmio") }
                    + [pciHostDevice]
            } else {
                vm.bootDevices = requiredLinuxDevices + optionalResearchDevices + secondaryBlockDevices
            }
        case .linuxConsole:
            vm.bootDevices = requiredLinuxDevices
        }

        let parallelVCPUCluster = parallelVCPUExecution && virtualCPUCount > 1
            ? ParallelVCPUCluster(
                primary: vm,
                counterTicksPerHostSecond: parallelCounterTicksPerHostSecond,
                activeCounterTicksPerHostSecond:
                    parallelActiveCounterTicksPerHostSecond
            )
            : nil

        return ResearchMachine(
            vm: vm,
            gic: gic,
            uart: uart,
            virtioBlock: virtioBlock,
            virtioSecondaryBlock: virtioSecondaryBlock,
            virtioNetwork: virtioNetwork,
            virtioInput: virtioInput,
            virtioDisplay: virtioDisplay,
            virtioKeyboard: virtioKeyboard,
            pciHost: pciHost,
            virtioPCITransports: virtioPCITransports,
            framebuffer: framebuffer,
            touch: touch,
            block: block,
            network: network,
            parallelVCPUCluster: parallelVCPUCluster
        )
    }

    private static func pciInterruptMap(hasSecondaryBlock: Bool) -> String {
        var entries: [(slot: UInt32, spi: UInt32)] = [
            (1, 36),
            (3, 37),
            (4, 38),
            (5, 39),
            (6, 40)
        ]
        if hasSecondaryBlock {
            entries.append((2, 41))
        }
        let cells = entries.sorted(by: { $0.slot < $1.slot }).reduce(into: [UInt32]()) { result, entry in
            result.append(contentsOf: [entry.slot << 11, 0, 0, 1, 1, 0, entry.spi, 4])
        }
        return "<\(cells.map(String.init).joined(separator: " "))>"
    }
}
