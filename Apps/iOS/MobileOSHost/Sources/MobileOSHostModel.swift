import ARM64VizCore
import Combine
import Foundation

private func linuxConsoleBootArguments() -> String {
    [
        "console=ttyAMA0",
        "console=tty0",
        "earlycon=pl011,mmio32,0x9000000",
        "root=/dev/vda",
        "rw",
        "rootwait",
        "rdinit=/init",
        "loglevel=7",
        "ignore_loglevel",
        "printk.time=1",
        "print-fatal-signals=1",
        "consoleblank=0",
        "pinecone.unix_time=\(Int64(Date().timeIntervalSince1970))"
    ].joined(separator: " ")
}

@MainActor
final class HostPerformanceFeed: ObservableObject {
    struct Snapshot: Equatable, Sendable {
        let steps: Int
        let summary: String
    }

    @Published private(set) var snapshot = Snapshot(steps: 0, summary: "")

    func update(steps: Int, summary: String) {
        snapshot = Snapshot(steps: steps, summary: summary)
    }

    func reset() {
        snapshot = Snapshot(steps: 0, summary: "")
    }
}

@MainActor
final class MobileOSHostModel: ObservableObject {
    @Published private(set) var vmBootLog: String = ""
    @Published private(set) var terminalText: String = ""
    @Published private(set) var kernelReport: MobileOSKernelReport?
    @Published private(set) var linuxReport: LinuxHostReport?
    @Published private(set) var status: HostStatus = .idle
    @Published private(set) var lastError: String?
    @Published private(set) var lastStopReason: String?
    @Published private(set) var displayTouchLog: [String] = []
    let displayFeed = GuestDisplayFeed()
    let performanceFeed = HostPerformanceFeed()

    private var runtime: LinuxConsoleRuntime?
    private var bootTask: Task<Void, Never>?
    private var runTask: Task<Void, Never>?
    private var displayTask: Task<Void, Never>?
    private var cleanupTask: Task<Void, Never>?
    private var uartCoalescer: UARTCoalescer?
    private var runIdentifier: UInt64 = 0
    private var cleanupIdentifier: UInt64 = 0
    private var filesystemLoadingMessagePrinted = false
    private var simulatorAutorunCommandSent = false
    private var pendingTerminalControlBytes: [UInt8] = []

    private static let terminalLimit = 64_000
    private static let terminalFlushIntervalNanoseconds: UInt64 = 50_000_000
    private static let bootRunSliceSteps = 20_000
    private static let interactiveRunSliceSteps = 80_000
    private static let idleRunSliceSteps = 4_000
    private static let pendingInputRunSliceSteps = 8_000
    private static let bootProgressIntervalNanoseconds: UInt64 = 250_000_000
    private static let interactiveProgressIntervalNanoseconds: UInt64 = 500_000_000
    private static let displayPublishIntervalNanoseconds: UInt64 = 16_666_667
    private static let cursorPositionQuery = Array("\u{001B}[6n".utf8)
    private static let cursorPositionReply = Array("\u{001B}[1;1R".utf8)

    enum HostStatus: String {
        case idle = "Idle"
        case booting = "Booting"
        case running = "Running"
        case stopped = "Stopped"
        case failed = "Failed"
    }

    var processRows: [MobileOSProcess] {
        kernelReport?.processes ?? []
    }

    var appRows: [MobileOSAppInstance] {
        kernelReport?.apps ?? []
    }

    var surfaceRows: [MobileOSSurface] {
        kernelReport?.surfaces ?? []
    }

    var bootLines: [String] {
        if let kernelReport {
            return kernelReport.bootLog
        }
        return vmBootLog
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map(String.init)
    }

    var hasShellPrompt: Bool {
        runtime?.hasSeenShellPrompt ?? false
    }

    var terminalPromptLabel: String {
        hasShellPrompt ? "arm64viz-root #" : "ttyAMA0"
    }

    var canSendTerminalInput: Bool {
        status == .running && hasShellPrompt
    }

    func boot() async {
        stop()
        await waitForCleanupToFinish()

        runIdentifier &+= 1
        let activeRunIdentifier = runIdentifier
        status = .booting
        lastError = nil
        lastStopReason = nil
        performanceFeed.update(steps: 0, summary: "loading guest image")
        kernelReport = nil
        linuxReport = nil
        terminalText = ""
        vmBootLog = ""
#if targetEnvironment(simulator)
        if let uartLogURL = Self.simulatorUARTLogURL {
            try? FileManager.default.removeItem(at: uartLogURL)
        }
        if let performanceLogURL = Self.simulatorPerformanceLogURL {
            try? FileManager.default.removeItem(at: performanceLogURL)
        }
#endif
        filesystemLoadingMessagePrinted = false
        simulatorAutorunCommandSent = false
        pendingTerminalControlBytes.removeAll(keepingCapacity: true)
        displayTouchLog.removeAll(keepingCapacity: false)
        displayFeed.reset()

        let uartCoalescer = UARTCoalescer(
            intervalNanoseconds: Self.terminalFlushIntervalNanoseconds
        ) { [weak self] bytes in
            await self?.appendUART(bytes, runIdentifier: activeRunIdentifier)
        }
        self.uartCoalescer = uartCoalescer

        bootTask = Task.detached(priority: .userInitiated) { [weak self, uartCoalescer] in
            do {
                try Task.checkCancellation()
                let bundle = try MobileOSHostModel.loadBundledShellArtifacts()

                try Task.checkCancellation()
                let runtime = try LinuxConsoleRuntime(
                    artifacts: bundle.artifacts,
                    diskPersistenceURL: bundle.diskPersistenceURL
                ) { bytes in
                    uartCoalescer.append(bytes)
                }

                try Task.checkCancellation()
                let report = MobileOSHostModel.makeLinuxReport(
                    from: runtime.loadResult,
                    bundle: bundle,
                    backendName: runtime.backendName
                )
                await self?.finishBootPreparation(
                    runtime: runtime,
                    linuxReport: report,
                    runIdentifier: activeRunIdentifier
                )
            } catch is CancellationError {
                return
            } catch {
                await self?.recordBootFailure(
                    runIdentifier: activeRunIdentifier,
                    error: String(describing: error)
                )
            }
        }
    }

    func stop() {
        runIdentifier &+= 1

        let previousBootTask = bootTask
        let previousRunTask = runTask
        let previousDisplayTask = displayTask
        let previousRuntime = runtime

        bootTask = nil
        runTask = nil
        displayTask = nil
        runtime = nil

        previousBootTask?.cancel()
        previousRunTask?.cancel()
        previousDisplayTask?.cancel()
        uartCoalescer?.cancel()
        uartCoalescer = nil

        scheduleCleanup(
            bootTask: previousBootTask,
            runTask: previousRunTask,
            displayTask: previousDisplayTask,
            runtime: previousRuntime
        )

        if status == .booting || status == .running {
            status = .stopped
        }
    }

    private func scheduleCleanup(
        bootTask: Task<Void, Never>?,
        runTask: Task<Void, Never>?,
        displayTask: Task<Void, Never>?,
        runtime: LinuxConsoleRuntime?
    ) {
        guard bootTask != nil || runTask != nil || displayTask != nil || runtime != nil else {
            return
        }

        cleanupIdentifier &+= 1
        let activeCleanupIdentifier = cleanupIdentifier
        let previousCleanupTask = cleanupTask

        cleanupTask = Task.detached(priority: .utility) { [weak self] in
            if let previousCleanupTask {
                await previousCleanupTask.value
            }
            if let bootTask {
                await bootTask.value
            }
            if let runTask {
                await runTask.value
            }
            if let displayTask {
                await displayTask.value
            }

            if let runtime {
                do {
                    try runtime.persistDiskImageIfNeeded()
                } catch {
                    await self?.recordPersistenceFailure(String(describing: error))
                }
            }

            await self?.cleanupDidFinish(identifier: activeCleanupIdentifier)
        }
    }

    private func waitForCleanupToFinish() async {
        while let cleanupTask {
            await cleanupTask.value
        }
    }

    private func cleanupDidFinish(identifier: UInt64) {
        guard identifier == cleanupIdentifier else {
            return
        }
        cleanupTask = nil
    }

    private func recordPersistenceFailure(_ error: String) {
        lastError = "failed to persist rootfs.ext4: \(error)"
    }

    func sendTerminalInput(_ input: String) {
        guard !input.isEmpty else {
            return
        }
        sendTerminalBytes(Array((input + "\n").utf8))
    }

    func sendTerminalBytes(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }
        runtime?.queueInput(bytes)
    }

    func sendControlC() {
        sendTerminalBytes([0x03])
    }

    func sendTouch(x: UInt32, y: UInt32, isDown: Bool) {
        runtime?.queueTouch(TouchEvent(x: x, y: y, isDown: isDown))
    }

    func withDisplayFrameBytes(
        afterGeneration previousGeneration: UInt64?,
        _ body: (VirtualFramebufferFrameMetadata, UnsafeRawBufferPointer) -> Void
    ) -> VirtualFramebufferFrameMetadata? {
        runtime?.withDisplayFrameBytes(
            afterGeneration: previousGeneration,
            body
        )
    }

    func recordDisplayPresented(
        generation: UInt64,
        uploadedBytes: Int,
        presentedAtNanoseconds: UInt64
    ) {
        runtime?.recordDisplayPresented(
            generation: generation,
            uploadedBytes: uploadedBytes,
            presentedAtNanoseconds: presentedAtNanoseconds
        )
    }

    func sendGuestKeyboardText(_ text: String) {
        runtime?.queueKeyboardEvents(LinuxKeyboardMapper.events(for: text))
    }

    func sendGuestKey(code: UInt16) {
        runtime?.queueKeyboardEvents([
            GuestKeyboardEvent(code: code, value: 1),
            GuestKeyboardEvent(code: code, value: 0)
        ])
    }

    private func startRunner(_ runtime: LinuxConsoleRuntime, runIdentifier: UInt64) {
        let bootRunSliceSteps = Self.bootRunSliceSteps
        let interactiveRunSliceSteps = Self.interactiveRunSliceSteps
        let idleRunSliceSteps = Self.idleRunSliceSteps
        let pendingInputRunSliceSteps = Self.pendingInputRunSliceSteps
        let bootProgressIntervalNanoseconds = Self.bootProgressIntervalNanoseconds
        let interactiveProgressIntervalNanoseconds = Self.interactiveProgressIntervalNanoseconds

        runTask = Task.detached(priority: .userInitiated) { [weak self, runtime] in
            var totalSteps = 0
            var lastProgressUpdate: UInt64 = 0
            let executionPacer = HostExecutionPacer()

            while !Task.isCancelled {
                var runDuration: UInt64 = 0
                do {
                    let sliceSteps = runtime.preferredRunSliceSteps(
                        bootSteps: bootRunSliceSteps,
                        interactiveSteps: interactiveRunSliceSteps,
                        idleSteps: idleRunSliceSteps,
                        pendingInputSteps: pendingInputRunSliceSteps
                    )
                    let sliceStart = DispatchTime.now().uptimeNanoseconds
                    let result = try runtime.runSlice(maxSteps: sliceSteps)
                    let sliceEnd = DispatchTime.now().uptimeNanoseconds
                    runDuration = sliceEnd &- sliceStart
                    totalSteps += result.steps
                    let stopReason = result.stopReason.description
                    let pc = runtime.pc

                    switch result.stopReason {
                    case .maxSteps:
                        let now = DispatchTime.now().uptimeNanoseconds
                        let progressIntervalNanoseconds = runtime.hasSeenShellPrompt
                            ? interactiveProgressIntervalNanoseconds
                            : bootProgressIntervalNanoseconds

                        if lastProgressUpdate == 0 ||
                            now - lastProgressUpdate >= progressIntervalNanoseconds {
                            await self?.recordRunnerProgress(
                                runIdentifier: runIdentifier,
                                steps: totalSteps,
                                stopReason: stopReason,
                                pc: pc,
                                performance: runtime.performanceReport()
                            )
                            lastProgressUpdate = now
                        }

                    default:
                        await self?.recordRunnerProgress(
                            runIdentifier: runIdentifier,
                            steps: totalSteps,
                            stopReason: stopReason,
                            pc: pc,
                            performance: runtime.performanceReport()
                        )
                        await self?.recordRunnerStopped(runIdentifier: runIdentifier)

                        do {
                            try runtime.persistDiskImageIfNeeded()
                        } catch {
                            await self?.recordPersistenceFailure(String(describing: error))
                        }

                        await self?.runnerTaskDidFinish(runIdentifier: runIdentifier)
                        return
                    }
                } catch {
                    let traceTail = runtime.traceTail()
                    await self?.recordRunnerFailure(
                        runIdentifier: runIdentifier,
                        error: String(describing: error),
                        traceTail: traceTail
                    )

                    do {
                        try runtime.persistDiskImageIfNeeded()
                    } catch {
                        await self?.recordPersistenceFailure(String(describing: error))
                    }

                    await self?.runnerTaskDidFinish(runIdentifier: runIdentifier)
                    return
                }

                if let generation = runtime.hostIdleWaitGeneration {
                    await runtime.waitForHostActivity(after: generation)
                } else if runtime.shouldPaceContinuousExecution {
                    let now = DispatchTime.now().uptimeNanoseconds
                    let delay = executionPacer.delayNanoseconds(
                        afterRunDuration: runDuration,
                        nowNanoseconds: now,
                        latestInteractionNanoseconds: runtime.latestHostActivityNanoseconds
                    )
                    if delay > 0 {
                        try? await Task.sleep(nanoseconds: delay)
                    } else {
                        await Task.yield()
                    }
                } else {
                    await Task.yield()
                }
            }

            await self?.runnerTaskDidFinish(runIdentifier: runIdentifier)
        }
    }

    private func startDisplayPublisher(
        _ runtime: LinuxConsoleRuntime,
        runIdentifier: UInt64
    ) {
        let minimumInterval = Self.displayPublishIntervalNanoseconds
        displayTask = Task.detached(priority: .userInitiated) { [weak self, runtime] in
            var publishedGeneration: UInt64?
            var lastPublishNanoseconds: UInt64 = 0

            while !Task.isCancelled {
                let commit = runtime.displayCommitSnapshot
                if commit.generation == 0 || commit.generation == publishedGeneration {
                    await runtime.waitForDisplayCommit(after: commit.generation)
                    continue
                }

                let now = DispatchTime.now().uptimeNanoseconds
                if lastPublishNanoseconds != 0,
                   now - lastPublishNanoseconds < minimumInterval {
                    try? await Task.sleep(
                        nanoseconds: minimumInterval - (now - lastPublishNanoseconds)
                    )
                    if Task.isCancelled { break }
                }

                guard let metadata = runtime.displayFrameMetadata(
                    afterGeneration: publishedGeneration
                ) else {
                    await runtime.waitForDisplayCommit(after: commit.generation)
                    continue
                }
                let publishedAt = DispatchTime.now().uptimeNanoseconds
                runtime.recordDisplayPublished(
                    metadata,
                    publishedAtNanoseconds: publishedAt
                )
                publishedGeneration = metadata.generation
                lastPublishNanoseconds = publishedAt
                await self?.recordDisplayMetadata(
                    runIdentifier: runIdentifier,
                    metadata: metadata
                )
            }
        }
    }

    private func recordDisplayMetadata(
        runIdentifier: UInt64,
        metadata: VirtualFramebufferFrameMetadata
    ) {
        guard runIdentifier == self.runIdentifier else { return }
        displayFeed.publish(metadata)
    }

    private func recordRunnerProgress(
        runIdentifier: UInt64,
        steps: Int,
        stopReason: String,
        pc: UInt64,
        performance: String
    ) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        lastStopReason = "\(stopReason) pc=\(Self.hex(pc))"
        performanceFeed.update(steps: steps, summary: performance)
#if targetEnvironment(simulator)
        writeSimulatorPerformanceSnapshot(
            steps: steps,
            stopReason: stopReason,
            performance: performance
        )
#endif
    }

    private func recordRunnerStopped(runIdentifier: UInt64) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        displayTask?.cancel()
        displayTask = nil
        runtime = nil
        status = .stopped
        bootTask = nil
    }

    private func recordRunnerFailure(runIdentifier: UInt64, error: String, traceTail: String?) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        displayTask?.cancel()
        displayTask = nil
        runtime = nil
        lastError = [error, traceTail].compactMap { $0 }.joined(separator: "\n")
        status = .failed
        bootTask = nil
    }

    private func runnerTaskDidFinish(runIdentifier: UInt64) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        runTask = nil
    }

    private func finishBootPreparation(
        runtime: LinuxConsoleRuntime,
        linuxReport: LinuxHostReport,
        runIdentifier: UInt64
    ) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        bootTask = nil
        self.runtime = runtime
        self.linuxReport = linuxReport
        performanceFeed.reset()
        status = .running
        startRunner(runtime, runIdentifier: runIdentifier)
        startDisplayPublisher(runtime, runIdentifier: runIdentifier)
    }

    private func recordBootFailure(runIdentifier: UInt64, error: String) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        bootTask = nil
        lastError = error
        status = .failed
    }

    private func appendUART(_ bytes: [UInt8], runIdentifier: UInt64) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        guard !bytes.isEmpty else {
            return
        }

        terminalText += String(decoding: consumeTerminalControlQueries(bytes), as: UTF8.self)
        appendFilesystemLoadingMessageIfNeeded()
        if terminalText.count > Self.terminalLimit {
            terminalText.removeFirst(terminalText.count - Self.terminalLimit)
        }
        vmBootLog = terminalText
#if targetEnvironment(simulator)
        appendSimulatorUARTLog(bytes)
#endif
        sendSimulatorAutorunCommandIfNeeded()
    }

    private func consumeTerminalControlQueries(_ bytes: [UInt8]) -> [UInt8] {
        var visible = [UInt8]()
        visible.reserveCapacity(bytes.count)

        for byte in bytes {
            if pendingTerminalControlBytes.isEmpty {
                if byte == Self.cursorPositionQuery[0] {
                    pendingTerminalControlBytes.append(byte)
                } else {
                    visible.append(byte)
                }
                continue
            }

            if byte == Self.cursorPositionQuery[pendingTerminalControlBytes.count] {
                pendingTerminalControlBytes.append(byte)
                if pendingTerminalControlBytes.count == Self.cursorPositionQuery.count {
                    pendingTerminalControlBytes.removeAll(keepingCapacity: true)
                    runtime?.queueInput(Self.cursorPositionReply)
                }
                continue
            }

            visible.append(contentsOf: pendingTerminalControlBytes)
            pendingTerminalControlBytes.removeAll(keepingCapacity: true)
            if byte == Self.cursorPositionQuery[0] {
                pendingTerminalControlBytes.append(byte)
            } else {
                visible.append(byte)
            }
        }

        return visible
    }

#if targetEnvironment(simulator)
    private static var simulatorUARTLogURL: URL? {
        guard ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_UART"] == "1",
              let cachesURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
              ).first else {
            return nil
        }
        return cachesURL.appendingPathComponent("pinecone-uart.log")
    }

    private static var simulatorPerformanceLogURL: URL? {
        guard ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_PERFORMANCE"] == "1",
              let cachesURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
              ).first else {
            return nil
        }
        return cachesURL.appendingPathComponent("pinecone-performance.log")
    }

    private func writeSimulatorPerformanceSnapshot(
        steps: Int,
        stopReason: String,
        performance: String
    ) {
        guard let performanceLogURL = Self.simulatorPerformanceLogURL else {
            return
        }
        let snapshot = "steps=\(steps) stop=\(stopReason)\n\(performance)\n"
        try? Data(snapshot.utf8).write(to: performanceLogURL, options: .atomic)
    }

    private func appendSimulatorUARTLog(_ bytes: [UInt8]) {
        guard let uartLogURL = Self.simulatorUARTLogURL else {
            return
        }
        if !FileManager.default.fileExists(atPath: uartLogURL.path) {
            FileManager.default.createFile(atPath: uartLogURL.path, contents: nil)
        }
        guard let handle = try? FileHandle(forWritingTo: uartLogURL) else {
            return
        }
        defer { try? handle.close() }
        do {
            try handle.seekToEnd()
            try handle.write(contentsOf: Data(bytes))
        } catch {
            return
        }
    }
#endif

    private func sendSimulatorAutorunCommandIfNeeded() {
#if targetEnvironment(simulator)
        guard !simulatorAutorunCommandSent,
              hasShellPrompt,
              let command = ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_AUTORUN_COMMAND"],
              !command.isEmpty else {
            return
        }
        simulatorAutorunCommandSent = true
        sendTerminalInput(command)
#endif
    }

    private func appendFilesystemLoadingMessageIfNeeded() {
        guard !filesystemLoadingMessagePrinted,
              status == .running,
              !hasShellPrompt,
              terminalText.contains("legacy bootconsole [pl11] disabled") else {
            return
        }
        let filesystemMessages = [
            "arm64viz init: mounting persistent root",
            "arm64viz init: switching to persistent root",
            "arm64viz rootfs:",
            "arm64viz-root"
        ]
        guard !filesystemMessages.contains(where: terminalText.contains) else {
            return
        }
        if !terminalText.hasSuffix("\n") {
            terminalText += "\n"
        }
        terminalText += "loading filesystem...\n"
        filesystemLoadingMessagePrinted = true
    }

    nonisolated private static func loadBundledShellArtifacts() throws -> BundledShellArtifacts {
        guard let kernelURL = Bundle.main.url(forResource: "Image", withExtension: nil) else {
            throw VMError.deviceError("bundled Linux Image resource is missing")
        }

        let initrdNames = [
            "initramfs-minimal-ttyinit.cpio",
            "initramfs-virt-ttyinit.cpio",
            "initramfs-virt-repacked-console.cpio",
            "initramfs-virt"
        ]
        let initrdCandidate = initrdNames.lazy.compactMap { name -> (String, URL)? in
            Bundle.main.url(forResource: name, withExtension: nil).map { (name, $0) }
        }.first
        guard let (initrdName, initrdURL) = initrdCandidate else {
            throw VMError.deviceError("bundled Linux initramfs resource is missing")
        }

        let kernel = try Data(contentsOf: kernelURL, options: .mappedIfSafe)
        let initrd = try Data(contentsOf: initrdURL, options: .mappedIfSafe)
        let disk = try loadWritableDiskImage()
        return BundledShellArtifacts(
            artifacts: LinuxBootArtifacts(
                kernelImage: [UInt8](kernel),
                initrd: [UInt8](initrd),
                diskByteCountHint: disk?.byteCount
            ),
            kernelResourceName: "Image",
            initrdResourceName: initrdName,
            diskResourceName: disk == nil ? nil : "rootfs.ext4",
            diskPersistenceURL: disk?.url,
            diskByteCount: disk?.byteCount ?? 0
        )
    }

    nonisolated private static func loadWritableDiskImage() throws -> (url: URL, byteCount: Int)? {
        guard let bundledDiskURL = Bundle.main.url(forResource: "rootfs", withExtension: "ext4") else {
            return nil
        }

        let bundledFingerprint = try diskFingerprint(forResourceAt: bundledDiskURL)
        let fileManager = FileManager.default
        let supportRoot = try fileManager.url(
            for: .applicationSupportDirectory,
            in: .userDomainMask,
            appropriateFor: nil,
            create: true
        )
        let diskDirectory = supportRoot.appendingPathComponent("Pinecone", isDirectory: true)
        try fileManager.createDirectory(at: diskDirectory, withIntermediateDirectories: true)

        let writableDiskURL = diskDirectory.appendingPathComponent("rootfs.ext4")
        let fingerprintURL = diskDirectory.appendingPathComponent("rootfs.bundle-fingerprint")
        let storedFingerprint = (try? String(contentsOf: fingerprintURL, encoding: .utf8))?
            .trimmingCharacters(in: .whitespacesAndNewlines)

        if !fileManager.fileExists(atPath: writableDiskURL.path) ||
            storedFingerprint != bundledFingerprint {
            let backupURL = diskDirectory.appendingPathComponent("rootfs.previous.ext4")
            try? fileManager.removeItem(at: backupURL)

            let stagingURL = diskDirectory.appendingPathComponent("rootfs.staging.ext4")
            try? fileManager.removeItem(at: stagingURL)
            try fileManager.copyItem(at: bundledDiskURL, to: stagingURL)

            if fileManager.fileExists(atPath: writableDiskURL.path) {
                _ = try fileManager.replaceItemAt(
                    writableDiskURL,
                    withItemAt: stagingURL,
                    backupItemName: "rootfs.previous.ext4"
                )
            } else {
                try fileManager.moveItem(at: stagingURL, to: writableDiskURL)
            }
            try bundledFingerprint.write(to: fingerprintURL, atomically: true, encoding: .utf8)
        }

        let attributes = try fileManager.attributesOfItem(atPath: writableDiskURL.path)
        let byteCount = (attributes[.size] as? NSNumber)?.intValue ?? 0
        guard byteCount > 0 else {
            throw VMError.deviceError("persistent rootfs image is empty")
        }
        return (writableDiskURL, byteCount)
    }

    nonisolated private static func diskFingerprint(forResourceAt url: URL) throws -> String {
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        let modificationDate = (attributes[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let bundleVersion = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "0"
        return "\(bundleVersion)-\(byteCount)-\(UInt64(max(0, modificationDate)))"
    }

    nonisolated private static func makeLinuxReport(
        from result: LinuxBootLoadResult,
        bundle: BundledShellArtifacts,
        backendName: String
    ) -> LinuxHostReport {
        let artifacts = bundle.artifacts
        let diskDescription: String
        if let diskResourceName = bundle.diskResourceName {
            diskDescription = "\(diskResourceName) attached for persistent-root bring-up (\(byteCount(artifacts.diskByteCountHint ?? 0)))"
        } else {
            diskDescription = "rootfs.ext4 not bundled"
        }
        return LinuxHostReport(
            guest: result.configuration.machineName,
            profile: result.layout.profile.rawValue,
            backend: backendName,
            shellTarget: "persistent rootfs /sbin/init with ttyAMA0 shell",
            kernelArtifact: "Bundle resource: \(bundle.kernelResourceName) (\(byteCount(artifacts.kernelImage.count)))",
            initrdArtifact: "Bundle resource: \(bundle.initrdResourceName) (\(byteCount(artifacts.initrd?.count ?? 0))); \(diskDescription)",
            entryPoint: hex(result.layout.kernelLoadAddress),
            fdtAddress: hex(result.layout.fdtLoadAddress),
            fdtByteCount: result.layout.fdtByteCount,
            bootArguments: result.layout.bootArguments,
            traceBlocker: "guest outbound networking now uses the host TCP/UDP stack plus ICMP echo bridging; broader slirp-style parity is still incomplete",
            canExecuteNow: true,
            nextBackendWork: [
                "Broaden ICMP/error handling and make UDP NAT fully stateful",
                "Implement virtio-input event queues and map iOS touch coordinates",
                "Replace simplefb bring-up with DRM/KMS scanout for Wayland guests",
                "Keep rootfs writeback policy explicit for persistent guest images",
                "Move guest images into a signed internal asset manifest"
            ]
        )
    }

    nonisolated private static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    nonisolated private static func byteCount(_ count: Int) -> String {
        let mib = Double(count) / 1_048_576
        return String(format: "%.1f MiB", mib)
    }
}

private struct BundledShellArtifacts {
    let artifacts: LinuxBootArtifacts
    let kernelResourceName: String
    let initrdResourceName: String
    let diskResourceName: String?
    let diskPersistenceURL: URL?
    let diskByteCount: Int
}

private struct GuestKeyboardEvent {
    let code: UInt16
    let value: Int32
}

private enum LinuxKeyboardMapper {
    private static let keyCodes: [Character: UInt16] = [
        "1": 2, "2": 3, "3": 4, "4": 5, "5": 6, "6": 7, "7": 8, "8": 9, "9": 10, "0": 11,
        "-": 12, "=": 13, "q": 16, "w": 17, "e": 18, "r": 19, "t": 20, "y": 21, "u": 22,
        "i": 23, "o": 24, "p": 25, "[": 26, "]": 27, "a": 30, "s": 31, "d": 32, "f": 33,
        "g": 34, "h": 35, "j": 36, "k": 37, "l": 38, ";": 39, "'": 40, "`": 41, "\\": 43,
        "z": 44, "x": 45, "c": 46, "v": 47, "b": 48, "n": 49, "m": 50, ",": 51, ".": 52,
        "/": 53, " ": 57
    ]
    private static let shifted: [Character: Character] = [
        "!": "1", "@": "2", "#": "3", "$": "4", "%": "5", "^": "6", "&": "7", "*": "8",
        "(": "9", ")": "0", "_": "-", "+": "=", "{": "[", "}": "]", ":": ";", "\"": "'",
        "~": "`", "|": "\\", "<": ",", ">": ".", "?": "/"
    ]

    static func events(for text: String) -> [GuestKeyboardEvent] {
        text.flatMap(events(for:))
    }

    private static func events(for character: Character) -> [GuestKeyboardEvent] {
        if character == "\n" || character == "\r" { return tap(28) }
        if character == "\t" { return tap(15) }

        var base = character
        var needsShift = false
        if let shiftedBase = shifted[character] {
            base = shiftedBase
            needsShift = true
        } else if character.isUppercase {
            base = Character(String(character).lowercased())
            needsShift = true
        }
        guard let code = keyCodes[base] else { return [] }
        if needsShift {
            return [
                GuestKeyboardEvent(code: 42, value: 1),
                GuestKeyboardEvent(code: code, value: 1),
                GuestKeyboardEvent(code: code, value: 0),
                GuestKeyboardEvent(code: 42, value: 0)
            ]
        }
        return tap(code)
    }

    private static func tap(_ code: UInt16) -> [GuestKeyboardEvent] {
        [GuestKeyboardEvent(code: code, value: 1), GuestKeyboardEvent(code: code, value: 0)]
    }
}

private final class LinuxConsoleRuntime: @unchecked Sendable {
    private static let networkPumpRunSliceSteps = 2_000
    private static let bootChunkRunSliceSteps = 10_000
    private static let interactiveChunkRunSliceSteps = 10_000
    private static let pendingInputChunkRunSliceSteps = 8_000
    private static let maximumPendingInputBytes = 64 * 1024
    private static let maximumPendingTouchEvents = 256
    private static let maximumPendingKeyboardEvents = 4_096
    private static let touchInteractionWatchdogNanoseconds: UInt64 = 2_000_000_000
    private static let touchLatencySampleLimit = 64
#if targetEnvironment(simulator)
    private static let defaultGuestMemoryMiB = 1024
#else
    private static let defaultGuestMemoryMiB = 384
#endif

    private static var guestMemorySize: Int {
        let requestedMiB = ProcessInfo.processInfo.environment["PINECONE_GUEST_MEMORY_MB"]
            .flatMap(Int.init)
        let memoryMiB = min(max(requestedMiB ?? defaultGuestMemoryMiB, 128), 1_024)
        return memoryMiB * 1024 * 1024
    }

    let loadResult: LinuxBootLoadResult
    let backendName: String
    let diskPersistenceURL: URL?

    private let machine: ResearchMachine
    private let networkBridge: LinkLocalVirtIONetworkBackend
    private let hostWakeSignal: HostWakeSignal
    private let displayCommitSignal: DisplayCommitSignal
    private let uartOutputBuffer: LockedByteBuffer
    private let onUART: @Sendable ([UInt8]) -> Void
    private let lock = NSLock()
    private let persistenceLock = NSLock()
    private var pendingInput: [UInt8] = []
    private var pendingInputReadIndex = 0
    private var pendingTouches: [TouchEvent] = []
    private var pendingTouchMoveIndex: Int?
    private var hostTouchContactActive = false
    private var queuedTouchEventCount = 0
    private var drainedTouchEventCount = 0
    private var droppedTouchEventCount = 0
    private var pendingKeyboardEvents: [GuestKeyboardEvent] = []
    private var diskPersistenceCompleted = false
    private var pendingInputTimestamp: UInt64?
    private var lastInputLatencyNanoseconds: UInt64?
    private var lastHostActivityNanoseconds: UInt64?
    private var touchInteractionActive = false
    private var touchAwaitingFrame = false
    private var latestTouchQueuedNanoseconds: UInt64?
    private var latestTouchInjectedNanoseconds: UInt64?
    private var latestTouchDeliveredNanoseconds: UInt64?
    private var touchBaselineDisplayGeneration: UInt64 = 0
    private var touchQueueToDeviceSamples: [UInt64] = []
    private var touchDeviceToFrameSamples: [UInt64] = []
    private var touchFrameToPublishSamples: [UInt64] = []
    private var touchEndToEndSamples: [UInt64] = []
    private var shellPromptSeen = false
    private var lastRunSliceObservedWFI = false
    private var displayContentVisible = false
    private var displayBlankedAfterShell = false
    private var uartPromptTail = ""
#if targetEnvironment(simulator)
    private var lastFramebufferDumpNanoseconds: UInt64 = 0
#endif

    init(
        artifacts: LinuxBootArtifacts,
        diskPersistenceURL: URL?,
        onUART: @escaping @Sendable ([UInt8]) -> Void
    ) throws {
        let uartOutputBuffer = LockedByteBuffer()
        let fileBackedStorage = try diskPersistenceURL.map(FileBackedVirtIOBlockStorage.init(url:))
        let diskByteCount = fileBackedStorage?.count ?? artifacts.diskImage?.count ?? 0
        let machine = try MachineFactory.makeResearchMachine(
            memorySize: Self.guestMemorySize,
            blockStorageSize: max(1024 * 1024, diskByteCount),
            blockStorage: fileBackedStorage,
            publishedDevices: diskByteCount == 0 ? .linuxConsole : .full
        )
#if targetEnvironment(simulator)
        let hotPCProfilingEnabled =
            ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_HOT_PC_PROFILE"] == "1"
        (machine.vm.backend as? SoftwareARM64Backend)?
            .setNativeHotPCProfilingEnabled(hotPCProfilingEnabled)
#endif
        let networkBridge = LinkLocalVirtIONetworkBackend()
        let hostWakeSignal = HostWakeSignal()
        let displayCommitSignal = DisplayCommitSignal()
        machine.virtioNetwork.attachNetworkBackend(networkBridge)
        networkBridge.onFramesAvailable = { [weak networkDevice = machine.virtioNetwork, weak hostWakeSignal] in
            networkDevice?.pumpNetworkReceiveQueue()
            hostWakeSignal?.signal()
        }
        machine.virtioDisplay.onDisplayFrameCommitted = { [weak displayCommitSignal, weak hostWakeSignal] generation in
            displayCommitSignal?.note(generation: generation)
            hostWakeSignal?.signal()
        }
        let adapter = LinuxDirectBootAdapter(
            artifacts: artifacts,
            profile: .generic,
            bootArguments: linuxConsoleBootArguments()
        )
        let result = try adapter.loadWithResult(into: machine.vm)

        machine.vm.timerCyclesPerInstruction = 1
        machine.vm.wallClockRunBudgetNanoseconds = 20_000_000
        if let backend = machine.vm.backend as? SoftwareARM64Backend {
            backend.enableBasicBlockExecution = true
            backend.fallbackInterpreterPolicy = .alwaysAllow
        }
        machine.vm.exceptionStormThreshold = 0
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.uart.onByte = { byte in
            uartOutputBuffer.append(byte)
        }

        self.machine = machine
        self.networkBridge = networkBridge
        self.hostWakeSignal = hostWakeSignal
        self.displayCommitSignal = displayCommitSignal
        self.uartOutputBuffer = uartOutputBuffer
        self.onUART = onUART
        self.loadResult = result
        self.backendName = machine.vm.backend.name
        self.diskPersistenceURL = diskPersistenceURL
    }

    var pc: UInt64 {
        machine.vm.cpu.pc
    }

    func queueInput(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }

        lock.lock()
        compactPendingInputLockedIfNeeded(force: false)

        let pendingCount = pendingInput.count - pendingInputReadIndex
        let availableCapacity = max(0, Self.maximumPendingInputBytes - pendingCount)
        let appendedInput: Bool
        if availableCapacity > 0 {
            pendingInput.append(contentsOf: bytes.prefix(availableCapacity))
            let now = DispatchTime.now().uptimeNanoseconds
            pendingInputTimestamp = now
            lastHostActivityNanoseconds = now
            appendedInput = true
        } else {
            appendedInput = false
        }
        lock.unlock()
        if appendedInput {
            hostWakeSignal.signal()
        }
    }

    func queueTouch(_ event: TouchEvent) {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        var accepted = false

        if event.isDown, hostTouchContactActive {
            if let moveIndex = pendingTouchMoveIndex,
               pendingTouches.indices.contains(moveIndex) {
                pendingTouches[moveIndex] = event
                droppedTouchEventCount += 1
            } else {
                pendingTouchMoveIndex = pendingTouches.count
                pendingTouches.append(event)
            }
            accepted = true
        } else if event.isDown {
            hostTouchContactActive = true
            pendingTouchMoveIndex = nil
            pendingTouches.append(event)
            accepted = true
        } else if hostTouchContactActive {
            hostTouchContactActive = false
            pendingTouchMoveIndex = nil
            pendingTouches.append(event)
            accepted = true
        }

        guard accepted else {
            lock.unlock()
            return
        }

        if pendingTouches.count > Self.maximumPendingTouchEvents {
            let overflow = pendingTouches.count - Self.maximumPendingTouchEvents
            pendingTouches.removeFirst(overflow)
            pendingTouchMoveIndex = nil
            droppedTouchEventCount += overflow
        }
        queuedTouchEventCount += 1
        lastHostActivityNanoseconds = now
        touchInteractionActive = event.isDown
        touchAwaitingFrame = true
        latestTouchQueuedNanoseconds = now
        latestTouchInjectedNanoseconds = nil
        latestTouchDeliveredNanoseconds = nil

        lock.unlock()
        hostWakeSignal.signal()
    }

    func queueKeyboardEvents(_ events: [GuestKeyboardEvent]) {
        guard !events.isEmpty else {
            return
        }

        lock.lock()
        let overflow = pendingKeyboardEvents.count + events.count - Self.maximumPendingKeyboardEvents
        if overflow > 0 {
            pendingKeyboardEvents.removeFirst(min(overflow, pendingKeyboardEvents.count))
        }
        pendingKeyboardEvents.append(contentsOf: events.suffix(Self.maximumPendingKeyboardEvents))
        lastHostActivityNanoseconds = DispatchTime.now().uptimeNanoseconds
        lock.unlock()
        hostWakeSignal.signal()
    }

    var hasPendingInput: Bool {
        lock.lock()
        let result = pendingInputReadIndex < pendingInput.count ||
            !pendingTouches.isEmpty ||
            !pendingKeyboardEvents.isEmpty
        lock.unlock()
        return result
    }

    var hasSeenShellPrompt: Bool {
        lock.lock()
        let result = shellPromptSeen
        lock.unlock()
        return result
    }

    var latestHostActivityNanoseconds: UInt64? {
        lock.lock()
        let value = lastHostActivityNanoseconds
        lock.unlock()
        return value
    }

    private var hasLatencySensitiveTouch: Bool {
        lock.lock()
        let result = isTouchLatencySensitiveLocked(
            now: DispatchTime.now().uptimeNanoseconds
        )
        lock.unlock()
        return result
    }

    var shouldPaceContinuousExecution: Bool {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldPace = shellPromptSeen && displayContentVisible &&
            !lastRunSliceObservedWFI &&
            pendingInputReadIndex >= pendingInput.count &&
            pendingTouches.isEmpty && pendingKeyboardEvents.isEmpty &&
            !isTouchLatencySensitiveLocked(now: now)
        lock.unlock()
        return shouldPace && !networkBridge.hasPendingAsynchronousTraffic
    }

    func preferredRunSliceSteps(
        bootSteps: Int,
        interactiveSteps: Int,
        idleSteps: Int,
        pendingInputSteps: Int
    ) -> Int {
        lock.lock()
        let result: Int
        let now = DispatchTime.now().uptimeNanoseconds
        if isTouchLatencySensitiveLocked(now: now) ||
            pendingInputReadIndex < pendingInput.count ||
            !pendingTouches.isEmpty ||
            !pendingKeyboardEvents.isEmpty {
            result = pendingInputSteps
        } else if shellPromptSeen && lastRunSliceObservedWFI &&
                    !networkBridge.hasPendingAsynchronousTraffic {
            result = idleSteps
        } else if shellPromptSeen {
            result = interactiveSteps
        } else {
            result = bootSteps
        }
        lock.unlock()
        return result
    }

    func runSlice(maxSteps: Int) throws -> RunResult {
        let initialWaitForInterruptCount = machine.vm.waitForInterruptCount
        defer {
            lock.lock()
            lastRunSliceObservedWFI =
                machine.vm.waitForInterruptCount != initialWaitForInterruptCount
            lock.unlock()
            flushUARTOutput()
        }
        let input = drainInput(maxCount: machine.uart.receiveFIFOAvailableCapacity)
        if !input.isEmpty {
            machine.uart.injectReceiveBytes(input)
        }
        let touches = drainTouches()
        if !touches.isEmpty {
            let injectionTime = DispatchTime.now().uptimeNanoseconds
            let baselineGeneration = machine.virtioDisplay.displayGeneration ?? 0
            lock.lock()
            latestTouchInjectedNanoseconds = injectionTime
            touchBaselineDisplayGeneration = baselineGeneration
            lock.unlock()
            let deliveredBefore = machine.virtioInput.inputFramesDelivered
            for event in touches {
                machine.touch.enqueue(event)
                machine.virtioInput.enqueueTouch(x: event.x, y: event.y, isDown: event.isDown)
            }
            noteTouchDeliveredIfNeeded(previousDeliveredCount: deliveredBefore)
        }
        for event in drainKeyboardEvents() {
            machine.virtioKeyboard.enqueueKey(code: event.code, value: event.value)
        }
        machine.virtioNetwork.pumpNetworkReceiveQueue()
        var stepsRemaining = maxSteps
        var totalSteps = 0
        var lastException: ARM64ExceptionTraceEntry?

        while stepsRemaining > 0 {
            let responsivenessBudget: Int
            if hasPendingInput || hasLatencySensitiveTouch {
                responsivenessBudget = Self.pendingInputChunkRunSliceSteps
            } else if hasSeenShellPrompt {
                responsivenessBudget = Self.interactiveChunkRunSliceSteps
            } else {
                responsivenessBudget = Self.bootChunkRunSliceSteps
            }
            var stepBudget = min(stepsRemaining, responsivenessBudget)
            if shouldUseFrequentNetworkPumps {
                stepBudget = min(stepBudget, Self.networkPumpRunSliceSteps)
            }
            let result = try machine.vm.run(maxSteps: stepBudget)
            totalSteps += result.steps
            lastException = result.lastException
            flushUARTOutput()
            machine.virtioNetwork.pumpNetworkReceiveQueue()
            noteTouchDeliveredIfNeeded(previousDeliveredCount: nil)

            guard case .maxSteps = result.stopReason else {
                return RunResult(steps: totalSteps, stopReason: result.stopReason, lastException: lastException)
            }
            guard result.steps > 0 else {
                return RunResult(steps: totalSteps, stopReason: result.stopReason, lastException: lastException)
            }
            if result.steps < stepBudget {
                return RunResult(steps: totalSteps, stopReason: result.stopReason, lastException: lastException)
            }
            stepsRemaining -= result.steps
        }

        return RunResult(steps: totalSteps, stopReason: .maxSteps(maxSteps), lastException: lastException)
    }

    var hostIdleWaitGeneration: UInt64? {
        lock.lock()
        let generation = hostWakeSignal.currentGeneration
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldIdle = shellPromptSeen &&
            lastRunSliceObservedWFI &&
            pendingInputReadIndex >= pendingInput.count &&
            pendingTouches.isEmpty &&
            pendingKeyboardEvents.isEmpty &&
            !isTouchLatencySensitiveLocked(now: now)
        lock.unlock()

        guard shouldIdle,
              !networkBridge.hasPendingAsynchronousTraffic,
              machine.vm.interruptController.peekPending() == nil else {
            return nil
        }
        return generation
    }

    func waitForHostActivity(after generation: UInt64) async {
        await hostWakeSignal.wait(
            after: generation,
            timeoutNanoseconds: 16_666_667
        )
    }

    func traceTail() -> String? {
        guard let last = machine.vm.instructionTrace.last else {
            return nil
        }
        return "\(last.decode) 0x\(String(last.instruction, radix: 16)) at \(Self.hex(last.pc))"
    }

    func persistDiskImageIfNeeded() throws {
        guard let diskPersistenceURL else {
            return
        }

        persistenceLock.lock()
        if diskPersistenceCompleted {
            persistenceLock.unlock()
            return
        }
        diskPersistenceCompleted = true
        persistenceLock.unlock()

        do {
            try writeDiskImage(to: diskPersistenceURL)
        } catch {
            persistenceLock.lock()
            diskPersistenceCompleted = false
            persistenceLock.unlock()
            throw error
        }
    }

    private func writeDiskImage(to destinationURL: URL) throws {
        guard destinationURL == diskPersistenceURL else {
            throw VMError.deviceError("persistent rootfs destination changed while the VM was running")
        }
        try machine.virtioBlock.flushStorage()
    }

    func performanceReport() -> String {
        let softwareBackend = machine.vm.backend as? SoftwareARM64Backend
        let snapshot = softwareBackend?.performanceSnapshot(unsupportedLimit: 3)
        let latency = latestInputLatencyMilliseconds()
        let nativeSteps = snapshot?.nativeBasicBlockSteps ?? 0
        let fallbackSteps = (snapshot?.decodedBasicBlockSteps ?? 0) + (snapshot?.swiftFallbackSingleInstructionSteps ?? 0)
        let nativeMS = Double(snapshot?.nativeBasicBlockNanoseconds ?? 0) / 1_000_000
        let fallbackMS = Double((snapshot?.decodedBasicBlockNanoseconds ?? 0) + (snapshot?.singleInstructionNanoseconds ?? 0)) / 1_000_000
        let nativeRate = nativeMS > 0 ? Double(nativeSteps) / nativeMS : 0
        let fallbackRate = fallbackMS > 0 ? Double(fallbackSteps) / fallbackMS : 0
        let throughputText = nativeMS > 0 || fallbackMS > 0
            ? "native \(Int(nativeRate.rounded()))k/s fallback \(Int(fallbackRate.rounded()))k/s"
            : "native \(nativeSteps.formatted()) fallback \(fallbackSteps.formatted())"
        let fallback = snapshot?.nativeIneligibleGadgets.first.map { " missing=\($0.name)" }
            ?? snapshot?.decodedFallbackGadgets.first.map { " hot=\($0.name)" }
            ?? ""
        let generic = (snapshot?.nativeGenericDispatches ?? 0) > 0
            ? " generic=\(snapshot?.nativeGenericDispatches ?? 0)"
            : ""
        let semanticFastPath = (softwareBackend?.nativeSemanticFastPathHits ?? 0) > 0
            ? " sfp=\(softwareBackend?.nativeSemanticFastPathHits ?? 0)" +
                "/\(softwareBackend?.nativeSemanticFastPathSteps ?? 0)"
            : ""
        let trace: String
        if let snapshot {
            let superblocks = " sb=\(snapshot.nativeSuperblockBlocks)/\(snapshot.nativeSuperblockDispatches)/f\(snapshot.nativeSuperblockFrontHits)"
            let directLinks = " dl=\(snapshot.nativeDirectLinkHits)/\(snapshot.nativeDirectLinkMisses)"
            let instructionTLB = " itlb=\(snapshot.nativeInstructionTLBHits)/\(snapshot.nativeInstructionTLBMisses)"
            let blockCache = " bc=\(snapshot.nativeBlockCacheHits)/\(snapshot.nativeBlockCacheMisses)"
            let prefetch = " pf\(snapshot.nativeBatchPrefetchLimit)=\(snapshot.nativeBatchPrefetchHits)/\(snapshot.nativeBatchPrefetchedBlocks)"
            let unusedPrefetch = " pfu=\(snapshot.nativeBatchPrefetchUnused)"
            let decodeWindow = " dw=\(snapshot.nativeDecodeWindowHits)/\(snapshot.nativeDecodeWindowMisses)"
            trace = superblocks + directLinks + instructionTLB + blockCache +
                prefetch + unusedPrefetch + decodeWindow
        } else {
            trace = ""
        }
        let unsupported = snapshot?.unsupportedInstructions.first.map {
            " unsupported=0x\(String($0.instruction, radix: 16))/\($0.count)"
        } ?? ""
        let hotPCs = softwareBackend?
            .nativeHotPCSnapshot(limit: 3)
            .map { "\(Self.hex($0.pc))/\($0.samples)" }
            .joined(separator: ",") ?? ""
        let hotPCTrace = hotPCs.isEmpty ? "" : " hpc=\(hotPCs)"
        let network = " net=tx\(networkBridge.transmittedFrameCount)" +
            "/gen\(networkBridge.generatedFrameCount)" +
            "/rx\(networkBridge.pendingReceiveFrameCount)" +
            "/tcp\(networkBridge.activeTCPConnectionCount)"
        let displayDiagnostics = machine.virtioDisplay.displayDiagnostics
        let display = displayDiagnostics.isEmpty ? "" : " \(displayDiagnostics)"
        let presentation = displayCommitSignal.diagnosticsSummary
        let latencyText = latency.map { " input=\(String(format: "%.1f", $0))ms" } ?? ""
        let touch = touchPipelineDiagnostics()
        let translationDiagnostics: String
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_PERFORMANCE"] == "1" {
            let tcr = machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.tcrEL1)
            let ttbr0 = machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.ttbr0EL1)
            let ttbr1 = machine.vm.systemRegisters.rawValue(for: ARM64SystemRegister.ttbr1EL1)
            let firstTranslationFault = machine.vm.exceptionTrace.first {
                $0.source == .translationFault
            }
            let firstFaultDiagnostics: String
            if let firstTranslationFault {
                let address = firstTranslationFault.faultAddress.map(Self.hex) ?? "none"
                let status = firstTranslationFault.faultStatusCode
                    .map { String($0.rawValue) } ?? "none"
                firstFaultDiagnostics =
                    " first-fault=\(address)/\(status)" +
                    "@\(Self.hex(firstTranslationFault.returnAddress))"
            } else {
                firstFaultDiagnostics = " first-fault=none"
            }
            if let fault = machine.vm.lastException {
                let faultAddress = fault.faultAddress.map(Self.hex) ?? "none"
                let status = fault.faultStatusCode.map { String($0.rawValue) } ?? "none"
                translationDiagnostics =
                    " tcr=\(Self.hex(tcr)) ttbr0=\(Self.hex(ttbr0))" +
                    " ttbr1=\(Self.hex(ttbr1)) exception=\(fault.source.rawValue)" +
                    " ec=\(fault.exceptionClass.rawValue) iss=\(Self.hex(fault.iss))" +
                    " far=\(faultAddress) fault-status=\(status)" +
                    " return=\(Self.hex(fault.returnAddress))\(firstFaultDiagnostics)"
            } else {
                translationDiagnostics =
                    " tcr=\(Self.hex(tcr)) ttbr0=\(Self.hex(ttbr0))" +
                    " ttbr1=\(Self.hex(ttbr1)) exception=none\(firstFaultDiagnostics)"
            }
        } else {
            translationDiagnostics = ""
        }
#else
        translationDiagnostics = ""
#endif
        return "\(throughputText)\(fallback)\(unsupported)\(latencyText)" +
            " pc=\(Self.hex(machine.vm.cpu.pc))\(network)\(display)\(presentation)" +
            "\(touch)\(trace)\(generic)\(semanticFastPath)\(hotPCTrace)" +
            "\(translationDiagnostics)"
    }

    var displayCommitSnapshot: DisplayCommitSignal.Snapshot {
        displayCommitSignal.snapshot
    }

    func waitForDisplayCommit(after generation: UInt64) async {
        await displayCommitSignal.wait(after: generation)
    }

    func displayFrameMetadata(
        afterGeneration previousGeneration: UInt64?
    ) -> VirtualFramebufferFrameMetadata? {
        guard let metadata = machine.virtioDisplay.displayFrameMetadata(
            afterGeneration: previousGeneration
        ) else {
            return nil
        }
        noteVisibleDisplayContent(metadata: metadata)
#if targetEnvironment(simulator)
        dumpFramebufferForDiagnosticsIfRequested()
#endif
        return metadata
    }

    func withDisplayFrameBytes(
        afterGeneration previousGeneration: UInt64?,
        _ body: (VirtualFramebufferFrameMetadata, UnsafeRawBufferPointer) -> Void
    ) -> VirtualFramebufferFrameMetadata? {
        machine.virtioDisplay.withDisplayFrameBytes(
            afterGeneration: previousGeneration,
            body
        )
    }

    func recordDisplayPublished(
        _ metadata: VirtualFramebufferFrameMetadata,
        publishedAtNanoseconds: UInt64
    ) {
        displayCommitSignal.notePublished(
            metadata: metadata,
            timestampNanoseconds: publishedAtNanoseconds
        )

        lock.lock()
        let latencySensitive = isTouchLatencySensitiveLocked(now: publishedAtNanoseconds)
        let baselineGeneration = touchBaselineDisplayGeneration
        let deliveredNanoseconds = latestTouchDeliveredNanoseconds
        guard latencySensitive,
              let deliveredNanoseconds,
              metadata.generation > baselineGeneration,
              metadata.commitTimestampNanoseconds >= deliveredNanoseconds else {
            lock.unlock()
            return
        }
        touchAwaitingFrame = false
        Self.appendLatencySampleLocked(
            metadata.commitTimestampNanoseconds - deliveredNanoseconds,
            to: &touchDeviceToFrameSamples
        )
        Self.appendLatencySampleLocked(
            publishedAtNanoseconds &- metadata.commitTimestampNanoseconds,
            to: &touchFrameToPublishSamples
        )
        if let queued = latestTouchQueuedNanoseconds {
            Self.appendLatencySampleLocked(
                publishedAtNanoseconds &- queued,
                to: &touchEndToEndSamples
            )
        }
        lock.unlock()
    }

    func recordDisplayPresented(
        generation: UInt64,
        uploadedBytes: Int,
        presentedAtNanoseconds: UInt64
    ) {
        displayCommitSignal.notePresented(
            generation: generation,
            uploadedBytes: uploadedBytes,
            timestampNanoseconds: presentedAtNanoseconds
        )
    }

    private func noteVisibleDisplayContent(metadata: VirtualFramebufferFrameMetadata) {
        lock.lock()
        let shellIsReady = shellPromptSeen
        let alreadyVisible = displayContentVisible
        let blankedAfterShell = displayBlankedAfterShell
        lock.unlock()
        guard shellIsReady, !alreadyVisible else {
            return
        }

        var foundVisiblePixel = false
        let previousGeneration = metadata.generation == 0 ? nil : metadata.generation - 1
        _ = machine.virtioDisplay.withDisplayFrameBytes(
            afterGeneration: previousGeneration
        ) { frame, bytes in
            guard frame.bytesPerPixel >= 3 else { return }
            let totalDamagePixels = max(
                1,
                frame.damage.reduce(0) { partial, rectangle in
                    partial + rectangle.width * rectangle.height
                }
            )
            let sampleBudget = 4_096
            for rectangle in frame.damage where !foundVisiblePixel {
                let rectanglePixels = rectangle.width * rectangle.height
                let rectangleBudget = max(
                    1,
                    sampleBudget * rectanglePixels / totalDamagePixels
                )
                let sampleStep = max(
                    1,
                    Int((Double(rectanglePixels) / Double(rectangleBudget)).squareRoot())
                )
                for y in stride(
                    from: rectangle.y,
                    to: rectangle.y + rectangle.height,
                    by: sampleStep
                ) {
                    for x in stride(
                        from: rectangle.x,
                        to: rectangle.x + rectangle.width,
                        by: sampleStep
                    ) {
                        let offset = y * frame.stride + x * frame.bytesPerPixel
                        guard offset + 2 < bytes.count else { continue }
                        if bytes[offset] > 16 || bytes[offset + 1] > 16 || bytes[offset + 2] > 16 {
                            foundVisiblePixel = true
                            break
                        }
                    }
                    if foundVisiblePixel { break }
                }
            }
        }
        guard foundVisiblePixel else {
            lock.lock()
            displayBlankedAfterShell = true
            lock.unlock()
            return
        }
        guard blankedAfterShell else {
            return
        }
        lock.lock()
        displayContentVisible = true
        lock.unlock()
    }

#if targetEnvironment(simulator)
    private func dumpFramebufferForDiagnosticsIfRequested() {
        guard ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_FRAMEBUFFER"] == "1" else {
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        guard lastFramebufferDumpNanoseconds == 0 || now - lastFramebufferDumpNanoseconds >= 2_000_000_000 else {
            return
        }
        lastFramebufferDumpNanoseconds = now
        guard let cacheDirectory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first else {
            return
        }
        guard let snapshot = machine.virtioDisplay.displaySnapshot() else {
            return
        }
        try? Data(snapshot.pixels).write(
            to: cacheDirectory.appendingPathComponent("pinecone-framebuffer.raw"),
            options: .atomic
        )
        if let backingSnapshot = machine.virtioDisplay.displayBackingSnapshot(memory: machine.vm.memory) {
            try? Data(backingSnapshot.pixels).write(
                to: cacheDirectory.appendingPathComponent("pinecone-framebuffer-backing.raw"),
                options: .atomic
            )
        }
    }
#endif

    private static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }

    private func drainInput(maxCount: Int) -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        let availableCount = pendingInput.count - pendingInputReadIndex
        let count = min(max(0, maxCount), availableCount)
        guard count > 0 else {
            return []
        }

        let startIndex = pendingInputReadIndex
        let endIndex = startIndex + count
        let bytes = Array(pendingInput[startIndex..<endIndex])
        pendingInputReadIndex = endIndex
        compactPendingInputLockedIfNeeded(force: pendingInputReadIndex == pendingInput.count)
        return bytes
    }

    private func compactPendingInputLockedIfNeeded(force: Bool) {
        guard pendingInputReadIndex > 0 else {
            return
        }

        if force ||
            (pendingInputReadIndex >= 4_096 && pendingInputReadIndex * 2 >= pendingInput.count) {
            pendingInput.removeFirst(pendingInputReadIndex)
            pendingInputReadIndex = 0
        }
    }

    private func drainTouches() -> [TouchEvent] {
        lock.lock()
        defer { lock.unlock() }

        var events: [TouchEvent] = []
        swap(&events, &pendingTouches)
        pendingTouchMoveIndex = nil
        drainedTouchEventCount += events.count
        return events
    }

    private func noteTouchDeliveredIfNeeded(previousDeliveredCount: Int?) {
        let deliveredCount = machine.virtioInput.inputFramesDelivered
        if let previousDeliveredCount, deliveredCount <= previousDeliveredCount {
            return
        }

        lock.lock()
        guard touchAwaitingFrame,
              latestTouchInjectedNanoseconds != nil,
              latestTouchDeliveredNanoseconds == nil else {
            lock.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        latestTouchDeliveredNanoseconds = now
        if let queued = latestTouchQueuedNanoseconds {
            Self.appendLatencySampleLocked(now &- queued, to: &touchQueueToDeviceSamples)
        }
        lock.unlock()
    }

    private func isTouchLatencySensitiveLocked(now: UInt64) -> Bool {
        guard touchInteractionActive || touchAwaitingFrame else {
            return false
        }
        guard let queued = latestTouchQueuedNanoseconds,
              now >= queued,
              now - queued <= Self.touchInteractionWatchdogNanoseconds else {
            touchInteractionActive = false
            touchAwaitingFrame = false
            return false
        }
        return true
    }

    private static func appendLatencySampleLocked(_ value: UInt64, to samples: inout [UInt64]) {
        if samples.count == Self.touchLatencySampleLimit {
            samples.removeFirst()
        }
        samples.append(value)
    }

    private static func latencyPercentileMilliseconds(_ samples: [UInt64], percentile: Double) -> Double? {
        guard !samples.isEmpty else {
            return nil
        }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * percentile).rounded(.up))
        )
        return Double(sorted[index]) / 1_000_000
    }

    private func touchPipelineDiagnostics() -> String {
        lock.lock()
        let queued = queuedTouchEventCount
        let drained = drainedTouchEventCount
        let dropped = droppedTouchEventCount
        let queueP95 = Self.latencyPercentileMilliseconds(touchQueueToDeviceSamples, percentile: 0.95)
        let renderP95 = Self.latencyPercentileMilliseconds(touchDeviceToFrameSamples, percentile: 0.95)
        let publishP95 = Self.latencyPercentileMilliseconds(touchFrameToPublishSamples, percentile: 0.95)
        let totalP95 = Self.latencyPercentileMilliseconds(touchEndToEndSamples, percentile: 0.95)
        lock.unlock()
        guard queued > 0 else {
            return ""
        }
        let latency = [queueP95, renderP95, publishP95, totalP95].map {
            $0.map { String(format: "%.1f", $0) } ?? "-"
        }.joined(separator: "/")
        return " hosttouch=\(queued)/\(drained)/\(dropped)" +
            " touchp95=\(latency)ms \(machine.virtioInput.inputDiagnostics)"
    }

    private func drainKeyboardEvents() -> [GuestKeyboardEvent] {
        lock.lock()
        defer { lock.unlock() }

        var events: [GuestKeyboardEvent] = []
        swap(&events, &pendingKeyboardEvents)
        return events
    }

    private func flushUARTOutput() {
        let output = uartOutputBuffer.drain()
        if !output.isEmpty {
            recordShellPromptIfNeeded(output)
            recordInputLatencyIfNeeded()
            onUART(output)
        }
    }

    private func latestInputLatencyMilliseconds() -> Double? {
        lock.lock()
        let latency = lastInputLatencyNanoseconds
        lock.unlock()
        return latency.map { Double($0) / 1_000_000 }
    }

    private func recordInputLatencyIfNeeded() {
        let now = DispatchTime.now().uptimeNanoseconds
        lock.lock()
        if let pendingInputTimestamp {
            lastInputLatencyNanoseconds = now &- pendingInputTimestamp
            self.pendingInputTimestamp = nil
        }
        lock.unlock()
    }

    private func recordShellPromptIfNeeded(_ bytes: [UInt8]) {
        lock.lock()
        defer { lock.unlock() }
        guard !shellPromptSeen else {
            return
        }

        uartPromptTail += String(decoding: bytes, as: UTF8.self)
        if uartPromptTail.count > 512 {
            uartPromptTail.removeFirst(uartPromptTail.count - 512)
        }
        let foundPrompt = uartPromptTail.contains("arm64viz-root:~#") ||
            uartPromptTail.contains("arm64viz-root #")
        if foundPrompt {
            shellPromptSeen = true
            displayContentVisible = false
            displayBlankedAfterShell = false
        }
    }

    private var shouldUseFrequentNetworkPumps: Bool {
        networkBridge.hasPendingAsynchronousTraffic
    }
}

private final class HostWakeSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]

    var currentGeneration: UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    func signal() {
        lock.lock()
        generation &+= 1
        let pending = Array(waiters.values)
        waiters.removeAll(keepingCapacity: true)
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }

    func wait(after observedGeneration: UInt64, timeoutNanoseconds: UInt64) async {
        await withCheckedContinuation { continuation in
            lock.lock()
            guard generation == observedGeneration else {
                lock.unlock()
                continuation.resume()
                return
            }

            let identifier = UUID()
            waiters[identifier] = continuation
            lock.unlock()

            let boundedTimeout = min(timeoutNanoseconds, UInt64(Int.max))
            DispatchQueue.global(qos: .userInitiated).asyncAfter(
                deadline: .now() + .nanoseconds(Int(boundedTimeout))
            ) { [weak self] in
                self?.resumeWaiter(identifier)
            }
        }
    }

    private func resumeWaiter(_ identifier: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: identifier)
        lock.unlock()
        continuation?.resume()
    }
}

private final class DisplayCommitSignal: @unchecked Sendable {
    struct Snapshot: Sendable {
        let generation: UInt64
        let timestampNanoseconds: UInt64
    }

    private let lock = NSLock()
    private var generation: UInt64 = 0
    private var timestampNanoseconds: UInt64 = 0
    private var waiters: [UUID: CheckedContinuation<Void, Never>] = [:]
    private var commitCount: UInt64 = 0
    private var publishedCount: UInt64 = 0
    private var presentedCount: UInt64 = 0
    private var coalescedCount: UInt64 = 0
    private var publishedDamageBytes: UInt64 = 0
    private var uploadedBytes: UInt64 = 0
    private var lastPublishedGeneration: UInt64 = 0
    private var lastPresentedGeneration: UInt64 = 0
    private var commitToPublishSamples: [UInt64] = []
    private var commitToPresentSamples: [UInt64] = []
    private var presentationTimestamps: [UInt64] = []
    private var publishedCommitTimestamps: [UInt64: UInt64] = [:]

    private static let sampleLimit = 120
    private static let activePresentationGapNanoseconds: UInt64 = 1_000_000_000

    var snapshot: Snapshot {
        lock.lock()
        let value = Snapshot(
            generation: generation,
            timestampNanoseconds: timestampNanoseconds
        )
        lock.unlock()
        return value
    }

    var diagnosticsSummary: String {
        lock.lock()
        let commits = commitCount
        let published = publishedCount
        let presented = presentedCount
        let coalesced = coalescedCount
        let damageKilobytes = publishedDamageBytes / 1024
        let uploadKilobytes = uploadedBytes / 1024
        let publishP95 = Self.percentileMilliseconds(commitToPublishSamples, percentile: 0.95)
        let presentP95 = Self.percentileMilliseconds(commitToPresentSamples, percentile: 0.95)
        let fps: Double
        if let first = presentationTimestamps.first,
           let last = presentationTimestamps.last,
           last > first,
           presentationTimestamps.count > 1 {
            fps = Double(presentationTimestamps.count - 1) * 1_000_000_000 /
                Double(last - first)
        } else {
            fps = 0
        }
        lock.unlock()
        guard commits > 0 else { return "" }
        return " ui=c\(commits)/p\(published)/r\(presented)/d\(coalesced)" +
            "@\(String(format: "%.1f", fps))fps" +
            " c2p=\(String(format: "%.1f", publishP95))/" +
            "\(String(format: "%.1f", presentP95))ms" +
            " bytes=\(damageKilobytes)/\(uploadKilobytes)K"
    }

    func note(generation: UInt64) {
        lock.lock()
        var pending: [CheckedContinuation<Void, Never>] = []
        if generation > self.generation {
            commitCount &+= generation &- self.generation
            self.generation = generation
            timestampNanoseconds = DispatchTime.now().uptimeNanoseconds
            pending = Array(waiters.values)
            waiters.removeAll(keepingCapacity: true)
        }
        lock.unlock()

        for continuation in pending {
            continuation.resume()
        }
    }

    func wait(after observedGeneration: UInt64) async {
        let identifier = UUID()
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                lock.lock()
                guard generation == observedGeneration, !Task.isCancelled else {
                    lock.unlock()
                    continuation.resume()
                    return
                }
                waiters[identifier] = continuation
                lock.unlock()
            }
        } onCancel: {
            resumeWaiter(identifier)
        }
    }

    func notePublished(
        metadata: VirtualFramebufferFrameMetadata,
        timestampNanoseconds: UInt64
    ) {
        lock.lock()
        guard metadata.generation > lastPublishedGeneration else {
            lock.unlock()
            return
        }
        lastPublishedGeneration = metadata.generation
        publishedCount &+= 1
        publishedDamageBytes &+= UInt64(metadata.damagedByteCount)
        publishedCommitTimestamps[metadata.generation] = metadata.commitTimestampNanoseconds
        if publishedCommitTimestamps.count > Self.sampleLimit {
            let staleGenerations = publishedCommitTimestamps.keys
                .sorted()
                .prefix(publishedCommitTimestamps.count - Self.sampleLimit)
            for staleGeneration in staleGenerations {
                publishedCommitTimestamps.removeValue(forKey: staleGeneration)
            }
        }
        if timestampNanoseconds >= metadata.commitTimestampNanoseconds {
            Self.append(
                timestampNanoseconds - metadata.commitTimestampNanoseconds,
                to: &commitToPublishSamples
            )
        }
        lock.unlock()
    }

    func notePresented(
        generation: UInt64,
        uploadedBytes frameUploadedBytes: Int,
        timestampNanoseconds: UInt64
    ) {
        lock.lock()
        guard generation > lastPresentedGeneration else {
            lock.unlock()
            return
        }
        if lastPresentedGeneration != 0,
           generation > lastPresentedGeneration &+ 1 {
            coalescedCount &+= generation &- lastPresentedGeneration &- 1
        }
        lastPresentedGeneration = generation
        presentedCount &+= 1
        uploadedBytes &+= UInt64(max(0, frameUploadedBytes))
        let commitTimestamp = publishedCommitTimestamps.removeValue(forKey: generation)
        publishedCommitTimestamps = publishedCommitTimestamps.filter { $0.key > generation }
        if let commitTimestamp,
           timestampNanoseconds >= commitTimestamp,
           timestampNanoseconds - commitTimestamp <= Self.activePresentationGapNanoseconds {
            Self.append(
                timestampNanoseconds - commitTimestamp,
                to: &commitToPresentSamples
            )
        }
        if let lastPresentation = presentationTimestamps.last,
           timestampNanoseconds <= lastPresentation ||
            timestampNanoseconds - lastPresentation > Self.activePresentationGapNanoseconds {
            presentationTimestamps.removeAll(keepingCapacity: true)
        }
        presentationTimestamps.append(timestampNanoseconds)
        if presentationTimestamps.count > Self.sampleLimit {
            presentationTimestamps.removeFirst(
                presentationTimestamps.count - Self.sampleLimit
            )
        }
        lock.unlock()
    }

    private func resumeWaiter(_ identifier: UUID) {
        lock.lock()
        let continuation = waiters.removeValue(forKey: identifier)
        lock.unlock()
        continuation?.resume()
    }

    private static func append(_ value: UInt64, to samples: inout [UInt64]) {
        samples.append(value)
        if samples.count > sampleLimit {
            samples.removeFirst(samples.count - sampleLimit)
        }
    }

    private static func percentileMilliseconds(
        _ samples: [UInt64],
        percentile: Double
    ) -> Double {
        guard !samples.isEmpty else { return 0 }
        let sorted = samples.sorted()
        let index = min(
            sorted.count - 1,
            Int((Double(sorted.count - 1) * percentile).rounded(.up))
        )
        return Double(sorted[index]) / 1_000_000
    }
}

private final class LockedByteBuffer: @unchecked Sendable {
    private static let maximumBufferedBytes = 256 * 1024

    private let lock = NSLock()
    private var bytes: [UInt8] = []

    init() {
        bytes.reserveCapacity(4 * 1024)
    }

    func append(_ byte: UInt8) {
        lock.lock()
        if bytes.count >= Self.maximumBufferedBytes {
            bytes.removeFirst(Self.maximumBufferedBytes / 2)
        }
        bytes.append(byte)
        lock.unlock()
    }

    func drain() -> [UInt8] {
        lock.lock()
        defer { lock.unlock() }

        var drained: [UInt8] = []
        swap(&drained, &bytes)
        return drained
    }
}

private final class UARTCoalescer: @unchecked Sendable {
    private static let maximumPendingBytes = 256 * 1024

    private let lock = NSLock()
    private let intervalNanoseconds: UInt64
    private let deliver: @Sendable ([UInt8]) async -> Void
    private var pendingBytes: [UInt8] = []
    private var deliveryScheduled = false
    private var cancelled = false

    init(
        intervalNanoseconds: UInt64,
        deliver: @escaping @Sendable ([UInt8]) async -> Void
    ) {
        self.intervalNanoseconds = intervalNanoseconds
        self.deliver = deliver
        pendingBytes.reserveCapacity(8 * 1024)
    }

    func append(_ bytes: [UInt8]) {
        guard !bytes.isEmpty else {
            return
        }

        var shouldSchedule = false
        lock.lock()
        if !cancelled {
            let overflow = pendingBytes.count + bytes.count - Self.maximumPendingBytes
            if overflow > 0 {
                pendingBytes.removeFirst(min(overflow, pendingBytes.count))
            }
            pendingBytes.append(contentsOf: bytes.suffix(Self.maximumPendingBytes))
            if !deliveryScheduled {
                deliveryScheduled = true
                shouldSchedule = true
            }
        }
        lock.unlock()

        if shouldSchedule {
            scheduleDeliveryLoop()
        }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        pendingBytes.removeAll(keepingCapacity: false)
        lock.unlock()
    }

    private func scheduleDeliveryLoop() {
        Task.detached(priority: .utility) { [weak self] in
            guard let self else {
                return
            }

            while true {
                try? await Task.sleep(nanoseconds: self.intervalNanoseconds)
                guard let bytes = self.takeNextBatch() else {
                    return
                }
                if !bytes.isEmpty {
                    await self.deliver(bytes)
                }
            }
        }
    }

    private func takeNextBatch() -> [UInt8]? {
        lock.lock()
        defer { lock.unlock() }

        if cancelled {
            deliveryScheduled = false
            return nil
        }
        if pendingBytes.isEmpty {
            deliveryScheduled = false
            return nil
        }

        var bytes: [UInt8] = []
        swap(&bytes, &pendingBytes)
        return bytes
    }
}

struct LinuxHostReport {
    let guest: String
    let profile: String
    let backend: String
    let shellTarget: String
    let kernelArtifact: String
    let initrdArtifact: String
    let entryPoint: String
    let fdtAddress: String
    let fdtByteCount: Int
    let bootArguments: String
    let traceBlocker: String
    let canExecuteNow: Bool
    let nextBackendWork: [String]
}
