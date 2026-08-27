import ARM64VizCore
import Combine
import Darwin
import Foundation

private func linuxConsoleBootArguments() -> String {
    var arguments = [
        "console=ttyAMA0",
        "root=/dev/vda",
        "rw",
        "rootwait",
        "rdinit=/init",
        "loglevel=4",
        "printk.time=1",
        "pinecone.unix_time=\(Int64(Date().timeIntervalSince1970))"
    ]
    if ProcessInfo.processInfo.environment["PINECONE_VERBOSE_BOOT"] == "1" {
        arguments.append(contentsOf: [
            "earlycon=pl011,mmio32,0x9000000",
            "loglevel=7",
            "ignore_loglevel",
            "print-fatal-signals=1"
        ])
    }
    return arguments.joined(separator: " ")
}

@MainActor
final class HostPerformanceFeed: ObservableObject {
    struct Snapshot: Equatable, Sendable {
        let steps: Int
        let nativeSteps: Int
        let fallbackSteps: Int
        let summary: String
    }

    @Published private(set) var snapshot = Snapshot(
        steps: 0,
        nativeSteps: 0,
        fallbackSteps: 0,
        summary: ""
    )

    func update(
        steps: Int,
        nativeSteps: Int,
        fallbackSteps: Int,
        summary: String
    ) {
        snapshot = Snapshot(
            steps: steps,
            nativeSteps: nativeSteps,
            fallbackSteps: fallbackSteps,
            summary: summary
        )
    }

    func reset() {
        snapshot = Snapshot(
            steps: 0,
            nativeSteps: 0,
            fallbackSteps: 0,
            summary: ""
        )
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
    @Published private(set) var isPhoshReady = false
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
    private var phoshLaunchCommandSent = false
    private var pendingTerminalControlBytes: [UInt8] = []

    private static let terminalLimit = 64_000
    private static let terminalFlushIntervalNanoseconds: UInt64 = 50_000_000
    private static let bootRunSliceSteps = 40_000
    private static let interactiveRunSliceSteps = 1_000_000
    private static let idleRunSliceSteps = 4_000
    private static let pendingInputRunSliceSteps = 2_000_000
    private static let bootProgressIntervalNanoseconds: UInt64 = 250_000_000
    private static let interactiveProgressIntervalNanoseconds: UInt64 = 2_000_000_000
    private static let displayPublicationIntervalNanoseconds: UInt64 = 16_666_667
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
        performanceFeed.update(
            steps: 0,
            nativeSteps: 0,
            fallbackSteps: 0,
            summary: "loading guest image"
        )
        kernelReport = nil
        linuxReport = nil
        terminalText = ""
        vmBootLog = ""
#if targetEnvironment(simulator)
        if let uartLogURL = Self.simulatorUARTLogURL {
            try? FileManager.default.removeItem(at: uartLogURL)
        }
#endif
        if let performanceLogURL = Self.performanceLogURL {
            try? FileManager.default.removeItem(at: performanceLogURL)
        }
        filesystemLoadingMessagePrinted = false
        phoshLaunchCommandSent = false
        isPhoshReady = false
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
                runtime.stopExecution()
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

    func displayFrameLease(
        afterGeneration previousGeneration: UInt64?
    ) -> VirtualFramebufferFrameLease? {
        runtime?.displayFrameLease(afterGeneration: previousGeneration)
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
        let detailedPerformanceEnabled = Self.performanceLogURL != nil

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
                    case .maxSteps, .yielded:
                        let now = DispatchTime.now().uptimeNanoseconds
                        let progressIntervalNanoseconds = runtime.hasSeenShellPrompt
                            ? interactiveProgressIntervalNanoseconds
                            : bootProgressIntervalNanoseconds

                        if lastProgressUpdate == 0 ||
                            now - lastProgressUpdate >= progressIntervalNanoseconds {
                            let counters = runtime.executionCounters()
                            await self?.recordRunnerProgress(
                                runIdentifier: runIdentifier,
                                steps: totalSteps,
                                nativeSteps: counters.native,
                                fallbackSteps: counters.fallback,
                                stopReason: stopReason,
                                pc: pc,
                                performance: detailedPerformanceEnabled
                                    ? runtime.performanceReport()
                                    : ""
                            )
                            lastProgressUpdate = now
                        }

                    default:
                        let counters = runtime.executionCounters()
                        await self?.recordRunnerProgress(
                            runIdentifier: runIdentifier,
                            steps: totalSteps,
                            nativeSteps: counters.native,
                            fallbackSteps: counters.fallback,
                            stopReason: stopReason,
                            pc: pc,
                            performance: detailedPerformanceEnabled
                                ? runtime.performanceReport()
                                : ""
                        )
                        await self?.recordRunnerStopped(runIdentifier: runIdentifier)

                        runtime.stopExecution()
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

                    runtime.stopExecution()
                    do {
                        try runtime.persistDiskImageIfNeeded()
                    } catch {
                        await self?.recordPersistenceFailure(String(describing: error))
                    }

                    await self?.runnerTaskDidFinish(runIdentifier: runIdentifier)
                    return
                }

                if runtime.shouldContinueInteractiveBurst {
                    continue
                } else if let generation = runtime.hostIdleWaitGeneration {
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
        let displayPublicationIntervalNanoseconds =
            Self.displayPublicationIntervalNanoseconds
        displayTask = Task.detached(priority: .userInitiated) { [weak self, runtime] in
            var publishedGeneration: UInt64?
            var nextPublicationNanoseconds: UInt64 = 0

            while !Task.isCancelled {
                var commit = runtime.displayCommitSnapshot
                if commit.generation == 0 || commit.generation == publishedGeneration {
                    await runtime.waitForDisplayCommit(after: commit.generation)
                    continue
                }

                let now = DispatchTime.now().uptimeNanoseconds
                if nextPublicationNanoseconds > now {
                    try? await Task.sleep(
                        nanoseconds: nextPublicationNanoseconds - now
                    )
                    guard !Task.isCancelled else { return }
                    commit = runtime.displayCommitSnapshot
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
                nextPublicationNanoseconds = publishedAt &+
                    displayPublicationIntervalNanoseconds
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
        nativeSteps: Int,
        fallbackSteps: Int,
        stopReason: String,
        pc: UInt64,
        performance: String
    ) {
        guard runIdentifier == self.runIdentifier else {
            return
        }
        lastStopReason = "\(stopReason) pc=\(Self.hex(pc))"
        performanceFeed.update(
            steps: steps,
            nativeSteps: nativeSteps,
            fallbackSteps: fallbackSteps,
            summary: performance
        )
        writePerformanceSnapshot(
            steps: steps,
            stopReason: stopReason,
            performance: performance
        )
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
        writePerformanceFailure(error: error, traceTail: traceTail)
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
        launchPhoshIfNeeded()
        if !isPhoshReady, runtime?.hasInteractiveWorkloadReady == true {
            isPhoshReady = true
        }
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

    private static var performanceLogURL: URL? {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PINECONE_DUMP_PERFORMANCE"] == "1" ||
                environment["PINECONE_SIMULATOR_DUMP_PERFORMANCE"] == "1",
              let cachesURL = FileManager.default.urls(
                for: .cachesDirectory,
                in: .userDomainMask
              ).first else {
            return nil
        }
        return cachesURL.appendingPathComponent("pinecone-performance.log")
    }

    private func writePerformanceSnapshot(
        steps: Int,
        stopReason: String,
        performance: String
    ) {
        guard let performanceLogURL = Self.performanceLogURL else { return }
        let snapshot = "steps=\(steps) stop=\(stopReason)\n\(performance)\n"
        try? Data(snapshot.utf8).write(to: performanceLogURL, options: .atomic)
    }

    private func writePerformanceFailure(error: String, traceTail: String?) {
        guard let performanceLogURL = Self.performanceLogURL else { return }
        var snapshot = "runner-failure=\(error)\n"
        if let traceTail, !traceTail.isEmpty {
            snapshot += "trace-tail:\n\(traceTail)\n"
        }
        try? Data(snapshot.utf8).write(to: performanceLogURL, options: .atomic)
    }

    private func launchPhoshIfNeeded() {
        guard !phoshLaunchCommandSent, hasShellPrompt else {
            return
        }
        phoshLaunchCommandSent = true
        runtime?.beginInteractiveWorkloadProfile()
#if targetEnvironment(simulator)
        let command = ProcessInfo.processInfo.environment[
            "PINECONE_SIMULATOR_AUTORUN_COMMAND"
        ] ?? "start-pinecone-phosh"
#else
        let command = "start-pinecone-phosh"
#endif
        sendTerminalInput(command)
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
            try cloneOrCopyDiskImage(
                from: bundledDiskURL,
                to: stagingURL,
                fileManager: fileManager
            )

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
        if let identityURL = Bundle.main.url(
            forResource: "rootfs.ext4",
            withExtension: "sha256"
        ),
        let identity = try? String(contentsOf: identityURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
        !identity.isEmpty {
            return identity
        }

        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
        return "size-\(byteCount)"
    }

    nonisolated private static func cloneOrCopyDiskImage(
        from sourceURL: URL,
        to destinationURL: URL,
        fileManager: FileManager
    ) throws {
        let cloneResult: Int32 = sourceURL.withUnsafeFileSystemRepresentation { sourcePath in
            destinationURL.withUnsafeFileSystemRepresentation { destinationPath in
                guard let sourcePath, let destinationPath else {
                    errno = EINVAL
                    return -1
                }
                return clonefile(sourcePath, destinationPath, 0)
            }
        }
        if cloneResult == 0 {
            return
        }

        let cloneError = errno
        do {
            try fileManager.copyItem(at: sourceURL, to: destinationURL)
        } catch {
            throw VMError.deviceError(
                "failed to provision persistent rootfs (clone errno \(cloneError)): \(error)"
            )
        }
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
    private static let bootChunkRunSliceSteps = 40_000
    private static let interactiveChunkRunSliceSteps = 1_000_000
    private static let pendingInputChunkRunSliceSteps = 80_000
    private static let touchDeliveryChunkRunSliceSteps = 131_072
    private static let touchRenderingChunkRunSliceSteps = 1_048_576
    private static let applicationLaunchChunkRunSliceSteps = 2_000_000
    private static let normalSecondaryRunSliceSteps = 262_144
    private static let touchDeliverySecondaryRunSliceSteps = 524_288
    private static let touchRenderingSecondaryRunSliceSteps = 1_048_576
    private static let applicationLaunchSecondaryRunSliceSteps = 1_048_576
    private static let normalWallClockRunBudgetNanoseconds: UInt64 = 20_000_000
    private static let touchDeliveryWallClockRunBudgetNanoseconds: UInt64 = 4_000_000
    private static let touchRenderingWallClockRunBudgetNanoseconds: UInt64 = 10_000_000
    private static let applicationLaunchWallClockRunBudgetNanoseconds: UInt64 = 12_000_000
    private static let maximumIdleTimerWaitNanoseconds: UInt64 = 250_000_000
    private static let maximumPendingInputBytes = 64 * 1024
    private static let maximumPendingTouchEvents = 256
    private static let maximumPendingKeyboardEvents = 4_096
    private static var virtualCPUCount: Int {
        let requested = ProcessInfo.processInfo.environment["PINECONE_VCPU_COUNT"]
            .flatMap(Int.init)
        return min(max(requested ?? 2, 1), 8)
    }
    private static var parallelVCPUExecutionEnabled: Bool {
        guard let configured = ProcessInfo.processInfo.environment[
            "PINECONE_EXPERIMENTAL_PARALLEL_VCPU"
        ] else {
            return true
        }
        return configured == "1"
    }
    private static let touchInteractionWatchdogNanoseconds: UInt64 = 2_000_000_000
    private static let applicationLaunchBoostNanoseconds: UInt64 = 5_000_000_000
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
    private let graphicsAccelerator: PineconeMetalGraphicsAccelerator?
    private let networkBridge: LinkLocalVirtIONetworkBackend
    private let hostWakeSignal: HostWakeSignal
    private let inputPreemptionSignal: InputPreemptionSignal
    private let displayCommitSignal: DisplayCommitSignal
    private let performanceTimeline = VMPerformanceTimeline()
    private let uartOutputBuffer: LockedByteBuffer
    private let onUART: @Sendable ([UInt8]) -> Void
    private let lock = NSLock()
    private let persistenceLock = NSLock()
    private var pendingInput: [UInt8] = []
    private var pendingInputReadIndex = 0
    private var pendingTouches: [TouchEvent] = []
    private var pendingTouchMoveIndex: Int?
    private var hostTouchContactActive = false
    private var lastAcceptedTouchPoint: (x: UInt32, y: UInt32)?
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
    private var touchInputFrameInFlight = false
    private var latestTouchQueuedNanoseconds: UInt64?
    private var inFlightTouchQueuedNanoseconds: UInt64?
    private var latestTouchInjectedNanoseconds: UInt64?
    private var latestTouchDeliveredNanoseconds: UInt64?
    private var touchDeliveryTargetFrameCount = 0
    private var touchBaselineDisplayGeneration: UInt64 = 0
    private enum ExecutionProfile: UInt8 {
        case normal
        case touchDelivery
        case touchRendering
        case applicationLaunch
    }

    private var executionProfile = ExecutionProfile.normal
    private var touchDeliverySlicePending = false
    private var touchQueueToDeviceSamples: [UInt64] = []
    private var touchDeviceToFrameSamples: [UInt64] = []
    private var touchFrameToPublishSamples: [UInt64] = []
    private var touchEndToEndSamples: [UInt64] = []
    private var wrotePresentedFrameMetrics = false
    private var shellPromptSeen = false
    private var lastRunSliceObservedWFI = false
    private var displayContentVisible = false
    private var displayBlankedAfterShell = false
    private var interactiveWorkloadReady = false
    private var applicationLaunchAwaitingFrame = false
    private var applicationLaunchFrameGeneration: UInt64?
    private var applicationLaunchBoostDeadlineNanoseconds: UInt64?
    private var uartPromptTail = ""
#if targetEnvironment(simulator)
    private var lastFramebufferDumpNanoseconds: UInt64 = 0
    private var postReadyActionsScheduled = false
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
            virtualCPUCount: Self.virtualCPUCount,
            parallelVCPUExecution:
                Self.virtualCPUCount > 1 && Self.parallelVCPUExecutionEnabled,
            publishedDevices: diskByteCount == 0 ? .linuxConsole : .full
        )
        let environment = ProcessInfo.processInfo.environment
        let hotPCProfilingEnabled = environment["PINECONE_HOT_PC_PROFILE"] == "1" ||
            environment["PINECONE_SIMULATOR_HOT_PC_PROFILE"] == "1"
        let detailedMemoryStatisticsEnabled =
            environment["PINECONE_DETAILED_MEMORY_STATS"] == "1"
        if let softwareBackend = machine.vm.backend as? SoftwareARM64Backend {
            softwareBackend.setNativeHotPCProfilingEnabled(hotPCProfilingEnabled)
            softwareBackend.setNativeDetailedMemoryStatisticsEnabled(
                detailedMemoryStatisticsEnabled
            )
            softwareBackend.setNativeDirectBulkMappingEnabled(
                environment["PINECONE_DIAGNOSTIC_DISABLE_BULK_MAPPING"] != "1"
            )
        }
        machine.parallelVCPUCluster?.setNativeDirectBulkMappingEnabled(
            environment["PINECONE_DIAGNOSTIC_DISABLE_BULK_MAPPING"] != "1"
        )
        machine.parallelVCPUCluster?.setNativeDetailedMemoryStatisticsEnabled(
            detailedMemoryStatisticsEnabled
        )
        let networkBridge = LinkLocalVirtIONetworkBackend()
        let graphicsAccelerator = PineconeMetalGraphicsAccelerator()
        let hostWakeSignal = HostWakeSignal()
        let inputPreemptionSignal = InputPreemptionSignal()
        let displayCommitSignal = DisplayCommitSignal()
        machine.parallelVCPUCluster?.setHostWakeHandler { [weak hostWakeSignal] in
            hostWakeSignal?.signal()
        }
        machine.virtioNetwork.attachNetworkBackend(networkBridge)
        machine.virtioDisplay.attachGraphicsAccelerator(graphicsAccelerator)
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
        machine.vm.memory.beginConcurrentExecution()
        if environment["PINECONE_DIAGNOSTIC_SYNCHRONIZE_ALL_RAM"] == "1" {
            machine.vm.memory.requireFullySynchronizedConcurrentAccess()
        }

        machine.vm.timerCyclesPerInstruction = 1
        machine.vm.wallClockRunBudgetNanoseconds =
            Self.normalWallClockRunBudgetNanoseconds
        machine.vm.nativeCheckpointBlockInterval = 4_096
        machine.vm.hostPreemptionGenerationProvider = { [weak inputPreemptionSignal] in
            inputPreemptionSignal?.currentGeneration ?? 0
        }
        if let backend = machine.vm.backend as? SoftwareARM64Backend {
            backend.enableBasicBlockExecution = true
            backend.fallbackInterpreterPolicy = .nativeOnly
        }
        machine.parallelVCPUCluster?.configureExecution(
            timerCyclesPerInstruction: machine.vm.timerCyclesPerInstruction,
            wallClockRunBudgetNanoseconds: machine.vm.wallClockRunBudgetNanoseconds,
            nativeCheckpointBlockInterval: machine.vm.nativeCheckpointBlockInterval,
            hostPreemptionGenerationProvider: machine.vm.hostPreemptionGenerationProvider,
            fallbackInterpreterPolicy: .nativeOnly
        )
        machine.vm.exceptionStormThreshold = 0
        machine.vm.systemRegisterTraceCapacity = 0
        machine.vm.systemRegisterReadTraceCapacity = 0
        machine.vm.disableInstructionTrace()
        machine.vm.enableMMIOTrace(capacity: 0)
        machine.uart.onByte = { byte in
            uartOutputBuffer.append(byte)
        }

        self.machine = machine
        self.graphicsAccelerator = graphicsAccelerator
        self.networkBridge = networkBridge
        self.hostWakeSignal = hostWakeSignal
        self.inputPreemptionSignal = inputPreemptionSignal
        self.displayCommitSignal = displayCommitSignal
        self.uartOutputBuffer = uartOutputBuffer
        self.onUART = onUART
        self.loadResult = result
        self.backendName = machine.vm.backend.name
        self.diskPersistenceURL = diskPersistenceURL
    }

    deinit {
        stopExecution()
    }

    func stopExecution() {
        machine.parallelVCPUCluster?.stop()
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
            inputPreemptionSignal.signal()
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
                lastAcceptedTouchPoint = (event.x, event.y)
                droppedTouchEventCount += 1
                accepted = true
            } else {
                pendingTouchMoveIndex = pendingTouches.count
                pendingTouches.append(event)
                lastAcceptedTouchPoint = (event.x, event.y)
                accepted = true
            }
        } else if event.isDown {
            hostTouchContactActive = true
            lastAcceptedTouchPoint = (event.x, event.y)
            pendingTouchMoveIndex = nil
            pendingTouches.append(event)
            accepted = true
        } else if hostTouchContactActive {
            hostTouchContactActive = false
            if lastAcceptedTouchPoint?.x != event.x ||
                lastAcceptedTouchPoint?.y != event.y {
                let finalMove = TouchEvent(
                    x: event.x,
                    y: event.y,
                    isDown: true
                )
                if let moveIndex = pendingTouchMoveIndex,
                   pendingTouches.indices.contains(moveIndex) {
                    pendingTouches[moveIndex] = finalMove
                } else {
                    pendingTouches.append(finalMove)
                }
            }
            pendingTouchMoveIndex = nil
            lastAcceptedTouchPoint = nil
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
        latestTouchQueuedNanoseconds = now

        lock.unlock()
        inputPreemptionSignal.signal()
        machine.parallelVCPUCluster?.signal()
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
        inputPreemptionSignal.signal()
        machine.parallelVCPUCluster?.signal()
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

    var hasInteractiveWorkloadReady: Bool {
        lock.lock()
        let result = interactiveWorkloadReady
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

    private var hasLatencySensitiveApplicationLaunch: Bool {
        lock.lock()
        let result = isApplicationLaunchLatencySensitiveLocked(
            now: DispatchTime.now().uptimeNanoseconds
        )
        lock.unlock()
        return result
    }

    private func isApplicationLaunchLatencySensitiveLocked(now: UInt64) -> Bool {
        guard applicationLaunchAwaitingFrame,
              let deadline = applicationLaunchBoostDeadlineNanoseconds else {
            return false
        }
        return now < deadline
    }

    var shouldContinueInteractiveBurst: Bool {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let latencySensitive = isTouchLatencySensitiveLocked(now: now)
        let baseline = touchBaselineDisplayGeneration
        lock.unlock()
        guard latencySensitive else { return false }
        return (machine.virtioDisplay.displayGeneration ?? 0) <= baseline
    }

    var shouldPaceContinuousExecution: Bool {
        lock.lock()
        let now = DispatchTime.now().uptimeNanoseconds
        let shouldPace = shellPromptSeen && displayContentVisible &&
            !lastRunSliceObservedWFI &&
            pendingInputReadIndex >= pendingInput.count &&
            pendingTouches.isEmpty && pendingKeyboardEvents.isEmpty &&
            !isTouchLatencySensitiveLocked(now: now) &&
            !isApplicationLaunchLatencySensitiveLocked(now: now)
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
        } else if isApplicationLaunchLatencySensitiveLocked(now: now) {
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
#if targetEnvironment(simulator)
            if touches.contains(where: \.isDown),
               ProcessInfo.processInfo.environment[
                   "PINECONE_SIMULATOR_RESET_HOT_PC_ON_TOUCH"
               ] == "1" {
                (machine.vm.backend as? SoftwareARM64Backend)?
                    .resetNativeHotPCProfile()
            }
#endif
            let injectionTime = DispatchTime.now().uptimeNanoseconds
            let baselineGeneration = machine.virtioDisplay.displayGeneration ?? 0
            lock.lock()
            touchInputFrameInFlight = true
            touchAwaitingFrame = true
            inFlightTouchQueuedNanoseconds = latestTouchQueuedNanoseconds
            latestTouchInjectedNanoseconds = injectionTime
            latestTouchDeliveredNanoseconds = nil
            touchDeliveryTargetFrameCount = Int.max
            touchBaselineDisplayGeneration = baselineGeneration
            touchDeliverySlicePending = true
            lock.unlock()
            for event in touches {
                machine.touch.enqueue(event)
            }
            machine.virtioInput.enqueueTouches(touches)
            let deliveryProgress =
                machine.virtioInput.inputFrameDeliveryProgress
            lock.lock()
            touchDeliveryTargetFrameCount = deliveryProgress.target
            lock.unlock()
            noteTouchDeliveredIfNeeded()
        }
        for event in drainKeyboardEvents() {
            machine.virtioKeyboard.enqueueKey(code: event.code, value: event.value)
        }
        let initialLatencySensitive = hasLatencySensitiveTouch
        let initialApplicationLaunch = hasLatencySensitiveApplicationLaunch
        configureExecutionProfile(
            touchActive: initialLatencySensitive,
            deliveryPending: hasPendingTouchDeliverySlice,
            applicationLaunchActive: initialApplicationLaunch
        )
        if !initialLatencySensitive {
            machine.virtioNetwork.pumpNetworkReceiveQueue()
        }
        var stepsRemaining = maxSteps
        var totalSteps = 0
        var lastException: ARM64ExceptionTraceEntry?

        while stepsRemaining > 0 {
            let responsivenessBudget: Int
            if hasPendingInput {
                responsivenessBudget = Self.pendingInputChunkRunSliceSteps
            } else if hasLatencySensitiveTouch {
                responsivenessBudget = hasPendingTouchDeliverySlice
                    ? Self.touchDeliveryChunkRunSliceSteps
                    : Self.touchRenderingChunkRunSliceSteps
            } else if hasLatencySensitiveApplicationLaunch {
                responsivenessBudget = Self.applicationLaunchChunkRunSliceSteps
            } else if hasSeenShellPrompt {
                responsivenessBudget = Self.interactiveChunkRunSliceSteps
            } else {
                responsivenessBudget = Self.bootChunkRunSliceSteps
            }
            var stepBudget = min(stepsRemaining, responsivenessBudget)
            let latencySensitive = hasLatencySensitiveTouch
            let applicationLaunchActive = hasLatencySensitiveApplicationLaunch
            let interactiveLatencySensitive =
                latencySensitive || applicationLaunchActive
            let deliveryPending = hasPendingTouchDeliverySlice
            configureExecutionProfile(
                touchActive: latencySensitive,
                deliveryPending: deliveryPending,
                applicationLaunchActive: applicationLaunchActive
            )
            if shouldUseFrequentNetworkPumps && !interactiveLatencySensitive {
                stepBudget = min(stepBudget, Self.networkPumpRunSliceSteps)
            }
            let result = try machine.vm.run(maxSteps: stepBudget)
            totalSteps += result.steps
            lastException = result.lastException
            flushUARTOutput()
            if !interactiveLatencySensitive {
                machine.virtioNetwork.pumpNetworkReceiveQueue()
            }
            noteTouchDeliveredIfNeeded()

            if latencySensitive && !shouldContinueInteractiveBurst {
                return RunResult(
                    steps: totalSteps,
                    stopReason: .maxSteps(totalSteps),
                    lastException: lastException
                )
            }

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
            if hasPendingInput {
                return RunResult(
                    steps: totalSteps,
                    stopReason: .maxSteps(totalSteps),
                    lastException: lastException
                )
            }
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
              !machine.vm.hasPendingInterruptForAnyVirtualCPU else {
            return nil
        }
        return generation
    }

    func waitForHostActivity(after generation: UInt64) async {
        let timerWait = machine.vm.hostTimerWaitNanoseconds ??
            Self.maximumIdleTimerWaitNanoseconds
        await hostWakeSignal.wait(
            after: generation,
            timeoutNanoseconds: min(
                timerWait,
                Self.maximumIdleTimerWaitNanoseconds
            )
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

    func executionCounters() -> (native: Int, fallback: Int) {
        guard let totals = (machine.vm.backend as? SoftwareARM64Backend)?
            .executionTotals() else {
            return (0, 0)
        }
        return (totals.nativeSteps, totals.fallbackSteps)
    }

    private func executionMilestoneSnapshot() -> VMExecutionMilestoneSnapshot {
        let counters = executionCounters()
        let cluster = machine.parallelVCPUCluster
        let secondaryTotals = cluster?.secondaryExecutionTotals ?? (
            nativeSteps: UInt64(0),
            fallbackSteps: UInt64(0)
        )
        return VMExecutionMilestoneSnapshot(
            primaryNativeSteps: counters.native,
            primaryFallbackSteps: counters.fallback,
            secondarySteps: cluster?.secondaryExecutedSteps ?? 0,
            secondaryNativeSteps: secondaryTotals.nativeSteps,
            secondaryFallbackSteps: secondaryTotals.fallbackSteps
        )
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
            let instructionTLB = " itlb=\(snapshot.nativeInstructionTLBHits)/\(snapshot.nativeInstructionTLBMisses)" +
                ":h\(snapshot.nativeInstructionTLBHotHits)" +
                ":c\(snapshot.nativeInstructionTLBColdMisses)" +
                ":x\(snapshot.nativeInstructionTLBConflictMisses)" +
                ":i\(snapshot.nativeInstructionTLBInvalidationMisses)"
            let dataTLB = " dtlb=r\(snapshot.nativeReadTLBHits)/\(snapshot.nativeReadTLBMisses)" +
                ":w\(snapshot.nativeWriteTLBHits)/\(snapshot.nativeWriteTLBMisses)"
            let blockCache = " bc=\(snapshot.nativeBlockCacheHits)/\(snapshot.nativeBlockCacheMisses)"
            let prefetch = " pf\(snapshot.nativeBatchPrefetchLimit)=\(snapshot.nativeBatchPrefetchHits)/\(snapshot.nativeBatchPrefetchedBlocks)"
            let unusedPrefetch = " pfu=\(snapshot.nativeBatchPrefetchUnused)"
            let decodeWindow = " dw=\(snapshot.nativeDecodeWindowHits)/\(snapshot.nativeDecodeWindowMisses)"
            trace = superblocks + directLinks + instructionTLB + dataTLB + blockCache +
                prefetch + unusedPrefetch + decodeWindow
        } else {
            trace = ""
        }
        let unsupported = snapshot?.unsupportedInstructions.first.map {
            " unsupported=0x\(String($0.instruction, radix: 16))/\($0.count)"
        } ?? ""
        let hotPCs = softwareBackend?
            .nativeHotPCSnapshot(limit: 3)
            .map {
                let words = $0.instructions
                    .map { String(format: "%08x", $0) }
                    .joined(separator: ".")
                return "\(Self.hex($0.pc))/\($0.samples)/lr\(Self.hex($0.linkRegister))/\(words)"
            }
            .joined(separator: ",") ?? ""
        let hotPCTrace = hotPCs.isEmpty ? "" : " hpc=\(hotPCs)"
        let network = " net=tx\(networkBridge.transmittedFrameCount)" +
            "/gen\(networkBridge.generatedFrameCount)" +
            "/rx\(networkBridge.pendingReceiveFrameCount)" +
            "/tcp\(networkBridge.activeTCPConnectionCount)"
        let displayDiagnostics = machine.virtioDisplay.displayDiagnostics
        let display = displayDiagnostics.isEmpty ? "" : " \(displayDiagnostics)"
        let metalDiagnostics = graphicsAccelerator?.diagnosticsSummary ?? ""
        let metal = metalDiagnostics.isEmpty ? "" : " \(metalDiagnostics)"
        let presentation = displayCommitSignal.diagnosticsSummary
        let latencyText = latency.map { " input=\(String(format: "%.1f", $0))ms" } ?? ""
        let touch = touchPipelineDiagnostics()
        let interruptDiagnostics: String
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_PERFORMANCE"] == "1" {
            let controller = machine.vm.interruptController
            let diagnostics = controller.diagnostics()
            let pending = diagnostics.pendingLines.contains(33) ? 1 : 0
            let active = diagnostics.activeLines.contains(33) ? 1 : 0
            let enabled = diagnostics.enabledLines.contains(33) ? 1 : 0
            interruptDiagnostics =
                " uart=rx\(machine.uart.receiveFIFOCount)" +
                "/raw\(String(machine.uart.rawInterruptStatusValue, radix: 16))" +
                "/mask\(String(machine.uart.interruptMaskValue, radix: 16))" +
                "/t\(String(controller.targetMask(line: 33), radix: 16))" +
                "/p\(pending)/a\(active)/e\(enabled)"
        } else {
            interruptDiagnostics = ""
        }
#else
        interruptDiagnostics = ""
#endif
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
        let virtualCPUDetails: String
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_DUMP_PERFORMANCE"] == "1" {
            virtualCPUDetails = machine.vm.virtualCPUStates.map { state in
                let lifecycle = String(state.lifecycle.rawValue.prefix(1))
                return "\(state.id):\(lifecycle)@\(Self.hex(state.cpu.pc))" +
                    "/sp\(Self.hex(state.cpu.sp))/el\(state.cpu.currentExceptionLevel)"
            }.joined(separator: ",")
        } else {
            virtualCPUDetails = ""
        }
#else
        virtualCPUDetails = ""
#endif
        let virtualCPUs = " vcpu=\(machine.vm.activeVCPUID + 1)/\(machine.vm.virtualCPUCount)" +
            "/w\(machine.vm.waitingVirtualCPUCount)" +
            (virtualCPUDetails.isEmpty ? "" : "[\(virtualCPUDetails)]")
        let parallelVCPUs = machine.parallelVCPUCluster?.diagnosticsSummary ?? ""
        let timelineSnapshot = performanceTimeline.snapshot()
        let shellMilliseconds = timelineSnapshot.elapsedMilliseconds[
            VMPerformanceMilestone.shellPrompt.rawValue
        ]
        let frameMilliseconds = timelineSnapshot.elapsedMilliseconds[
            VMPerformanceMilestone.firstVisibleFrame.rawValue
        ]
        let workloadStartMilliseconds = timelineSnapshot.elapsedMilliseconds[
            VMPerformanceMilestone.interactiveWorkloadStarted.rawValue
        ]
        let workloadReadyMilliseconds = timelineSnapshot.elapsedMilliseconds[
            VMPerformanceMilestone.interactiveWorkloadReady.rawValue
        ]
        let bootTimeline = " boot=" +
            (shellMilliseconds.map { String(format: "%.0f", $0) } ?? "-") + "/" +
            (frameMilliseconds.map { String(format: "%.0f", $0) } ?? "-") + "ms"
        let workloadTimeline = " workload=" +
            (workloadStartMilliseconds.map { String(format: "%.0f", $0) } ?? "-") + "/" +
            (workloadReadyMilliseconds.map { String(format: "%.0f", $0) } ?? "-") + "ms"
        return "\(throughputText)\(fallback)\(unsupported)\(latencyText)\(virtualCPUs)\(parallelVCPUs)" +
            " pc=\(Self.hex(machine.vm.cpu.pc))\(network)\(display)\(metal)\(presentation)" +
            "\(touch)\(interruptDiagnostics)\(trace)\(generic)\(semanticFastPath)\(hotPCTrace)" +
            "\(translationDiagnostics)\(bootTimeline)\(workloadTimeline)"
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

    func displayFrameLease(
        afterGeneration previousGeneration: UInt64?
    ) -> VirtualFramebufferFrameLease? {
        machine.virtioDisplay.displayFrameLease(
            afterGeneration: previousGeneration
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
        performanceTimeline.recordFramePublished(
            generation: metadata.generation,
            committedAtNanoseconds: metadata.commitTimestampNanoseconds,
            publishedAtNanoseconds: publishedAtNanoseconds,
            damagedByteCount: metadata.damagedByteCount
        )

        lock.lock()
        let shouldInspectApplicationFrame =
            applicationLaunchAwaitingFrame &&
            applicationLaunchFrameGeneration == nil
        lock.unlock()
        if shouldInspectApplicationFrame,
           isSubstantialVisibleApplicationFrame(metadata: metadata) {
            lock.lock()
            if applicationLaunchAwaitingFrame &&
                applicationLaunchFrameGeneration == nil {
                applicationLaunchFrameGeneration = metadata.generation
            }
            lock.unlock()
        }

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
        touchInputFrameInFlight = false
        touchDeliverySlicePending = false
        touchDeliveryTargetFrameCount = 0
        Self.appendLatencySampleLocked(
            metadata.commitTimestampNanoseconds - deliveredNanoseconds,
            to: &touchDeviceToFrameSamples
        )
        Self.appendLatencySampleLocked(
            publishedAtNanoseconds &- metadata.commitTimestampNanoseconds,
            to: &touchFrameToPublishSamples
        )
        if let queued = inFlightTouchQueuedNanoseconds {
            let endToEnd = publishedAtNanoseconds &- queued
            Self.appendLatencySampleLocked(
                endToEnd,
                to: &touchEndToEndSamples
            )
            performanceTimeline.recordTouchLatency(nanoseconds: endToEnd)
        }
        inFlightTouchQueuedNanoseconds = nil
        lock.unlock()
        hostWakeSignal.signal()
        writePerformanceMetricsIfRequested()
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
        performanceTimeline.recordFramePresented(
            generation: generation,
            presentedAtNanoseconds: presentedAtNanoseconds,
            uploadedByteCount: uploadedBytes
        )
        lock.lock()
        let completedApplicationLaunch =
            applicationLaunchAwaitingFrame &&
            applicationLaunchFrameGeneration.map { generation >= $0 } == true
        if completedApplicationLaunch {
            applicationLaunchAwaitingFrame = false
            applicationLaunchFrameGeneration = nil
            applicationLaunchBoostDeadlineNanoseconds = nil
        }
        let shouldWriteMetrics = !wrotePresentedFrameMetrics
        wrotePresentedFrameMetrics = true
        lock.unlock()
        if completedApplicationLaunch {
            _ = performanceTimeline.mark(
                .applicationFirstVisibleFrame,
                execution: executionMilestoneSnapshot()
            )
        }
        if shouldWriteMetrics {
            writePerformanceMetricsIfRequested()
        } else if completedApplicationLaunch {
            writePerformanceMetricsIfRequested()
        }
    }

    func beginInteractiveWorkloadProfile() {
        _ = performanceTimeline.mark(
            .interactiveWorkloadStarted,
            execution: executionMilestoneSnapshot()
        )
#if targetEnvironment(simulator)
        if ProcessInfo.processInfo.environment["PINECONE_SIMULATOR_HOT_PC_PROFILE"] == "1" {
            (machine.vm.backend as? SoftwareARM64Backend)?.resetNativeHotPCProfile()
        }
#endif
        writePerformanceMetricsIfRequested()
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
        if performanceTimeline.mark(
            .firstVisibleFrame,
            execution: executionMilestoneSnapshot()
        ) {
            writePerformanceMetricsIfRequested()
        }
    }

    private func isSubstantialVisibleApplicationFrame(
        metadata: VirtualFramebufferFrameMetadata
    ) -> Bool {
        let framePixels = metadata.width * metadata.height
        let damagedPixels = metadata.damage.reduce(0) { partial, rectangle in
            partial + rectangle.width * rectangle.height
        }
        guard framePixels > 0, damagedPixels >= framePixels / 8 else {
            return false
        }

        var visibleSamples = 0
        var sampledPixels = 0
        let previousGeneration = metadata.generation == 0
            ? nil
            : metadata.generation - 1
        _ = machine.virtioDisplay.withDisplayFrameBytes(
            afterGeneration: previousGeneration
        ) { frame, bytes in
            guard frame.bytesPerPixel >= 3 else { return }
            let sampleBudget = 2_048
            let sampleStep = max(
                1,
                Int((Double(max(1, damagedPixels)) /
                    Double(sampleBudget)).squareRoot())
            )
            for rectangle in frame.damage {
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
                        sampledPixels += 1
                        if bytes[offset] > 16 || bytes[offset + 1] > 16 ||
                            bytes[offset + 2] > 16 {
                            visibleSamples += 1
                        }
                    }
                }
            }
        }
        return sampledPixels > 0 && visibleSamples * 100 >= sampledPixels
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

    private var hasPendingTouchDeliverySlice: Bool {
        lock.lock()
        let pending = touchDeliverySlicePending
        lock.unlock()
        return pending
    }

    private func configureExecutionProfile(
        touchActive: Bool,
        deliveryPending: Bool,
        applicationLaunchActive: Bool
    ) {
        let profile: ExecutionProfile
        if touchActive {
            profile = deliveryPending ? .touchDelivery : .touchRendering
        } else if applicationLaunchActive {
            profile = .applicationLaunch
        } else {
            profile = .normal
        }
        lock.lock()
        guard executionProfile != profile else {
            lock.unlock()
            return
        }
        executionProfile = profile
        lock.unlock()

        let wallClockBudget: UInt64
        let checkpointInterval: UInt64
        switch profile {
        case .touchDelivery:
            wallClockBudget = Self.touchDeliveryWallClockRunBudgetNanoseconds
            checkpointInterval = 1_024
        case .touchRendering:
            wallClockBudget = Self.touchRenderingWallClockRunBudgetNanoseconds
            checkpointInterval = 4_096
        case .applicationLaunch:
            wallClockBudget = Self.applicationLaunchWallClockRunBudgetNanoseconds
            checkpointInterval = 8_192
        case .normal:
            wallClockBudget = Self.normalWallClockRunBudgetNanoseconds
            checkpointInterval = 4_096
        }
        machine.vm.wallClockRunBudgetNanoseconds = wallClockBudget
        machine.vm.nativeCheckpointBlockInterval = checkpointInterval
        machine.parallelVCPUCluster?.configureRunBudget(
            wallClockRunBudgetNanoseconds: wallClockBudget,
            nativeCheckpointBlockInterval: checkpointInterval,
            secondaryRunStepBudget: switch profile {
            case .touchDelivery:
                Self.touchDeliverySecondaryRunSliceSteps
            case .touchRendering:
                Self.touchRenderingSecondaryRunSliceSteps
            case .applicationLaunch:
                Self.applicationLaunchSecondaryRunSliceSteps
            case .normal:
                Self.normalSecondaryRunSliceSteps
            }
        )
    }

    private func noteTouchDeliveredIfNeeded() {
        let deliveryProgress = machine.virtioInput.inputFrameDeliveryProgress

        lock.lock()
        guard touchAwaitingFrame,
              latestTouchInjectedNanoseconds != nil,
              latestTouchDeliveredNanoseconds == nil,
              touchDeliveryTargetFrameCount > 0,
              deliveryProgress.delivered >=
                touchDeliveryTargetFrameCount else {
            lock.unlock()
            return
        }
        let now = DispatchTime.now().uptimeNanoseconds
        latestTouchDeliveredNanoseconds = now
        touchDeliverySlicePending = false
        if let queued = inFlightTouchQueuedNanoseconds {
            Self.appendLatencySampleLocked(now &- queued, to: &touchQueueToDeviceSamples)
        }
        lock.unlock()
    }

    private func isTouchLatencySensitiveLocked(now: UInt64) -> Bool {
        guard touchInteractionActive || touchAwaitingFrame else {
            return false
        }
        let activityTimestamp = inFlightTouchQueuedNanoseconds ??
            latestTouchQueuedNanoseconds
        guard let queued = activityTimestamp,
              now >= queued,
              now - queued <= Self.touchInteractionWatchdogNanoseconds else {
            touchInteractionActive = false
            touchAwaitingFrame = false
            touchInputFrameInFlight = false
            touchDeliverySlicePending = false
            touchDeliveryTargetFrameCount = 0
            inFlightTouchQueuedNanoseconds = nil
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
        var schedulePostReadyActions = false
        lock.lock()
        uartPromptTail += String(decoding: bytes, as: UTF8.self)
        if uartPromptTail.count > 1_024 {
            uartPromptTail.removeFirst(uartPromptTail.count - 1_024)
        }
        let foundPrompt = !shellPromptSeen && (
            uartPromptTail.contains("arm64viz-root:~#") ||
                uartPromptTail.contains("arm64viz-root #")
        )
        let foundWorkloadReady = uartPromptTail.contains("Phosh ready after")
        var foundApplicationLaunch = false
        let applicationLaunchMarker = "Pinecone app launch requested:"
        while let markerRange = uartPromptTail.range(
            of: applicationLaunchMarker
        ) {
            foundApplicationLaunch = true
            uartPromptTail.removeSubrange(markerRange)
        }
        if foundPrompt {
            shellPromptSeen = true
            displayContentVisible = false
            displayBlankedAfterShell = false
        }
        if foundWorkloadReady {
            interactiveWorkloadReady = true
#if targetEnvironment(simulator)
            let environment = ProcessInfo.processInfo.environment
            if !postReadyActionsScheduled && (
                environment["PINECONE_SIMULATOR_AUTO_UNLOCK"] == "1" ||
                !(environment["PINECONE_SIMULATOR_POST_READY_COMMAND"] ?? "")
                    .isEmpty
            ) {
                postReadyActionsScheduled = true
                schedulePostReadyActions = true
            }
#endif
        }
        if foundApplicationLaunch {
            let now = DispatchTime.now().uptimeNanoseconds
            applicationLaunchAwaitingFrame = true
            applicationLaunchFrameGeneration = nil
            applicationLaunchBoostDeadlineNanoseconds = now &+
                Self.applicationLaunchBoostNanoseconds
            lastHostActivityNanoseconds = now
        }
        lock.unlock()
        if foundPrompt, performanceTimeline.mark(
            .shellPrompt,
            execution: executionMilestoneSnapshot()
        ) {
            writePerformanceMetricsIfRequested()
        }
        if foundWorkloadReady, performanceTimeline.mark(
            .interactiveWorkloadReady,
            execution: executionMilestoneSnapshot()
        ) {
            writePerformanceMetricsIfRequested()
        }
        if foundApplicationLaunch, performanceTimeline.mark(
            .applicationLaunchRequested,
            execution: executionMilestoneSnapshot()
        ) {
#if targetEnvironment(simulator)
            if ProcessInfo.processInfo.environment[
                "PINECONE_SIMULATOR_HOT_PC_PROFILE"
            ] == "1" {
                (machine.vm.backend as? SoftwareARM64Backend)?
                    .resetNativeHotPCProfile()
            }
#endif
            writePerformanceMetricsIfRequested()
        }
#if targetEnvironment(simulator)
        if schedulePostReadyActions {
            scheduleSimulatorPostReadyActions()
        }
#endif
    }

#if targetEnvironment(simulator)
    private func scheduleSimulatorPostReadyActions() {
        let environment = ProcessInfo.processInfo.environment
        let shouldUnlock = environment["PINECONE_SIMULATOR_AUTO_UNLOCK"] == "1"
        let postReadyCommand = environment[
            "PINECONE_SIMULATOR_POST_READY_COMMAND"
        ].flatMap { $0.isEmpty ? nil : $0 }
        let configuredDelayMilliseconds = environment[
            "PINECONE_SIMULATOR_POST_READY_DELAY_MS"
        ].flatMap { UInt32($0) }
        let commandDelayMilliseconds = configuredDelayMilliseconds ??
            (shouldUnlock ? 2_000 : 0)

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self else { return }
            if shouldUnlock {
                usleep(500_000)
                let x: UInt32 = 240
                let startY: UInt32 = 940
                let endY: UInt32 = 64
                let moveCount: UInt32 = 18
                self.queueTouch(TouchEvent(x: x, y: startY, isDown: true))
                for move in 1...moveCount {
                    usleep(100_000)
                    let distance = UInt64(startY - endY) * UInt64(move)
                    let y = startY - UInt32(distance / UInt64(moveCount))
                    self.queueTouch(TouchEvent(x: x, y: y, isDown: true))
                }
                usleep(100_000)
                self.queueTouch(TouchEvent(x: x, y: endY, isDown: false))
            }
            guard let postReadyCommand else { return }
            if commandDelayMilliseconds > 0 {
                Thread.sleep(
                    forTimeInterval: Double(commandDelayMilliseconds) / 1_000
                )
            }
            self.queueInput(Array((postReadyCommand + "\n").utf8))
        }
    }
#endif

    private func writePerformanceMetricsIfRequested() {
        let environment = ProcessInfo.processInfo.environment
        guard environment["PINECONE_WRITE_PERFORMANCE_METRICS"] == "1" ||
                environment["PINECONE_SIMULATOR_WRITE_PERFORMANCE_METRICS"] == "1",
        let cacheDirectory = FileManager.default.urls(
            for: .cachesDirectory,
            in: .userDomainMask
        ).first,
        let data = try? JSONEncoder().encode(performanceTimeline.snapshot()) else {
            return
        }
        try? data.write(
            to: cacheDirectory.appendingPathComponent("pinecone-performance.json"),
            options: .atomic
        )
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

private final class InputPreemptionSignal: @unchecked Sendable {
    private let lock = NSLock()
    private var generation: UInt64 = 0

    var currentGeneration: UInt64 {
        lock.lock()
        let value = generation
        lock.unlock()
        return value
    }

    func signal() {
        lock.lock()
        generation &+= 1
        lock.unlock()
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
