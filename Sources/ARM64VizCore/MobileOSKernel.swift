import Foundation

public typealias MobileOSProcessID = UInt32

public enum MobileOSProcessKind: String, Codable, Equatable {
    case kernel
    case systemService
    case app
}

public enum MobileOSProcessState: String, Codable, Equatable {
    case ready
    case running
    case waiting
    case stopped
}

public struct MobileOSProcess: Codable, Equatable {
    public let pid: MobileOSProcessID
    public let name: String
    public let kind: MobileOSProcessKind
    public var state: MobileOSProcessState
    public var mailbox: [MobileOSMessage]
    public var ticksRun: UInt64

    public init(
        pid: MobileOSProcessID,
        name: String,
        kind: MobileOSProcessKind,
        state: MobileOSProcessState = .ready,
        mailbox: [MobileOSMessage] = [],
        ticksRun: UInt64 = 0
    ) {
        self.pid = pid
        self.name = name
        self.kind = kind
        self.state = state
        self.mailbox = mailbox
        self.ticksRun = ticksRun
    }
}

public struct MobileOSMessage: Codable, Equatable {
    public let from: MobileOSProcessID
    public let to: MobileOSProcessID
    public let topic: String
    public let payload: String

    public init(from: MobileOSProcessID, to: MobileOSProcessID, topic: String, payload: String) {
        self.from = from
        self.to = to
        self.topic = topic
        self.payload = payload
    }
}

public final class MobileOSScheduler {
    private var nextPID: MobileOSProcessID = 1
    private var processes: [MobileOSProcessID: MobileOSProcess] = [:]
    private var runQueue: [MobileOSProcessID] = []
    private var currentPID: MobileOSProcessID?

    public init() {}

    public var allProcesses: [MobileOSProcess] {
        processes.values.sorted { $0.pid < $1.pid }
    }

    public var currentProcess: MobileOSProcess? {
        currentPID.flatMap { processes[$0] }
    }

    @discardableResult
    public func spawn(name: String, kind: MobileOSProcessKind) -> MobileOSProcessID {
        let pid = nextPID
        nextPID += 1
        processes[pid] = MobileOSProcess(pid: pid, name: name, kind: kind)
        runQueue.append(pid)
        return pid
    }

    public func send(_ message: MobileOSMessage) throws {
        guard var target = processes[message.to] else {
            throw VMError.deviceError("unknown MobileOS target pid \(message.to)")
        }
        target.mailbox.append(message)
        if target.state == .waiting {
            target.state = .ready
            runQueue.append(target.pid)
        }
        processes[target.pid] = target
    }

    public func receive(pid: MobileOSProcessID) throws -> MobileOSMessage? {
        guard var process = processes[pid] else {
            throw VMError.deviceError("unknown MobileOS pid \(pid)")
        }
        guard !process.mailbox.isEmpty else {
            process.state = .waiting
            processes[pid] = process
            runQueue.removeAll { $0 == pid }
            return nil
        }
        let message = process.mailbox.removeFirst()
        processes[pid] = process
        return message
    }

    @discardableResult
    public func tick() -> MobileOSProcess? {
        if let currentPID, var current = processes[currentPID], current.state == .running {
            current.state = .ready
            processes[currentPID] = current
            runQueue.append(currentPID)
        }

        while !runQueue.isEmpty {
            let pid = runQueue.removeFirst()
            guard var next = processes[pid], next.state == .ready else {
                continue
            }
            next.state = .running
            next.ticksRun += 1
            processes[pid] = next
            currentPID = pid
            return next
        }

        currentPID = nil
        return nil
    }

    public func stop(pid: MobileOSProcessID) throws {
        guard var process = processes[pid] else {
            throw VMError.deviceError("unknown MobileOS pid \(pid)")
        }
        process.state = .stopped
        processes[pid] = process
        runQueue.removeAll { $0 == pid }
        if currentPID == pid {
            currentPID = nil
        }
    }
}

public struct MobileOSAppManifest: Codable, Equatable {
    public let identifier: String
    public let displayName: String
    public let entryPoint: String
    public let permissions: [String]

    public init(
        identifier: String,
        displayName: String,
        entryPoint: String,
        permissions: [String] = []
    ) {
        self.identifier = identifier
        self.displayName = displayName
        self.entryPoint = entryPoint
        self.permissions = permissions
    }

    public static var builtInApps: [MobileOSAppManifest] {
        [
            MobileOSAppManifest(
                identifier: "dev.arm64viz.mail",
                displayName: "Mail",
                entryPoint: "mail.app.js",
                permissions: ["network.local", "storage.mail"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.browser",
                displayName: "Browser",
                entryPoint: "browser.app.js",
                permissions: ["network.local"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.settings",
                displayName: "Settings",
                entryPoint: "settings.app.js",
                permissions: ["settings.read", "settings.write"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.files",
                displayName: "Files",
                entryPoint: "files.app.js",
                permissions: ["storage.user"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.camera",
                displayName: "Camera",
                entryPoint: "camera.app.js",
                permissions: ["camera.read"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.notes",
                displayName: "Notes",
                entryPoint: "notes.app.js",
                permissions: ["storage.notes"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.console",
                displayName: "Terminal",
                entryPoint: "terminal.app.js",
                permissions: ["debug.console", "packages.manage", "unix.pty"]
            ),
            MobileOSAppManifest(
                identifier: "dev.arm64viz.store",
                displayName: "Store",
                entryPoint: "store.app.js",
                permissions: ["network.local", "packages.read"]
            )
        ]
    }
}

public struct MobileOSAppInstance: Codable, Equatable {
    public let manifest: MobileOSAppManifest
    public let pid: MobileOSProcessID
    public let surfaceID: UInt32

    public init(manifest: MobileOSAppManifest, pid: MobileOSProcessID, surfaceID: UInt32) {
        self.manifest = manifest
        self.pid = pid
        self.surfaceID = surfaceID
    }
}

public final class MobileOSAppRegistry {
    private var manifests: [String: MobileOSAppManifest] = [:]
    private var runningApps: [String: MobileOSAppInstance] = [:]

    public init() {}

    public var registeredApps: [MobileOSAppManifest] {
        manifests.values.sorted { $0.identifier < $1.identifier }
    }

    public var running: [MobileOSAppInstance] {
        runningApps.values.sorted { $0.pid < $1.pid }
    }

    public func register(_ manifest: MobileOSAppManifest) throws {
        guard manifest.identifier.contains(".") else {
            throw VMError.deviceError("app identifier must use reverse-DNS style")
        }
        guard manifest.entryPoint.hasSuffix(".js") else {
            throw VMError.deviceError("MobileOS app entry point must be JavaScript")
        }
        manifests[manifest.identifier] = manifest
    }

    @discardableResult
    public func launch(
        identifier: String,
        scheduler: MobileOSScheduler,
        compositor: MobileOSCompositor
    ) throws -> MobileOSAppInstance {
        guard let manifest = manifests[identifier] else {
            throw VMError.deviceError("unknown MobileOS app \(identifier)")
        }
        let pid = scheduler.spawn(name: manifest.displayName, kind: .app)
        let surfaceOffset = runningApps.count * 28
        let surface = compositor.createSurface(
            ownerPID: pid,
            title: manifest.displayName,
            frame: MobileOSRect(x: 32 + surfaceOffset, y: 78 + surfaceOffset, width: 300, height: 360),
            color: MobileOSColor.forIdentifier(identifier)
        )
        let instance = MobileOSAppInstance(manifest: manifest, pid: pid, surfaceID: surface.id)
        runningApps[identifier] = instance
        return instance
    }
}

public struct MobileOSRect: Codable, Equatable {
    public let x: Int
    public let y: Int
    public let width: Int
    public let height: Int

    public init(x: Int, y: Int, width: Int, height: Int) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }

    public func contains(x pointX: Int, y pointY: Int) -> Bool {
        pointX >= x && pointY >= y && pointX < x + width && pointY < y + height
    }
}

public struct MobileOSColor: Codable, Equatable {
    public let red: UInt8
    public let green: UInt8
    public let blue: UInt8
    public let alpha: UInt8

    public init(red: UInt8, green: UInt8, blue: UInt8, alpha: UInt8 = 0xff) {
        self.red = red
        self.green = green
        self.blue = blue
        self.alpha = alpha
    }

    public var argb: UInt32 {
        UInt32(alpha) << 24 | UInt32(red) << 16 | UInt32(green) << 8 | UInt32(blue)
    }

    public static func forIdentifier(_ identifier: String) -> MobileOSColor {
        let palette = [
            MobileOSColor(red: 0x25, green: 0x63, blue: 0xeb),
            MobileOSColor(red: 0x0f, green: 0x76, blue: 0x6e),
            MobileOSColor(red: 0xa1, green: 0x62, blue: 0x07),
            MobileOSColor(red: 0x47, green: 0x55, blue: 0x69)
        ]
        let index = abs(identifier.hashValue) % palette.count
        return palette[index]
    }
}

public struct MobileOSSurface: Codable, Equatable {
    public let id: UInt32
    public let ownerPID: MobileOSProcessID
    public let title: String
    public let frame: MobileOSRect
    public let color: MobileOSColor

    public init(
        id: UInt32,
        ownerPID: MobileOSProcessID,
        title: String,
        frame: MobileOSRect,
        color: MobileOSColor
    ) {
        self.id = id
        self.ownerPID = ownerPID
        self.title = title
        self.frame = frame
        self.color = color
    }
}

public struct MobileOSTouchDispatch: Codable, Equatable {
    public let event: TouchEvent
    public let targetSurfaceID: UInt32?
    public let targetPID: MobileOSProcessID?

    public init(event: TouchEvent, targetSurfaceID: UInt32?, targetPID: MobileOSProcessID?) {
        self.event = event
        self.targetSurfaceID = targetSurfaceID
        self.targetPID = targetPID
    }
}

public final class MobileOSCompositor {
    private var nextSurfaceID: UInt32 = 1
    private var surfaces: [MobileOSSurface] = []

    public init() {}

    public var orderedSurfaces: [MobileOSSurface] {
        surfaces
    }

    @discardableResult
    public func createSurface(
        ownerPID: MobileOSProcessID,
        title: String,
        frame: MobileOSRect,
        color: MobileOSColor
    ) -> MobileOSSurface {
        let surface = MobileOSSurface(
            id: nextSurfaceID,
            ownerPID: ownerPID,
            title: title,
            frame: frame,
            color: color
        )
        nextSurfaceID += 1
        surfaces.append(surface)
        return surface
    }

    public func dispatchTouch(_ event: TouchEvent) -> MobileOSTouchDispatch {
        let x = Int(event.x)
        let y = Int(event.y)
        let target = surfaces.reversed().first { $0.frame.contains(x: x, y: y) }
        return MobileOSTouchDispatch(
            event: event,
            targetSurfaceID: target?.id,
            targetPID: target?.ownerPID
        )
    }

    @discardableResult
    public func bringToFront(surfaceID: UInt32) -> MobileOSSurface? {
        guard let index = surfaces.firstIndex(where: { $0.id == surfaceID }) else {
            return nil
        }
        let surface = surfaces.remove(at: index)
        surfaces.append(surface)
        return surface
    }

    public func render(to framebuffer: VirtualFramebuffer) throws {
        try framebuffer.fill(MobileOSColor(red: 0xe1, green: 0xe8, blue: 0xef))
        for surface in surfaces {
            try framebuffer.fillRect(surface.frame, color: surface.color)
        }
    }
}

public struct MobileOSKernelReport: Codable, Equatable {
    public let bootLog: [String]
    public let processes: [MobileOSProcess]
    public let apps: [MobileOSAppInstance]
    public let surfaces: [MobileOSSurface]
    public let touchDispatch: MobileOSTouchDispatch?
    public let framebufferChecksum: UInt64
    public let unix: MobileOSUnixReport

    public init(
        bootLog: [String],
        processes: [MobileOSProcess],
        apps: [MobileOSAppInstance],
        surfaces: [MobileOSSurface],
        touchDispatch: MobileOSTouchDispatch?,
        framebufferChecksum: UInt64,
        unix: MobileOSUnixReport
    ) {
        self.bootLog = bootLog
        self.processes = processes
        self.apps = apps
        self.surfaces = surfaces
        self.touchDispatch = touchDispatch
        self.framebufferChecksum = framebufferChecksum
        self.unix = unix
    }
}

public final class MobileOSKernel {
    public let scheduler = MobileOSScheduler()
    public let appRegistry = MobileOSAppRegistry()
    public let compositor = MobileOSCompositor()
    public private(set) var unix = MobileOSUnixEnvironment()
    private var bootLog: [String] = []
    private var lastTouchDispatch: MobileOSTouchDispatch?

    public init() {}

    public func boot(on machine: ResearchMachine) throws -> MobileOSKernelReport {
        try RuntimeDirection.requireJavaScriptMobileOSEnabled(operation: "mobile-kernel-demo")
        bootLog.removeAll()
        unix = MobileOSUnixEnvironment()
        log("kernel: starting MobileOS services")

        let kernelPID = scheduler.spawn(name: "kernel", kind: .kernel)
        let compositorPID = scheduler.spawn(name: "compositor", kind: .systemService)
        let inputPID = scheduler.spawn(name: "inputd", kind: .systemService)
        let appdPID = scheduler.spawn(name: "appd", kind: .systemService)
        let unixPID = scheduler.spawn(name: "unixd", kind: .systemService)
        log("kernel: services spawned kernel=\(kernelPID) compositor=\(compositorPID) input=\(inputPID) appd=\(appdPID) unixd=\(unixPID)")

        let shell = try unix.openPTY()
        log("unixd: mounted VFS paths=\(unix.report.mountedPaths.count)")
        log("unixd: pty \(shell.devicePath) shell pid=\(shell.foregroundPID)")
        log("unixd: syscalls online \(unix.report.supportedSyscalls.map(\.rawValue).joined(separator: ","))")

        try registerBuiltInApps()
        let mail = try appRegistry.launch(identifier: "dev.arm64viz.mail", scheduler: scheduler, compositor: compositor)
        let browser = try appRegistry.launch(identifier: "dev.arm64viz.browser", scheduler: scheduler, compositor: compositor)
        log("appd: launched \(mail.manifest.displayName) pid=\(mail.pid)")
        log("appd: launched \(browser.manifest.displayName) pid=\(browser.pid)")

        try scheduler.send(MobileOSMessage(from: inputPID, to: mail.pid, topic: "lifecycle", payload: "foreground"))
        for _ in 0..<6 {
            _ = scheduler.tick()
        }

        let touch = TouchEvent(x: 48, y: 96, isDown: true)
        machine.touch.enqueue(touch)
        lastTouchDispatch = compositor.dispatchTouch(touch)
        if let targetPID = lastTouchDispatch?.targetPID {
            try scheduler.send(MobileOSMessage(from: inputPID, to: targetPID, topic: "touch", payload: "\(touch.x),\(touch.y),down"))
            log("inputd: touch dispatched to pid=\(targetPID)")
        } else {
            log("inputd: touch ignored")
        }

        try compositor.render(to: machine.framebuffer)
        log("compositor: framebuffer rendered checksum=\(machine.framebuffer.checksum())")

        return MobileOSKernelReport(
            bootLog: bootLog,
            processes: scheduler.allProcesses,
            apps: appRegistry.running,
            surfaces: compositor.orderedSurfaces,
            touchDispatch: lastTouchDispatch,
            framebufferChecksum: machine.framebuffer.checksum(),
            unix: unix.report
        )
    }

    public func submitTerminalInput(_ input: String) throws -> MobileOSUnixReport {
        guard let ptyID = unix.report.primaryPTYID else {
            throw VMError.deviceError("MobileOS Unix PTY is not booted")
        }
        try unix.writePTY(id: ptyID, input: input.hasSuffix("\n") ? input : "\(input)\n")
        return unix.report
    }

    private func registerBuiltInApps() throws {
        for manifest in MobileOSAppManifest.builtInApps {
            try appRegistry.register(manifest)
        }
        log("appd: registered \(appRegistry.registeredApps.count) JavaScript apps")
    }

    private func log(_ line: String) {
        bootLog.append(line)
    }
}

public extension VirtualFramebuffer {
    func fill(_ color: MobileOSColor) throws {
        try fillRect(MobileOSRect(x: 0, y: 0, width: width, height: height), color: color)
    }

    func fillRect(_ rect: MobileOSRect, color: MobileOSColor) throws {
        let clippedX0 = max(0, rect.x)
        let clippedY0 = max(0, rect.y)
        let clippedX1 = min(width, rect.x + rect.width)
        let clippedY1 = min(height, rect.y + rect.height)

        guard clippedX0 < clippedX1, clippedY0 < clippedY1 else {
            return
        }

        for y in clippedY0..<clippedY1 {
            let rowOffset = y * stride
            for x in clippedX0..<clippedX1 {
                let offset = UInt64(rowOffset + x * bytesPerPixel)
                try write(offset: offset, width: .word, value: UInt64(color.argb))
            }
        }
    }

    func checksum() -> UInt64 {
        pixelBytes.reduce(UInt64(0)) { partial, byte in
            ((partial << 5) &+ partial) &+ UInt64(byte)
        }
    }
}
