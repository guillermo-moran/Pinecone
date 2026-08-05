import ARM64VizCore
import Darwin
import Foundation

@main
struct ARM64VizCommand {
    static func main() {
        do {
            try run(arguments: Array(CommandLine.arguments.dropFirst()))
        } catch {
            fputs("arm64viz: \(error)\n", stderr)
            exit(1)
        }
    }

    private static func run(arguments: [String]) throws {
        let command = arguments.first ?? "run-toy"
        switch command {
        case "run-toy":
            try runToy()
        case "run-mobile":
            try disabledJavaScriptMobileOSCommand(command)
        case "build-mobile-image":
            try disabledJavaScriptMobileOSCommand(command)
        case "mobile-kernel-demo":
            try disabledJavaScriptMobileOSCommand(command)
        case "prepare-linux":
            try prepareLinux(arguments: arguments)
        case "run-linux-trace":
            try runLinuxTrace(arguments: arguments)
        case "diff-linux-blocks":
            try diffLinuxBlocks(arguments: arguments)
        case "audit-instructions":
            try InstructionCoverageCommand.run(arguments: arguments)
        case "dump-dts":
            try dumpDTS()
        case "snapshot":
            try snapshot()
        case "validate-manifest":
            try validateManifest(path: requiredPath(arguments), preferencesPath: optionalValue(after: "--preferences", in: arguments))
        case "policy-show":
            try showPolicy(preferencesPath: optionalValue(after: "--preferences", in: arguments))
        case "adapters":
            try listAdapters()
        case "plan-boot":
            try planBoot(arguments: arguments)
        case "help", "--help", "-h":
            printHelp()
        default:
            printHelp()
            throw VMError.deviceError("unknown command: \(command)")
        }
    }

    private static func runToy() throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.uart.onByte = { byte in
            FileHandle.standardOutput.write(Data([byte]))
        }

        _ = try ToyUARTGuestAdapter().load(into: machine.vm)
        let result = try machine.vm.run(maxSteps: 10_000)
        print("")
        print("[arm64viz] backend=\(machine.vm.backend.name)")
        print("[arm64viz] stop=\(result.stopReason) steps=\(result.steps)")
    }

    private static func runMobile(imagePath: String?, verboseBoot: Bool) throws {
        let machine = try MachineFactory.makeResearchMachine()
        machine.uart.onByte = { byte in
            FileHandle.standardOutput.write(Data([byte]))
        }

        let image = try loadMobileOSImage(path: imagePath, verboseBoot: verboseBoot)
        if imagePath != nil, verboseBoot, !image.manifest.verboseBoot {
            print("[arm64viz] note=--verbose requested; supplied image was not built with verboseBoot=true")
        }
        let bootConfig = try MobileOSImageBootAdapter(image: image).load(into: machine.vm)
        let result = try machine.vm.run(maxSteps: 50_000)
        print("")
        print("[arm64viz] guest=\(bootConfig.machineName)")
        print("[arm64viz] image=\(image.manifest.imageName) version=\(image.manifest.version) verbose=\(image.manifest.verboseBoot)")
        print("[arm64viz] backend=\(machine.vm.backend.name)")
        print("[arm64viz] stop=\(result.stopReason) steps=\(result.steps)")
    }

    private static func buildMobileImage(path: String, verboseBoot: Bool) throws {
        let image = MobileOSImage.developmentImage(verboseBoot: verboseBoot)
        let data = try Data(image.encodedArtifact())
        try data.write(to: URL(fileURLWithPath: path))
        print("[arm64viz] wrote \(path)")
        print("[arm64viz] image=\(image.manifest.imageName) version=\(image.manifest.version) verbose=\(image.manifest.verboseBoot) bytes=\(data.count)")
    }

    private static func runMobileKernelDemo() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let kernel = MobileOSKernel()
        let report = try kernel.boot(on: machine)

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(report)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func disabledJavaScriptMobileOSCommand(_ command: String) throws {
        throw VMError.unsupportedGuest("\(command): \(RuntimeDirection.javascriptMobileOSDisabledReason). Use prepare-linux for the active native Linux/postmarketOS path.")
    }

    private static func prepareLinux(arguments: [String]) throws {
        let prepared = try prepareLinuxMachine(arguments: arguments)
        let machine = prepared.machine
        let result = prepared.loadResult
        try dumpGeneratedDTBIfRequested(result.deviceTreeBlob, arguments: arguments)

        let summary = LinuxPrepareSummary(
            guest: result.configuration.machineName,
            profile: result.layout.profile.rawValue,
            backend: machine.vm.backend.name,
            entryPoint: hex(result.layout.kernelLoadAddress),
            fdtAddress: hex(result.layout.fdtLoadAddress),
            fdtByteCount: result.layout.fdtByteCount,
            initrdAddress: result.layout.initrdLoadAddress.map(hex),
            initrdByteCount: result.layout.initrdByteCount,
            diskByteCount: result.layout.diskByteCount,
            suppliedDeviceTree: result.layout.usedSuppliedDeviceTree,
            bootArguments: result.layout.bootArguments,
            cpuX0: hex(machine.vm.cpu.x[0]),
            pstate: hex(machine.vm.cpu.pstate),
            currentEL: "EL\(machine.vm.cpu.currentExceptionLevel)",
            sp: hex(machine.vm.cpu.sp),
            canExecuteNow: true,
            nextBackendWork: [
                "Linux-grade IRQ/FIQ priority, masking, EOI, and nesting behavior",
                "Broader MMU attributes, shareability, cacheability, and TLB maintenance",
                "GIC/timer driver compatibility beyond the current minimal model",
                "PL011 FIFO depth, baud/control registers, and interrupt edge cases",
                "virtio descriptor-ring execution for net/input/display"
            ]
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func runLinuxTrace(arguments: [String]) throws {
        let prepared = try prepareLinuxMachine(arguments: arguments)
        let machine = prepared.machine
        let result = prepared.loadResult
        try dumpGeneratedDTBIfRequested(result.deviceTreeBlob, arguments: arguments)
        let maxSteps = try optionalInt(after: "--max-steps", in: arguments) ?? 128
        let traceDepth = try optionalNonNegativeInt(after: "--trace-depth", in: arguments) ?? 32
        let exceptionStormThreshold = try optionalNonNegativeInt(after: "--exception-storm-threshold", in: arguments) ?? 16
        let symbolMapPath = try optionalValue(after: "--symbols", in: arguments)
        let symbols = try symbolMapPath.map { try KernelSymbolMap(path: $0) }
        let breakpoints = try values(after: "--breakpoint", in: arguments).map(parseAddress)
        let breakpointSkips = try values(after: "--breakpoint-skip", in: arguments).map(parseBreakpointSkip)
        let stopOnEL0 = hasFlag("--stop-on-el0", in: arguments)
        let stopOnEL0Fault = hasFlag("--stop-on-el0-fault", in: arguments)
        let el0FaultSkip = try optionalNonNegativeInt(after: "--el0-fault-skip", in: arguments) ?? 0
        let stopOnUART = hasFlag("--stop-on-uart", in: arguments)
        let stopOnUARTOutput = try optionalValue(after: "--stop-on-uart-output", in: arguments).map(decodeEscapedArgument)
        let streamUART = hasFlag("--stream-uart", in: arguments)
        let mmioTraceDepth = try optionalNonNegativeInt(after: "--mmio-trace-depth", in: arguments) ?? 64
        let memoryTraceDepth = try optionalNonNegativeInt(after: "--memory-trace-depth", in: arguments) ?? 0
        let memoryTraceEL0Only = hasFlag("--memory-trace-el0-only", in: arguments)
        let stopOnMemoryWriteVirtual = try optionalValue(after: "--stop-on-memory-write-virtual", in: arguments).map(parseAddress)
        let stopOnMemoryWritePhysical = try optionalValue(after: "--stop-on-memory-write-physical", in: arguments).map(parseAddress)
        let memoryWriteSkip = try optionalNonNegativeInt(after: "--memory-write-skip", in: arguments) ?? 0
        let sysregTraceDepth = try optionalNonNegativeInt(after: "--sysreg-trace-depth", in: arguments) ?? 128
        let timerScale = UInt64(try optionalNonNegativeInt(after: "--timer-scale", in: arguments) ?? 1)
        let uartInputBytes = try linuxTraceUARTInputBytes(arguments: arguments)
        let uartInputAfterOutput = try optionalValue(after: "--uart-input-after-output", in: arguments).map(decodeEscapedArgument)
        let writebackDiskPath = try optionalValue(after: "--writeback-disk", in: arguments)
        let profileBackendTiming = hasFlag("--profile-backend-timing", in: arguments)
        let wallClockBudgetMS = try optionalNonNegativeInt(after: "--wall-clock-budget-ms", in: arguments)
        var uartInputInjected = false

        if let backend = machine.vm.backend as? SoftwareARM64Backend {
            backend.collectPerformanceTimings = profileBackendTiming
        }

        for breakpoint in breakpoints {
            machine.vm.breakpoints.insert(breakpoint)
        }
        for (address, skipCount) in breakpointSkips {
            machine.vm.breakpoints.insert(address)
            machine.vm.breakpointSkipCounts[address] = skipCount
        }
        machine.vm.stopOnEL0Entry = stopOnEL0
        machine.vm.stopOnEL0Fault = stopOnEL0Fault
        machine.vm.el0FaultStopSkipCount = el0FaultSkip
        machine.vm.stopOnUARTOutput = stopOnUART
        machine.vm.stopOnUARTOutputContaining = stopOnUARTOutput
        machine.vm.stopOnGuestMemoryWriteVirtualAddress = stopOnMemoryWriteVirtual
        machine.vm.stopOnGuestMemoryWritePhysicalAddress = stopOnMemoryWritePhysical
        machine.vm.guestMemoryWriteStopSkipCount = memoryWriteSkip
        machine.vm.timerCyclesPerInstruction = timerScale
        machine.vm.wallClockRunBudgetNanoseconds = wallClockBudgetMS.map { UInt64($0) * 1_000_000 }
        machine.vm.exceptionStormThreshold = exceptionStormThreshold
        machine.vm.systemRegisterTraceCapacity = sysregTraceDepth
        machine.vm.systemRegisterReadTraceCapacity = sysregTraceDepth
        machine.vm.enableInstructionTrace(capacity: traceDepth)
        machine.vm.enableMMIOTrace(capacity: mmioTraceDepth)
        machine.vm.enableGuestMemoryTrace(capacity: memoryTraceDepth, el0Only: memoryTraceEL0Only)
        let cursorPositionQuery: [UInt8] = [0x1b, 0x5b, 0x36, 0x6e]
        let cursorPositionReply: [UInt8] = Array("\u{001B}[1;1R".utf8)
        var recentUARTOutput: [UInt8] = []
        if streamUART || uartInputAfterOutput != nil || stopOnUARTOutput != nil || !uartInputBytes.isEmpty {
            machine.uart.onByte = { byte in
                if streamUART {
                    FileHandle.standardError.write(Data([byte]))
                }
                recentUARTOutput.append(byte)
                if recentUARTOutput.count > cursorPositionQuery.count {
                    recentUARTOutput.removeFirst(recentUARTOutput.count - cursorPositionQuery.count)
                }
                if recentUARTOutput == cursorPositionQuery {
                    machine.uart.injectReceiveBytes(cursorPositionReply)
                    recentUARTOutput.removeAll(keepingCapacity: true)
                }
                if !uartInputInjected,
                   let uartInputAfterOutput,
                   machine.uart.outputString.contains(uartInputAfterOutput) {
                    machine.uart.injectReceiveBytes(uartInputBytes)
                    uartInputInjected = true
                }
            }
        }
        if !uartInputBytes.isEmpty, uartInputAfterOutput == nil {
            machine.uart.injectReceiveBytes(uartInputBytes)
            uartInputInjected = true
        }

        var stopReason: String?
        var runtimeError: String?
        var lastException: ARM64ExceptionTraceEntry?
        var executedSteps: Int?
        let runSliceQuantum = uartInputAfterOutput == nil ? 5_000_000 : 250_000
        do {
            var totalSteps = 0
            var finalResult: RunResult?
            var remainingSteps = maxSteps

            if remainingSteps == 0 {
                finalResult = RunResult(steps: 0, stopReason: .maxSteps(0), lastException: machine.vm.lastException)
            }

            while remainingSteps > 0 {
                machine.virtioNetwork.pumpNetworkReceiveQueue()
                let sliceSteps = min(remainingSteps, runSliceQuantum)
                let runResult = try machine.vm.run(maxSteps: sliceSteps)
                machine.virtioNetwork.pumpNetworkReceiveQueue()
                totalSteps += runResult.steps
                finalResult = runResult

                if case .maxSteps = runResult.stopReason, runResult.steps == sliceSteps {
                    remainingSteps -= runResult.steps
                } else {
                    remainingSteps = 0
                }
            }

            if let finalResult {
                if totalSteps >= maxSteps, case .maxSteps = finalResult.stopReason {
                    stopReason = RunStopReason.maxSteps(maxSteps).description
                } else {
                    stopReason = finalResult.stopReason.description
                }
                lastException = finalResult.lastException
                executedSteps = totalSteps
            }
        } catch {
            runtimeError = String(describing: error)
            lastException = machine.vm.lastException
        }
        if let writebackDiskPath {
            try Data(machine.virtioBlock.storageBytes).write(to: URL(fileURLWithPath: writebackDiskPath))
        }

        let lastInstruction = machine.vm.instructionTrace.last
        let exception = lastException ?? machine.vm.lastException
        let physicalKernelLoadAddress = result.layout.kernelLoadAddress
        let backendPerformance = (machine.vm.backend as? SoftwareARM64Backend)?.performanceSnapshot()
        let recentMemoryAccesses = machine.vm.guestMemoryTrace.map {
            guestMemoryTraceSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress)
        }
        let summary = LinuxTraceSummary(
            guest: result.configuration.machineName,
            profile: result.layout.profile.rawValue,
            backend: machine.vm.backend.name,
            entryPoint: hex(result.layout.kernelLoadAddress),
            fdtAddress: hex(result.layout.fdtLoadAddress),
            fdtByteCount: result.layout.fdtByteCount,
            initrdAddress: result.layout.initrdLoadAddress.map(hex),
            initrdByteCount: result.layout.initrdByteCount,
            diskByteCount: result.layout.diskByteCount,
            suppliedDeviceTree: result.layout.usedSuppliedDeviceTree,
            bootArguments: result.layout.bootArguments,
            maxSteps: maxSteps,
            executedSteps: executedSteps,
            exceptionStormThreshold: exceptionStormThreshold,
            breakpoints: breakpoints.map(hex),
            stopOnEL0: stopOnEL0,
            stopOnEL0Fault: stopOnEL0Fault,
            el0FaultSkip: el0FaultSkip,
            stopOnUART: stopOnUART,
            stopOnUARTOutput: stopOnUARTOutput,
            streamUART: streamUART,
            uartInputByteCount: uartInputBytes.count,
            uartInputInjected: uartInputInjected,
            uartInputAfterOutput: uartInputAfterOutput,
            mmioTraceDepth: mmioTraceDepth,
            memoryTraceDepth: memoryTraceDepth,
            memoryTraceEL0Only: memoryTraceEL0Only,
            stopOnMemoryWriteVirtual: stopOnMemoryWriteVirtual.map(hex),
            stopOnMemoryWritePhysical: stopOnMemoryWritePhysical.map(hex),
            memoryWriteSkip: memoryWriteSkip,
            observedMemoryWriteWatchCount: machine.vm.observedGuestMemoryWriteWatchCount,
            sysregTraceDepth: sysregTraceDepth,
            timerScale: timerScale,
            waitForInterruptCount: machine.vm.waitForInterruptCount,
            waitForEventCount: machine.vm.waitForEventCount,
            timerFastForwardCount: machine.vm.timerFastForwardCount,
            timerFastForwardCycles: machine.vm.timerFastForwardCycles,
            virtioBlockRequests: machine.virtioBlock.completedBlockRequests,
            virtioBlockRequestTypes: machine.virtioBlock.blockRequestTypeCounts.map {
                VirtIOBlockRequestTypeSummary(
                    requestType: $0.requestType,
                    name: $0.name,
                    count: $0.count
                )
            },
            virtioBlockRecentRequests: machine.virtioBlock.recentBlockRequestSummaries,
            virtioNetworkTransmits: machine.virtioNetwork.completedNetworkTransmits,
            virtioNetworkReceives: machine.virtioNetwork.completedNetworkReceives,
            linkLocalTransmittedFrames: prepared.networkBackend.transmittedFrameCount,
            linkLocalGeneratedFrames: prepared.networkBackend.generatedFrameCount,
            linkLocalRecentFrames: prepared.networkBackend.recentFrameSummaries,
            el0FaultCount: machine.vm.observedEL0FaultCount,
            translationCacheHits: machine.vm.translationCacheHits,
            translationCacheMisses: machine.vm.translationCacheMisses,
            backendPerformance: backendPerformance,
            symbolMap: symbols.map { SymbolMapSummary(path: symbolMapPath ?? "", symbolCount: $0.symbolCount) },
            stopReason: stopReason,
            error: runtimeError,
            pc: hex(machine.vm.cpu.pc),
            pcPhysical: translatedInstructionAddress(machine.vm.cpu.pc, vm: machine.vm).map(hex),
            pcSymbol: instructionSymbol(
                machine.vm.cpu.pc,
                vm: machine.vm,
                symbols: symbols,
                physicalKernelLoadAddress: physicalKernelLoadAddress
            ),
            pstate: hex(machine.vm.cpu.pstate),
            currentEL: "EL\(machine.vm.cpu.currentExceptionLevel)",
            sp: hex(machine.vm.cpu.sp),
            instruction: lastInstruction.map { hex(UInt64($0.instruction)) },
            decodedInstruction: lastInstruction?.decode,
            lastException: exception.map { exceptionSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress) },
            uartOutputByteCount: machine.uart.outputBytes.count,
            uartOutputTail: utf8Tail(machine.uart.outputBytes, maxBytes: 4096),
            registers: traceRegisters(machine.vm.cpu),
            systemRegisters: traceSystemRegisters(machine.vm.systemRegisters, cpu: machine.vm.cpu),
            stackFrames: stackFrames(
                vm: machine.vm,
                symbols: symbols,
                physicalKernelLoadAddress: physicalKernelLoadAddress,
                maxDepth: 16
            ),
            memblock: memblockSummary(
                vm: machine.vm,
                symbols: symbols,
                physicalKernelLoadAddress: physicalKernelLoadAddress
            ),
            interruptState: interruptStateSummary(machine.vm),
            interruptDiagnostics: machine.vm.interruptController.diagnostics(),
            translationWalk: exception.flatMap { translationWalkSummary(for: $0, vm: machine.vm) },
            firstEL0Entry: machine.vm.firstEL0Entry.map {
                executionStateSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress)
            },
            recentInstructions: machine.vm.instructionTrace.map { entry in
                InstructionTraceSummary(
                    step: entry.step,
                    pc: hex(entry.pc),
                    physicalPC: translatedInstructionAddress(entry.pc, vm: machine.vm).map(hex),
                    symbol: instructionSymbol(
                        entry.pc,
                        vm: machine.vm,
                        symbols: symbols,
                        physicalKernelLoadAddress: physicalKernelLoadAddress
                    ),
                    instruction: hex(UInt64(entry.instruction)),
                    decode: entry.decode,
                    pstateBefore: hex(entry.pstateBefore),
                    pstateAfter: entry.pstateAfter.map(hex)
                )
            },
            recentExceptions: machine.vm.exceptionTrace.map {
                exceptionSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress)
            },
            exceptionCounts: exceptionCounts(
                machine.vm.exceptionTrace,
                symbols: symbols,
                physicalKernelLoadAddress: physicalKernelLoadAddress
            ),
            recentSystemRegisterWrites: machine.vm.systemRegisterTrace.map(systemRegisterWriteSummary),
            recentSystemRegisterReads: machine.vm.systemRegisterReadTrace.map(systemRegisterReadSummary),
            executionStateTransitions: machine.vm.executionStateTrace.map {
                executionStateSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress)
            },
            recentMMIOAccesses: machine.vm.mmioTrace.map {
                mmioTraceSummary($0, symbols: symbols, physicalKernelLoadAddress: physicalKernelLoadAddress)
            },
            recentMemoryAccesses: recentMemoryAccesses,
            globalMMIOAccessCounts: mmioAccessCounts(machine.vm.mmioAccessCounters),
            mmioAccessCounts: mmioAccessCounts(machine.vm.mmioTrace),
            nextBackendWork: linuxBackendWork(after: lastInstruction, runtimeError: runtimeError, exception: exception)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func prepareLinuxMachine(arguments: [String]) throws -> PreparedLinuxMachine {
        let positional = positionalArguments(in: arguments)
        guard let kernelPath = positional.first else {
            throw VMError.deviceError("missing Linux ARM64 Image path")
        }

        let kernel = try Data(contentsOf: URL(fileURLWithPath: kernelPath))
        let initrd = try optionalData(path: optionalValue(after: "--initrd", in: arguments))
        let dtb = try optionalData(path: optionalValue(after: "--dtb", in: arguments))
        let disk = try optionalData(path: optionalValue(after: "--disk", in: arguments))
        let memoryMiB = try optionalInt(after: "--memory-mib", in: arguments) ?? 512
        let memorySize = memoryMiB * 1024 * 1024
        let blockStorageSize = max(1024 * 1024, disk?.count ?? 0)
        let profile: LinuxGuestProfile = hasFlag("--postmarketos", in: arguments) ? .postmarketOS : .generic
        let publishedDevices: ResearchMachineDevicePublication = hasFlag("--minimal-devices", in: arguments) ? .linuxConsole : .full

        let machine = try MachineFactory.makeResearchMachine(
            memorySize: memorySize,
            blockStorageSize: blockStorageSize,
            publishedDevices: publishedDevices
        )
        let networkBackend = LinkLocalVirtIONetworkBackend()
        machine.virtioNetwork.attachNetworkBackend(networkBackend)
        let adapter = LinuxDirectBootAdapter(
            artifacts: LinuxBootArtifacts(
                kernelImage: [UInt8](kernel),
                initrd: initrd.map { [UInt8]($0) },
                deviceTreeBlob: dtb.map { [UInt8]($0) },
                diskImage: disk.map { [UInt8]($0) }
            ),
            profile: profile,
            bootArguments: try optionalValue(after: "--bootargs", in: arguments)
        )

        return PreparedLinuxMachine(
            machine: machine,
            loadResult: try adapter.loadWithResult(into: machine.vm),
            networkBackend: networkBackend
        )
    }

    private static func diffLinuxBlocks(arguments: [String]) throws {
        let maxSteps = try optionalInt(after: "--max-steps", in: arguments) ?? 1_000_000
        let chunkSteps = try optionalInt(after: "--chunk-steps", in: arguments) ?? 32
        let progressSteps = try optionalNonNegativeInt(after: "--progress-steps", in: arguments) ?? 100_000
        let debugChunks = hasFlag("--debug-chunks", in: arguments)
        let timerScale = UInt64(try optionalNonNegativeInt(after: "--timer-scale", in: arguments) ?? 1)
        let reference = try prepareLinuxMachine(arguments: arguments)
        let candidate = try prepareLinuxMachine(arguments: arguments)

        guard
            let referenceBackend = reference.machine.vm.backend as? SoftwareARM64Backend,
            let candidateBackend = candidate.machine.vm.backend as? SoftwareARM64Backend
        else {
            throw VMError.deviceError("differential runner requires SoftwareARM64Backend")
        }

        referenceBackend.enableBasicBlockExecution = false
        candidateBackend.enableBasicBlockExecution = true
        for machine in [reference.machine, candidate.machine] {
            machine.vm.exceptionStormThreshold = 0
            machine.vm.timerCyclesPerInstruction = timerScale
            machine.vm.traceCapacity = 0
            machine.vm.exceptionTraceCapacity = 0
            machine.vm.systemRegisterTraceCapacity = 0
            machine.vm.systemRegisterReadTraceCapacity = 0
            machine.vm.executionStateTraceCapacity = 0
            machine.vm.mmioTraceCapacity = 0
            machine.vm.guestMemoryTraceCapacity = 0
        }

        var matchedSteps = 0
        var nextProgress = progressSteps
        while matchedSteps < maxSteps {
            let requested = min(chunkSteps, maxSteps - matchedSteps)
            let windowStart = matchedSteps
            if debugChunks {
                fputs("diff-linux-blocks: reference start=\(windowStart) count=\(requested)\n", stderr)
            }
            let referenceResult = try reference.machine.vm.run(maxSteps: requested)
            if debugChunks {
                fputs("diff-linux-blocks: candidate start=\(windowStart) count=\(requested)\n", stderr)
            }
            let candidateResult = try candidate.machine.vm.run(maxSteps: requested)
            let differences = differentialStateDifferences(
                reference: reference.machine,
                candidate: candidate.machine,
                referenceResult: referenceResult,
                candidateResult: candidateResult
            )

            if !differences.isEmpty {
                try emitLinuxBlockDifferentialReport(
                    status: "diverged",
                    matchedSteps: matchedSteps,
                    divergentWindowStart: windowStart,
                    divergentWindowEnd: windowStart + max(referenceResult.steps, candidateResult.steps),
                    chunkSteps: chunkSteps,
                    differences: differences,
                    reference: reference.machine,
                    candidate: candidate.machine,
                    candidateBackend: candidateBackend
                )
                throw VMError.deviceError("native block engine diverged after \(matchedSteps) matched instructions")
            }

            matchedSteps += referenceResult.steps
            if progressSteps > 0, matchedSteps >= nextProgress {
                fputs("diff-linux-blocks: matched \(matchedSteps) instructions\n", stderr)
                nextProgress = matchedSteps + progressSteps
            }
            if referenceResult.steps == 0 || referenceResult.stopReason != .maxSteps(requested) {
                break
            }
        }

        try emitLinuxBlockDifferentialReport(
            status: "matched",
            matchedSteps: matchedSteps,
            divergentWindowStart: nil,
            divergentWindowEnd: nil,
            chunkSteps: chunkSteps,
            differences: [],
            reference: reference.machine,
            candidate: candidate.machine,
            candidateBackend: candidateBackend
        )
    }

    private static func differentialStateDifferences(
        reference: ResearchMachine,
        candidate: ResearchMachine,
        referenceResult: RunResult,
        candidateResult: RunResult
    ) -> [String] {
        var differences: [String] = []
        if referenceResult.steps != candidateResult.steps {
            differences.append("steps: reference=\(referenceResult.steps) candidate=\(candidateResult.steps)")
        }
        if referenceResult.stopReason != candidateResult.stopReason {
            differences.append("stopReason: reference=\(referenceResult.stopReason) candidate=\(candidateResult.stopReason)")
        }
        let referenceCPU = reference.vm.cpu
        let candidateCPU = candidate.vm.cpu
        for index in 0..<min(referenceCPU.x.count, candidateCPU.x.count) where referenceCPU.x[index] != candidateCPU.x[index] {
            differences.append("x\(index): reference=\(hex(referenceCPU.x[index])) candidate=\(hex(candidateCPU.x[index]))")
        }
        for index in 0..<min(referenceCPU.v.count, candidateCPU.v.count) where referenceCPU.v[index] != candidateCPU.v[index] {
            differences.append("v\(index): reference=\(vectorHex(referenceCPU.v[index])) candidate=\(vectorHex(candidateCPU.v[index]))")
        }
        if referenceCPU.sp != candidateCPU.sp {
            differences.append("sp: reference=\(hex(referenceCPU.sp)) candidate=\(hex(candidateCPU.sp))")
        }
        if referenceCPU.spEL1 != candidateCPU.spEL1 {
            differences.append("spEL1: reference=\(hex(referenceCPU.spEL1)) candidate=\(hex(candidateCPU.spEL1))")
        }
        if referenceCPU.pc != candidateCPU.pc {
            differences.append("pc: reference=\(hex(referenceCPU.pc)) candidate=\(hex(candidateCPU.pc))")
        }
        if referenceCPU.pstate != candidateCPU.pstate {
            differences.append("pstate: reference=\(hex(referenceCPU.pstate)) candidate=\(hex(candidateCPU.pstate))")
        }
        if referenceCPU.halted != candidateCPU.halted {
            differences.append("halted: reference=\(referenceCPU.halted) candidate=\(candidateCPU.halted)")
        }
        if referenceCPU.exclusiveReservationAddress != candidateCPU.exclusiveReservationAddress ||
            referenceCPU.exclusiveReservationSize != candidateCPU.exclusiveReservationSize {
            differences.append("exclusive reservation differs")
        }
        if reference.vm.systemRegisters != candidate.vm.systemRegisters {
            differences.append("system register bank differs")
        }
        if reference.uart.outputBytes != candidate.uart.outputBytes {
            differences.append("UART output differs: reference=\(reference.uart.outputBytes.count) bytes candidate=\(candidate.uart.outputBytes.count) bytes")
        }
        return differences
    }

    private static func emitLinuxBlockDifferentialReport(
        status: String,
        matchedSteps: Int,
        divergentWindowStart: Int?,
        divergentWindowEnd: Int?,
        chunkSteps: Int,
        differences: [String],
        reference: ResearchMachine,
        candidate: ResearchMachine,
        candidateBackend: SoftwareARM64Backend
    ) throws {
        let report = LinuxBlockDifferentialReport(
            status: status,
            matchedSteps: matchedSteps,
            divergentWindowStart: divergentWindowStart,
            divergentWindowEnd: divergentWindowEnd,
            chunkSteps: chunkSteps,
            differences: differences,
            reference: differentialCPUState(reference.vm),
            candidate: differentialCPUState(candidate.vm),
            referenceUARTBytes: reference.uart.outputBytes.count,
            candidateUARTBytes: candidate.uart.outputBytes.count,
            candidatePerformance: candidateBackend.performanceSnapshot()
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        FileHandle.standardOutput.write(try encoder.encode(report))
        print("")
    }

    private static func differentialCPUState(_ vm: VirtualMachine) -> DifferentialCPUState {
        let instruction = try? vm.readGuest(vm.cpu.pc, width: .word, access: .instruction)
        return DifferentialCPUState(
            pc: hex(vm.cpu.pc),
            instruction: instruction.map { hex($0) },
            pstate: hex(vm.cpu.pstate),
            currentEL: String(vm.cpu.currentExceptionLevel),
            sp: hex(vm.cpu.sp),
            spEL1: hex(vm.cpu.spEL1),
            counterTicks: vm.systemRegisters.counterTicks,
            registers: vm.cpu.x.map(hex)
        )
    }

    private static func vectorHex(_ value: ARM64VectorRegister) -> String {
        String(format: "0x%016llx%016llx", value.high, value.low)
    }

    private static func dumpGeneratedDTBIfRequested(_ bytes: [UInt8], arguments: [String]) throws {
        guard let path = try optionalValue(after: "--dump-generated-dtb", in: arguments) else {
            return
        }
        try Data(bytes).write(to: URL(fileURLWithPath: path))
    }

    private static func dumpDTS() throws {
        let machine = try MachineFactory.makeResearchMachine()
        let bootConfig = try ToyUARTGuestAdapter().load(into: machine.vm)
        print(bootConfig.renderDTS())
    }

    private static func snapshot() throws {
        let machine = try MachineFactory.makeResearchMachine()
        _ = try ToyUARTGuestAdapter().load(into: machine.vm)
        _ = try machine.vm.run(maxSteps: 10_000)

        let snapshot = machine.vm.makeSnapshot()
        let summary = SnapshotSummary(
            version: snapshot.version,
            backend: machine.vm.backend.name,
            pc: hex(snapshot.cpu.pc),
            halted: snapshot.cpu.halted,
            ramBase: hex(snapshot.ramBase),
            ramSize: snapshot.ram.count,
            uartOutput: String(decoding: snapshot.uartOutput, as: UTF8.self),
            breakpoints: snapshot.breakpoints.map(hex)
        )

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(summary)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func validateManifest(path: String, preferencesPath: String?) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let manifest = try JSONDecoder().decode(ProprietaryGuestManifest.self, from: data)
        let preferences = try ARM64VizPreferencesLoader.load(from: preferencesPath)
        let report = ProprietaryGuestPolicy.evaluate(manifest, preferences: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let encoded = try encoder.encode(report)
        FileHandle.standardOutput.write(encoded)
        print("")

        if !report.accepted {
            throw VMError.policyViolation(report.findings.joined(separator: "; "))
        }
    }

    private static func showPolicy(preferencesPath: String?) throws {
        let preferences = try ARM64VizPreferencesLoader.load(from: preferencesPath)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(preferences)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func listAdapters() throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(BootAdapterRegistry.descriptors())
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func planBoot(arguments: [String]) throws {
        let preferences = try ARM64VizPreferencesLoader.load(from: optionalValue(after: "--preferences", in: arguments))
        let artifactPaths = arguments.dropFirst().filter { !$0.hasPrefix("--") && $0 != optionalValueOrEmpty(after: "--preferences", in: arguments) }
        let artifacts = try artifactPaths.map { path in
            let attributes = try FileManager.default.attributesOfItem(atPath: path)
            let byteCount = (attributes[.size] as? NSNumber)?.uint64Value ?? 0
            return BootArtifactDescriptor(
                name: URL(fileURLWithPath: path).lastPathComponent,
                byteCount: byteCount
            )
        }

        let plans = BootAdapterRegistry.plans(for: artifacts, preferences: preferences)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(plans)
        FileHandle.standardOutput.write(data)
        print("")
    }

    private static func printHelp() {
        print(
            """
            arm64viz commands:
              run-toy    Run the dependency-free toy ARM64 UART guest.
              run-mobile [--verbose] [path.mosimg]
                         Disabled: JavaScript MobileOS is archived.
              build-mobile-image [--verbose] <path.mosimg>
                         Disabled: JavaScript MobileOS is archived.
              mobile-kernel-demo
                         Disabled: JavaScript MobileOS is archived.
              prepare-linux <Image> [--postmarketos] [--initrd path]
                         [--dtb path] [--disk path] [--memory-mib n]
                         [--bootargs "..."] [--minimal-devices]
                         [--dump-generated-dtb path]
                         Prepare native ARM64 Linux/postmarketOS boot state
                         without invoking QEMU. This loads artifacts, stages
                         FDT/initrd/disk state, and reports the handoff.
              run-linux-trace <Image> [--postmarketos] [--initrd path]
                         [--dtb path] [--disk path] [--memory-mib n]
                         [--bootargs "..."] [--minimal-devices] [--max-steps n]
                         [--dump-generated-dtb path]
                         [--trace-depth n] [--exception-storm-threshold n]
                         [--symbols System.map] [--breakpoint address]
                         [--breakpoint-skip address:count]
                         [--stop-on-el0] [--stop-on-el0-fault]
                         [--el0-fault-skip n] [--stop-on-uart]
                         [--stop-on-uart-output text]
                         [--stream-uart] [--mmio-trace-depth n]
                         [--memory-trace-depth n] [--memory-trace-el0-only]
                         [--stop-on-memory-write-virtual address]
                         [--stop-on-memory-write-physical address]
                         [--memory-write-skip n]
                         [--sysreg-trace-depth n] [--timer-scale n]
                         [--uart-input text] [--uart-input-line text]
                         [--uart-input-after-output text]
                         [--writeback-disk path] [--profile-backend-timing]
                         [--wall-clock-budget-ms n]
                         Attempt native execution with the owned software
                         backend and emit a bounded instruction trace. This is
                         diagnostic only; full Linux execution is still pending.
                         Use --exception-storm-threshold 0 to continue through
                         repeated handled guest exceptions such as Linux WARNs.
                         Use --breakpoint-skip to stop on a later breakpoint hit.
                         Use --stop-on-el0 to stop at the first userspace handoff.
                         Use --stop-on-el0-fault to stop on a userspace page fault.
                         Use --el0-fault-skip to stop after earlier EL0 faults.
                         Use --stop-on-uart to stop at the first PL011 byte.
                         Use --stop-on-uart-output to stop after escaped text
                         has appeared on PL011.
                         Use --memory-trace-depth to retain recent normal RAM
                         reads/writes, and --memory-trace-el0-only to limit it
                         to userspace accesses.
                         Use --stop-on-memory-write-virtual or
                         --stop-on-memory-write-physical to stop on a RAM write
                         that overlaps an address.
                         Use --memory-write-skip to ignore earlier matching
                         writes before stopping.
                         Use --uart-input for escaped PL011 receive bytes.
                         Use --uart-input-line to append an escaped line plus LF.
                         Use --uart-input-after-output to delay injection until
                         escaped output text has appeared on PL011.
                         Use --sysreg-trace-depth to retain recent MRS/MSR state.
                         Use --profile-backend-timing when nanosecond backend
                         timing counters are worth the extra timestamp overhead.
                         Use --timer-scale to set counter ticks per instruction;
                         0 means event-driven timer advancement at WFI only.
                         Use --minimal-devices for initramfs shell traces that
                         only publish GIC, timer, and UART in the guest FDT.
                         Use --writeback-disk to persist virtio-block storage
                         after the trace run completes.
              diff-linux-blocks <Image> [--initrd path] [--dtb path]
                         [--disk path] [--memory-mib n] [--bootargs "..."]
                         [--minimal-devices] [--max-steps n]
                         [--chunk-steps n] [--progress-steps n]
                         [--timer-scale n] [--debug-chunks]
                         Compare the native C block engine with the established
                         instruction path and stop at the first divergent chunk.
              audit-instructions <ELF|directory|APK>...
                         [--sample-limit n] [--max-opcodes n] [--json]
                         [--no-expand-apks]
                         Statically scan ARM64 ELF executable sections with the
                         production native decoder. Alpine APK files and APK
                         directories are expanded into a temporary rootfs view.
              dump-dts   Print the generated DTS-style boot configuration.
              snapshot   Run the toy guest and emit a JSON snapshot summary.
              validate-manifest <path>
                         Validate a proprietary-guest metadata manifest without
                         ingesting or booting proprietary OS packages.
                         Use --preferences <path> to apply a policy file.
              policy-show [--preferences <path>]
                         Print the effective hardened policy preferences.
              adapters   Print supported boot adapter descriptors.
              plan-boot <paths...> [--preferences <path>]
                         Classify local boot artifacts and show adapter plans.
              help       Show this help.
            """
        )
    }

    private static func requiredPath(_ arguments: [String]) throws -> String {
        guard arguments.count >= 2 else {
            throw VMError.deviceError("missing manifest path")
        }
        return arguments[1]
    }

    private static func optionalValue(after flag: String, in arguments: [String]) throws -> String? {
        guard let index = arguments.firstIndex(of: flag) else {
            return nil
        }

        let valueIndex = arguments.index(after: index)
        guard valueIndex < arguments.endIndex else {
            throw VMError.deviceError("missing value after \(flag)")
        }
        return arguments[valueIndex]
    }

    private static func values(after flag: String, in arguments: [String]) throws -> [String] {
        var result: [String] = []
        var searchIndex = arguments.startIndex
        while let index = arguments[searchIndex...].firstIndex(of: flag) {
            let valueIndex = arguments.index(after: index)
            guard valueIndex < arguments.endIndex else {
                throw VMError.deviceError("missing value after \(flag)")
            }
            result.append(arguments[valueIndex])
            searchIndex = arguments.index(after: valueIndex)
        }
        return result
    }

    private static func linuxTraceUARTInputBytes(arguments: [String]) throws -> [UInt8] {
        var bytes: [UInt8] = []
        for value in try values(after: "--uart-input", in: arguments) {
            bytes.append(contentsOf: decodeEscapedArgument(value).utf8)
        }
        for value in try values(after: "--uart-input-line", in: arguments) {
            bytes.append(contentsOf: decodeEscapedArgument(value).utf8)
            bytes.append(0x0a)
        }
        return bytes
    }

    private static func decodeEscapedArgument(_ value: String) -> String {
        var result = ""
        var iterator = value.makeIterator()
        while let character = iterator.next() {
            guard character == "\\" else {
                result.append(character)
                continue
            }
            guard let escaped = iterator.next() else {
                result.append("\\")
                break
            }
            switch escaped {
            case "e":
                result.append(Character(UnicodeScalar(0x1b)!))
            case "n":
                result.append("\n")
            case "r":
                result.append("\r")
            case "t":
                result.append("\t")
            case "\\":
                result.append("\\")
            default:
                result.append("\\")
                result.append(escaped)
            }
        }
        return result
    }

    private static func optionalValueOrEmpty(after flag: String, in arguments: [String]) -> String {
        (try? optionalValue(after: flag, in: arguments)) ?? ""
    }

    private static func optionalData(path: String?) throws -> Data? {
        guard let path else {
            return nil
        }
        return try Data(contentsOf: URL(fileURLWithPath: path))
    }

    private static func optionalInt(after flag: String, in arguments: [String]) throws -> Int? {
        guard let value = try optionalValue(after: flag, in: arguments) else {
            return nil
        }
        guard let parsed = Int(value), parsed > 0 else {
            throw VMError.deviceError("invalid positive integer after \(flag): \(value)")
        }
        return parsed
    }

    private static func parseAddress(_ value: String) throws -> GuestAddress {
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        let digits: Substring
        let radix: Int
        if trimmed.hasPrefix("0x") || trimmed.hasPrefix("0X") {
            digits = trimmed.dropFirst(2)
            radix = 16
        } else {
            digits = Substring(trimmed)
            radix = 16
        }
        guard let parsed = UInt64(digits, radix: radix) else {
            throw VMError.deviceError("invalid address: \(value)")
        }
        return parsed
    }

    private static func parseBreakpointSkip(_ value: String) throws -> (GuestAddress, Int) {
        let parts = value.split(separator: ":", maxSplits: 1).map(String.init)
        guard parts.count == 2 else {
            throw VMError.deviceError("invalid breakpoint skip, expected address:count: \(value)")
        }
        let address = try parseAddress(parts[0])
        guard let count = Int(parts[1]), count >= 0 else {
            throw VMError.deviceError("invalid breakpoint skip count: \(parts[1])")
        }
        return (address, count)
    }

    private static func optionalNonNegativeInt(after flag: String, in arguments: [String]) throws -> Int? {
        guard let value = try optionalValue(after: flag, in: arguments) else {
            return nil
        }
        guard let parsed = Int(value), parsed >= 0 else {
            throw VMError.deviceError("invalid non-negative integer after \(flag): \(value)")
        }
        return parsed
    }

    private static func traceRegisters(_ cpu: CPUState) -> [RegisterSummary] {
        let generalRegisters = (0...30).map { index in
            RegisterSummary(name: "x\(index)", value: hex(cpu.x[index]))
        }
        return generalRegisters + [
            RegisterSummary(name: "sp", value: hex(cpu.sp)),
            RegisterSummary(name: "pc", value: hex(cpu.pc))
        ]
    }

    private static func exceptionSummary(
        _ entry: ARM64ExceptionTraceEntry,
        symbols: KernelSymbolMap? = nil,
        physicalKernelLoadAddress: GuestAddress? = nil
    ) -> ExceptionTraceSummary {
        ExceptionTraceSummary(
            source: entry.source.rawValue,
            exceptionClass: String(describing: entry.exceptionClass),
            iss: hex(entry.iss),
            syndrome: hex(entry.syndrome),
            returnAddress: hex(entry.returnAddress),
            returnSymbol: symbols?.resolve(entry.returnAddress, physicalKernelLoadAddress: physicalKernelLoadAddress),
            faultAddress: entry.faultAddress.map(hex),
            faultSymbol: entry.faultAddress.flatMap {
                symbols?.resolve($0, physicalKernelLoadAddress: physicalKernelLoadAddress)
            },
            vectorBase: hex(entry.vectorBase),
            vectorOffset: hex(entry.vectorOffset),
            vectorAddress: hex(entry.vectorAddress),
            vectorSymbol: symbols?.resolve(entry.vectorAddress, physicalKernelLoadAddress: physicalKernelLoadAddress),
            previousPState: hex(entry.previousPState),
            newPState: hex(entry.newPState),
            currentEL: "EL\(entry.currentEL)",
            access: entry.access?.rawValue,
            faultLevel: entry.faultLevel,
            faultStatusCode: entry.faultStatusCode.map { String(describing: $0) },
            irqLine: entry.irqLine
        )
    }

    private static func systemRegisterWriteSummary(_ entry: ARM64SystemRegisterTraceEntry) -> SystemRegisterTraceSummary {
        SystemRegisterTraceSummary(
            step: entry.step,
            pc: hex(entry.pc),
            register: entry.register,
            key: entry.key.description,
            previousValue: hex(entry.previousValue),
            newValue: hex(entry.newValue)
        )
    }

    private static func systemRegisterReadSummary(_ entry: ARM64SystemRegisterReadTraceEntry) -> SystemRegisterReadTraceSummary {
        SystemRegisterReadTraceSummary(
            step: entry.step,
            pc: hex(entry.pc),
            register: entry.register,
            key: entry.key.description,
            value: hex(entry.value)
        )
    }

    private static func translatedInstructionAddress(_ address: GuestAddress, vm: VirtualMachine) -> GuestAddress? {
        try? vm.translateAddress(address, access: .instruction)
    }

    private static func instructionSymbol(
        _ address: GuestAddress,
        vm: VirtualMachine,
        symbols: KernelSymbolMap?,
        physicalKernelLoadAddress: GuestAddress?
    ) -> KernelSymbolSummary? {
        if let physicalAddress = translatedInstructionAddress(address, vm: vm),
           let summary = symbols?.resolve(
               physicalAddress,
               physicalKernelLoadAddress: physicalKernelLoadAddress
           ) {
            return summary
        }
        return symbols?.resolve(address, physicalKernelLoadAddress: physicalKernelLoadAddress)
    }

    private static func stackFrames(
        vm: VirtualMachine,
        symbols: KernelSymbolMap?,
        physicalKernelLoadAddress: GuestAddress?,
        maxDepth: Int
    ) -> [StackFrameSummary] {
        guard maxDepth > 0 else {
            return []
        }

        var frames: [StackFrameSummary] = []
        var framePointer = vm.cpu.x[29]
        var seen: Set<GuestAddress> = []

        for _ in 0..<maxDepth {
            guard framePointer != 0, !seen.contains(framePointer) else {
                break
            }
            seen.insert(framePointer)

            let previousFramePointer: UInt64
            let returnAddress: UInt64
            do {
                previousFramePointer = try vm.readGuest(framePointer, width: .doubleword)
                returnAddress = try vm.readGuest(framePointer + 8, width: .doubleword)
            } catch {
                frames.append(StackFrameSummary(
                    framePointer: hex(framePointer),
                    returnAddress: nil,
                    symbol: nil,
                    error: String(describing: error)
                ))
                break
            }

            frames.append(StackFrameSummary(
                framePointer: hex(framePointer),
                returnAddress: hex(returnAddress),
                symbol: instructionSymbol(
                    returnAddress,
                    vm: vm,
                    symbols: symbols,
                    physicalKernelLoadAddress: physicalKernelLoadAddress
                ),
                error: nil
            ))

            guard previousFramePointer > framePointer else {
                break
            }
            framePointer = previousFramePointer
        }

        return frames
    }

    private static func memblockSummary(
        vm: VirtualMachine,
        symbols: KernelSymbolMap?,
        physicalKernelLoadAddress: GuestAddress?
    ) -> MemblockSummary? {
        guard let symbols,
              let memblockAddress = runtimeAddress(
                  forSymbolNamed: "memblock",
                  symbols: symbols,
                  vm: vm,
                  physicalKernelLoadAddress: physicalKernelLoadAddress
              ) else {
            return nil
        }

        do {
            let bottomUp = try vm.readGuest(memblockAddress, width: .byte) != 0
            let currentLimit = try vm.readGuest(memblockAddress + 8, width: .doubleword)
            let memory = try memblockTypeSummary(vm: vm, address: memblockAddress + 16)
            let reserved = try memblockTypeSummary(vm: vm, address: memblockAddress + 56)
            return MemblockSummary(
                address: hex(memblockAddress),
                bottomUp: bottomUp,
                currentLimit: hex(currentLimit),
                memory: memory,
                reserved: reserved,
                error: nil
            )
        } catch {
            return MemblockSummary(
                address: hex(memblockAddress),
                bottomUp: nil,
                currentLimit: nil,
                memory: nil,
                reserved: nil,
                error: String(describing: error)
            )
        }
    }

    private static func memblockTypeSummary(vm: VirtualMachine, address: GuestAddress) throws -> MemblockTypeSummary {
        let count = try vm.readGuest(address, width: .doubleword)
        let max = try vm.readGuest(address + 8, width: .doubleword)
        let totalSize = try vm.readGuest(address + 16, width: .doubleword)
        let regionsAddress = try vm.readGuest(address + 24, width: .doubleword)
        let regionCount = min(count, 8)
        var regions: [MemblockRegionSummary] = []

        for index in 0..<regionCount {
            let regionAddress = regionsAddress + index * 32
            let base = try vm.readGuest(regionAddress, width: .doubleword)
            let size = try vm.readGuest(regionAddress + 8, width: .doubleword)
            let flags = try vm.readGuest(regionAddress + 16, width: .word)
            let nid = try vm.readGuest(regionAddress + 20, width: .word)
            regions.append(MemblockRegionSummary(
                base: hex(base),
                size: hex(size),
                flags: hex(flags),
                nid: UInt32(nid)
            ))
        }

        return MemblockTypeSummary(
            count: count,
            max: max,
            totalSize: hex(totalSize),
            regionsAddress: hex(regionsAddress),
            regions: regions
        )
    }

    private static func runtimeAddress(
        forSymbolNamed name: String,
        symbols: KernelSymbolMap,
        vm: VirtualMachine,
        physicalKernelLoadAddress: GuestAddress?
    ) -> GuestAddress? {
        guard let symbolAddress = symbols.address(named: name) else {
            return nil
        }
        let runtimeSlide = (physicalKernelLoadAddress ?? vm.memory.base) &- vm.memory.base
        return symbolAddress &+ runtimeSlide
    }

    private static func mmioTraceSummary(
        _ entry: MMIOTraceEntry,
        symbols: KernelSymbolMap? = nil,
        physicalKernelLoadAddress: GuestAddress? = nil
    ) -> MMIOTraceSummary {
        MMIOTraceSummary(
            step: entry.step,
            pc: hex(entry.pc),
            symbol: symbols?.resolve(entry.pc, physicalKernelLoadAddress: physicalKernelLoadAddress),
            device: entry.deviceName,
            access: entry.access.rawValue,
            address: hex(entry.address),
            offset: hex(entry.offset),
            width: entry.width,
            value: hex(entry.value)
        )
    }

    private static func guestMemoryTraceSummary(
        _ entry: GuestMemoryTraceEntry,
        symbols: KernelSymbolMap? = nil,
        physicalKernelLoadAddress: GuestAddress? = nil
    ) -> GuestMemoryTraceSummary {
        GuestMemoryTraceSummary(
            step: entry.step,
            pc: hex(entry.pc),
            symbol: symbols?.resolve(entry.pc, physicalKernelLoadAddress: physicalKernelLoadAddress),
            exceptionLevel: "EL\(entry.exceptionLevel)",
            access: entry.access.rawValue,
            virtualAddress: hex(entry.virtualAddress),
            physicalAddress: hex(entry.physicalAddress),
            width: entry.width,
            value: hex(entry.value)
        )
    }

    private static func executionStateSummary(
        _ entry: ARM64ExecutionStateTraceEntry,
        symbols: KernelSymbolMap? = nil,
        physicalKernelLoadAddress: GuestAddress? = nil
    ) -> ExecutionStateTraceSummary {
        ExecutionStateTraceSummary(
            step: entry.step,
            reason: entry.reason.rawValue,
            previousPC: hex(entry.previousPC),
            previousSymbol: symbols?.resolve(entry.previousPC, physicalKernelLoadAddress: physicalKernelLoadAddress),
            newPC: hex(entry.newPC),
            newSymbol: symbols?.resolve(entry.newPC, physicalKernelLoadAddress: physicalKernelLoadAddress),
            previousEL: "EL\(entry.previousEL)",
            newEL: "EL\(entry.newEL)",
            previousPState: hex(entry.previousPState),
            newPState: hex(entry.newPState)
        )
    }

    private static func exceptionCounts(
        _ entries: [ARM64ExceptionTraceEntry],
        symbols: KernelSymbolMap? = nil,
        physicalKernelLoadAddress: GuestAddress? = nil
    ) -> [ExceptionCountSummary] {
        var counts: [String: (entry: ARM64ExceptionTraceEntry, count: Int)] = [:]

        for entry in entries {
            let key = [
                entry.source.rawValue,
                String(describing: entry.exceptionClass),
                hex(entry.iss),
                hex(entry.returnAddress),
                hex(entry.vectorAddress)
            ].joined(separator: "|")

            if var existing = counts[key] {
                existing.count += 1
                counts[key] = existing
            } else {
                counts[key] = (entry, 1)
            }
        }

        return counts.values
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                return $0.entry.returnAddress < $1.entry.returnAddress
            }
            .map { value in
                ExceptionCountSummary(
                    source: value.entry.source.rawValue,
                    exceptionClass: String(describing: value.entry.exceptionClass),
                    iss: hex(value.entry.iss),
                    returnAddress: hex(value.entry.returnAddress),
                    returnSymbol: symbols?.resolve(
                        value.entry.returnAddress,
                        physicalKernelLoadAddress: physicalKernelLoadAddress
                    ),
                    vectorAddress: hex(value.entry.vectorAddress),
                    vectorSymbol: symbols?.resolve(
                        value.entry.vectorAddress,
                        physicalKernelLoadAddress: physicalKernelLoadAddress
                    ),
                    count: value.count
                )
            }
    }

    private static func mmioAccessCounts(_ entries: [MMIOTraceEntry]) -> [MMIOAccessCountSummary] {
        var counts: [String: (device: String, access: String, offset: UInt64, count: UInt64)] = [:]
        for entry in entries {
            let access = entry.access.rawValue
            let key = "\(entry.deviceName)|\(access)|\(entry.offset)"
            if var existing = counts[key] {
                existing.count += 1
                counts[key] = existing
            } else {
                counts[key] = (entry.deviceName, access, entry.offset, 1)
            }
        }

        return counts.values
            .sorted {
                if $0.count != $1.count {
                    return $0.count > $1.count
                }
                if $0.device != $1.device {
                    return $0.device < $1.device
                }
                if $0.access != $1.access {
                    return $0.access < $1.access
                }
                return $0.offset < $1.offset
            }
            .map {
                MMIOAccessCountSummary(
                    device: $0.device,
                    access: $0.access,
                    offset: hex($0.offset),
                    count: $0.count
                )
            }
    }

    private static func mmioAccessCounts(_ counters: [MMIOAccessCounter]) -> [MMIOAccessCountSummary] {
        counters.map {
            MMIOAccessCountSummary(
                device: $0.deviceName,
                access: $0.access.rawValue,
                offset: hex($0.offset),
                count: $0.count
            )
        }
    }

    private static func utf8Tail(_ bytes: [UInt8], maxBytes: Int) -> String {
        guard !bytes.isEmpty, maxBytes > 0 else {
            return ""
        }
        let tail = bytes.suffix(maxBytes)
        return String(decoding: tail, as: UTF8.self)
    }

    private static func traceSystemRegisters(_ registers: ARM64SystemRegisterBank, cpu: CPUState) -> [RegisterSummary] {
        let selected: [ARM64SystemRegisterKey] = [
            ARM64SystemRegister.currentEL,
            ARM64SystemRegister.daif,
            ARM64SystemRegister.sctlrEL1,
            ARM64SystemRegister.tcrEL1,
            ARM64SystemRegister.ttbr0EL1,
            ARM64SystemRegister.ttbr1EL1,
            ARM64SystemRegister.vbarEL1,
            ARM64SystemRegister.mairEL1,
            ARM64SystemRegister.spEL0,
            ARM64SystemRegister.esrEL1,
            ARM64SystemRegister.farEL1,
            ARM64SystemRegister.elrEL1,
            ARM64SystemRegister.spsrEL1,
            ARM64SystemRegister.contextidrEL1,
            ARM64SystemRegister.tpidrEL1,
            ARM64SystemRegister.tpidrEL0,
            ARM64SystemRegister.tpidrroEL0,
            ARM64SystemRegister.dczidEL0,
            ARM64SystemRegister.cntfrqEL0,
            ARM64SystemRegister.cntpCtlEL0,
            ARM64SystemRegister.cntpTvalEL0,
            ARM64SystemRegister.cntpCvalEL0,
            ARM64SystemRegister.cntvCtlEL0,
            ARM64SystemRegister.cntvTvalEL0,
            ARM64SystemRegister.cntvCvalEL0,
            ARM64SystemRegister.cntpctEL0,
            ARM64SystemRegister.cntvctEL0
        ]

        return selected.map { key in
            RegisterSummary(name: key.description, value: hex(registers.read(key, cpu: cpu)))
        }
    }

    private static func interruptStateSummary(_ vm: VirtualMachine) -> InterruptStateSummary {
        InterruptStateSummary(
            pendingLine: vm.interruptController.peekPending(),
            activeLine: vm.interruptController.activeLine(),
            physicalTimerIRQ: VirtualMachine.physicalTimerIRQ,
            physicalTimerEnabled: vm.interruptController.isEnabled(line: VirtualMachine.physicalTimerIRQ),
            physicalTimerAsserted: vm.systemRegisters.physicalTimerInterruptAsserted,
            virtualTimerIRQ: VirtualMachine.virtualTimerIRQ,
            virtualTimerEnabled: vm.interruptController.isEnabled(line: VirtualMachine.virtualTimerIRQ),
            virtualTimerAsserted: vm.systemRegisters.virtualTimerInterruptAsserted
        )
    }

    private static func translationWalkSummary(
        for exception: ARM64ExceptionTraceEntry,
        vm: VirtualMachine
    ) -> TranslationWalkSummary? {
        guard exception.source == .translationFault else {
            return nil
        }
        let virtualAddress = exception.faultAddress ?? exception.returnAddress
        let usesTTBR1 = (virtualAddress >> 63) == 1
        let tcr = vm.systemRegisters.rawValue(for: ARM64SystemRegister.tcrEL1)
        let sizeOffset = usesTTBR1 ? 16 : 0
        let tsz = Int((tcr >> UInt64(sizeOffset)) & 0x3f)
        let inputAddressSize = 64 - tsz
        let effectiveAddress: GuestAddress
        if inputAddressSize > 0, inputAddressSize < 64 {
            effectiveAddress = virtualAddress & ((UInt64(1) << UInt64(inputAddressSize)) - 1)
        } else {
            effectiveAddress = virtualAddress
        }
        let ttbrKey = usesTTBR1 ? ARM64SystemRegister.ttbr1EL1 : ARM64SystemRegister.ttbr0EL1
        let ttbr = vm.systemRegisters.rawValue(for: ttbrKey)
        let tableBase = ttbr & 0x0000_ffff_ffff_f000
        var currentTable = tableBase
        var levels: [TranslationWalkLevelSummary] = []

        guard inputAddressSize > 0, inputAddressSize <= 48, tableBase != 0 else {
            return TranslationWalkSummary(
                virtualAddress: hex(virtualAddress),
                access: exception.access?.rawValue,
                usesTTBR1: usesTTBR1,
                tcr: hex(tcr),
                inputAddressSize: inputAddressSize,
                effectiveAddress: hex(effectiveAddress),
                ttbr: hex(ttbr),
                tableBase: hex(tableBase),
                levels: levels
            )
        }

        for level in 0...3 {
            let shift = 39 - (level * 9)
            let index = (effectiveAddress >> UInt64(shift)) & 0x1ff
            let descriptorAddress = currentTable + index * 8
            let descriptor = try? vm.readPhysical(descriptorAddress, width: .doubleword)
            let descriptorType = descriptor.map { $0 & 0x3 }
            let valid = descriptor.map { ($0 & 0x1) != 0 } ?? false
            let isLeaf = descriptorType == 0x1 || (level == 3 && descriptorType == 0x3)
            levels.append(TranslationWalkLevelSummary(
                level: level,
                index: hex(index),
                descriptorAddress: hex(descriptorAddress),
                descriptor: descriptor.map(hex),
                descriptorType: descriptorType.map(hex),
                valid: valid,
                leaf: isLeaf
            ))
            guard let descriptor, valid else {
                break
            }
            if isLeaf {
                break
            }
            guard descriptorType == 0x3 else {
                break
            }
            currentTable = descriptor & 0x0000_ffff_ffff_f000
        }

        return TranslationWalkSummary(
            virtualAddress: hex(virtualAddress),
            access: exception.access?.rawValue,
            usesTTBR1: usesTTBR1,
            tcr: hex(tcr),
            inputAddressSize: inputAddressSize,
            effectiveAddress: hex(effectiveAddress),
            ttbr: hex(ttbr),
            tableBase: hex(tableBase),
            levels: levels
        )
    }

    private static func linuxBackendWork(
        after entry: InstructionTraceEntry?,
        runtimeError: String?,
        exception: ARM64ExceptionTraceEntry?
    ) -> [String] {
        var work = [
            "Linux-grade IRQ/FIQ priority, masking, EOI, and nesting behavior",
            "Broader MMU attributes, shareability, cacheability, and TLB maintenance",
            "GIC/timer driver compatibility beyond the current minimal model",
            "PL011 FIFO depth, baud/control registers, and interrupt edge cases",
            "virtio descriptor-ring execution for net/input/display"
        ]

        if let exception, exception.vectorAddress == exception.returnAddress {
            work.insert("Fix exception vector mapping/translation loop at \(hex(exception.vectorAddress))", at: 0)
            return work
        }

        guard runtimeError != nil else {
            return work
        }

        switch entry?.decode {
        case "mrs", "msr":
            work.insert("Implement architected system register access", at: 0)
        default:
            break
        }

        return work
    }

    private static func loadMobileOSImage(path: String?, verboseBoot: Bool) throws -> MobileOSImage {
        guard let path else {
            return .developmentImage(verboseBoot: verboseBoot)
        }
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try MobileOSImage.decodeArtifact([UInt8](data))
    }

    private static func hasFlag(_ flag: String, in arguments: [String]) -> Bool {
        arguments.contains(flag)
    }

    private static func positionalArguments(in arguments: [String]) -> [String] {
        var result: [String] = []
        var index = arguments.index(after: arguments.startIndex)
        let optionsWithValues: Set<String> = [
            "--bootargs",
            "--disk",
            "--dump-generated-dtb",
            "--dtb",
            "--initrd",
            "--exception-storm-threshold",
            "--breakpoint",
            "--breakpoint-skip",
            "--chunk-steps",
            "--max-steps",
            "--memory-mib",
            "--memory-trace-depth",
            "--memory-write-skip",
            "--mmio-trace-depth",
            "--preferences",
            "--progress-steps",
            "--symbols",
            "--stop-on-memory-write-physical",
            "--stop-on-memory-write-virtual",
            "--sysreg-trace-depth",
            "--timer-scale",
            "--trace-depth",
            "--writeback-disk"
        ]
        while index < arguments.endIndex {
            let value = arguments[index]
            if optionsWithValues.contains(value) {
                index = arguments.index(index, offsetBy: 2, limitedBy: arguments.endIndex) ?? arguments.endIndex
                continue
            }
            if value.hasPrefix("--") {
                index = arguments.index(after: index)
                continue
            }
            result.append(value)
            index = arguments.index(after: index)
        }
        return result
    }

    private static func requiredPositionalPath(_ arguments: [String]) throws -> String {
        guard let path = positionalArguments(in: arguments).first else {
            throw VMError.deviceError("missing path")
        }
        return path
    }

    private static func hex(_ value: UInt64) -> String {
        "0x" + String(value, radix: 16)
    }
}

private struct KernelSymbolMap {
    private let symbols: [KernelSymbol]

    init(path: String) throws {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        guard let text = String(data: data, encoding: .utf8) else {
            throw VMError.deviceError("symbol map is not valid UTF-8: \(path)")
        }
        symbols = text
            .split(whereSeparator: { $0.isNewline })
            .compactMap(KernelSymbol.init(systemMapLine:))
            .sorted { lhs, rhs in
                if lhs.address != rhs.address {
                    return lhs.address < rhs.address
                }
                return lhs.name < rhs.name
            }
    }

    var symbolCount: Int {
        symbols.count
    }

    func address(named name: String) -> GuestAddress? {
        symbolAddress(named: name)
    }

    func resolve(_ address: GuestAddress, physicalKernelLoadAddress: GuestAddress? = nil) -> KernelSymbolSummary? {
        if let virtualAddress = virtualAlias(forPhysicalAddress: address, loadAddress: physicalKernelLoadAddress),
           let summary = resolveDirect(virtualAddress) {
            return summary
        }
        return resolveDirect(address)
    }

    private func virtualAlias(
        forPhysicalAddress address: GuestAddress,
        loadAddress: GuestAddress?
    ) -> GuestAddress? {
        guard let loadAddress,
              address >= loadAddress,
              let textAddress = symbolAddress(named: "_text"),
              let lastAddress = symbols.last?.address,
              lastAddress >= textAddress else {
            return nil
        }

        let offset = address - loadAddress
        guard offset <= lastAddress - textAddress else {
            return nil
        }
        return textAddress &+ offset
    }

    private func symbolAddress(named name: String) -> GuestAddress? {
        symbols.first { $0.name == name }?.address
    }

    private func resolveDirect(_ address: GuestAddress) -> KernelSymbolSummary? {
        guard !symbols.isEmpty else {
            return nil
        }

        var low = 0
        var high = symbols.count
        while low < high {
            let mid = (low + high) / 2
            if symbols[mid].address <= address {
                low = mid + 1
            } else {
                high = mid
            }
        }

        guard low > 0 else {
            return nil
        }

        let symbol = symbols[low - 1]
        return KernelSymbolSummary(
            name: symbol.name,
            type: symbol.type,
            address: symbolHex(symbol.address),
            offset: symbolHex(address - symbol.address)
        )
    }
}

private struct KernelSymbol {
    let address: GuestAddress
    let type: String
    let name: String

    init?(systemMapLine line: Substring) {
        let fields = line.split(whereSeparator: { $0.isWhitespace })
        guard fields.count >= 3 else {
            return nil
        }
        guard let address = UInt64(fields[0], radix: 16) else {
            return nil
        }
        self.address = address
        self.type = String(fields[1])
        self.name = String(fields[2])
    }
}

private func symbolHex(_ value: UInt64) -> String {
    "0x" + String(value, radix: 16)
}

private struct SnapshotSummary: Encodable {
    let version: Int
    let backend: String
    let pc: String
    let halted: Bool
    let ramBase: String
    let ramSize: Int
    let uartOutput: String
    let breakpoints: [String]
}

private struct LinuxPrepareSummary: Encodable {
    let guest: String
    let profile: String
    let backend: String
    let entryPoint: String
    let fdtAddress: String
    let fdtByteCount: Int
    let initrdAddress: String?
    let initrdByteCount: Int?
    let diskByteCount: Int?
    let suppliedDeviceTree: Bool
    let bootArguments: String
    let cpuX0: String
    let pstate: String
    let currentEL: String
    let sp: String
    let canExecuteNow: Bool
    let nextBackendWork: [String]
}

private struct LinuxBlockDifferentialReport: Encodable {
    let status: String
    let matchedSteps: Int
    let divergentWindowStart: Int?
    let divergentWindowEnd: Int?
    let chunkSteps: Int
    let differences: [String]
    let reference: DifferentialCPUState
    let candidate: DifferentialCPUState
    let referenceUARTBytes: Int
    let candidateUARTBytes: Int
    let candidatePerformance: ARM64BackendPerformanceSnapshot
}

private struct DifferentialCPUState: Encodable {
    let pc: String
    let instruction: String?
    let pstate: String
    let currentEL: String
    let sp: String
    let spEL1: String
    let counterTicks: UInt64
    let registers: [String]
}

private struct LinuxTraceSummary: Encodable {
    let guest: String
    let profile: String
    let backend: String
    let entryPoint: String
    let fdtAddress: String
    let fdtByteCount: Int
    let initrdAddress: String?
    let initrdByteCount: Int?
    let diskByteCount: Int?
    let suppliedDeviceTree: Bool
    let bootArguments: String
    let maxSteps: Int
    let executedSteps: Int?
    let exceptionStormThreshold: Int
    let breakpoints: [String]
    let stopOnEL0: Bool
    let stopOnEL0Fault: Bool
    let el0FaultSkip: Int
    let stopOnUART: Bool
    let stopOnUARTOutput: String?
    let streamUART: Bool
    let uartInputByteCount: Int
    let uartInputInjected: Bool
    let uartInputAfterOutput: String?
    let mmioTraceDepth: Int
    let memoryTraceDepth: Int
    let memoryTraceEL0Only: Bool
    let stopOnMemoryWriteVirtual: String?
    let stopOnMemoryWritePhysical: String?
    let memoryWriteSkip: Int
    let observedMemoryWriteWatchCount: Int
    let sysregTraceDepth: Int
    let timerScale: UInt64
    let waitForInterruptCount: UInt64
    let waitForEventCount: UInt64
    let timerFastForwardCount: UInt64
    let timerFastForwardCycles: UInt64
    let virtioBlockRequests: Int
    let virtioBlockRequestTypes: [VirtIOBlockRequestTypeSummary]
    let virtioBlockRecentRequests: [String]
    let virtioNetworkTransmits: Int
    let virtioNetworkReceives: Int
    let linkLocalTransmittedFrames: Int
    let linkLocalGeneratedFrames: Int
    let linkLocalRecentFrames: [String]
    let el0FaultCount: Int
    let translationCacheHits: Int
    let translationCacheMisses: Int
    let backendPerformance: ARM64BackendPerformanceSnapshot?
    let symbolMap: SymbolMapSummary?
    let stopReason: String?
    let error: String?
    let pc: String
    let pcPhysical: String?
    let pcSymbol: KernelSymbolSummary?
    let pstate: String
    let currentEL: String
    let sp: String
    let instruction: String?
    let decodedInstruction: String?
    let lastException: ExceptionTraceSummary?
    let uartOutputByteCount: Int
    let uartOutputTail: String
    let registers: [RegisterSummary]
    let systemRegisters: [RegisterSummary]
    let stackFrames: [StackFrameSummary]
    let memblock: MemblockSummary?
    let interruptState: InterruptStateSummary
    let interruptDiagnostics: InterruptControllerDiagnostics
    let translationWalk: TranslationWalkSummary?
    let firstEL0Entry: ExecutionStateTraceSummary?
    let recentInstructions: [InstructionTraceSummary]
    let recentExceptions: [ExceptionTraceSummary]
    let exceptionCounts: [ExceptionCountSummary]
    let recentSystemRegisterWrites: [SystemRegisterTraceSummary]
    let recentSystemRegisterReads: [SystemRegisterReadTraceSummary]
    let executionStateTransitions: [ExecutionStateTraceSummary]
    let recentMMIOAccesses: [MMIOTraceSummary]
    let recentMemoryAccesses: [GuestMemoryTraceSummary]
    let globalMMIOAccessCounts: [MMIOAccessCountSummary]
    let mmioAccessCounts: [MMIOAccessCountSummary]
    let nextBackendWork: [String]
}

private struct VirtIOBlockRequestTypeSummary: Encodable {
    let requestType: UInt32
    let name: String
    let count: Int
}

private struct RegisterSummary: Encodable {
    let name: String
    let value: String
}

private struct StackFrameSummary: Encodable {
    let framePointer: String
    let returnAddress: String?
    let symbol: KernelSymbolSummary?
    let error: String?
}

private struct MemblockSummary: Encodable {
    let address: String
    let bottomUp: Bool?
    let currentLimit: String?
    let memory: MemblockTypeSummary?
    let reserved: MemblockTypeSummary?
    let error: String?
}

private struct MemblockTypeSummary: Encodable {
    let count: UInt64
    let max: UInt64
    let totalSize: String
    let regionsAddress: String
    let regions: [MemblockRegionSummary]
}

private struct MemblockRegionSummary: Encodable {
    let base: String
    let size: String
    let flags: String
    let nid: UInt32
}

private struct InstructionTraceSummary: Encodable {
    let step: Int
    let pc: String
    let physicalPC: String?
    let symbol: KernelSymbolSummary?
    let instruction: String
    let decode: String
    let pstateBefore: String
    let pstateAfter: String?
}

private struct ExceptionTraceSummary: Encodable {
    let source: String
    let exceptionClass: String
    let iss: String
    let syndrome: String
    let returnAddress: String
    let returnSymbol: KernelSymbolSummary?
    let faultAddress: String?
    let faultSymbol: KernelSymbolSummary?
    let vectorBase: String
    let vectorOffset: String
    let vectorAddress: String
    let vectorSymbol: KernelSymbolSummary?
    let previousPState: String
    let newPState: String
    let currentEL: String
    let access: String?
    let faultLevel: Int?
    let faultStatusCode: String?
    let irqLine: UInt32?
}

private struct ExceptionCountSummary: Encodable {
    let source: String
    let exceptionClass: String
    let iss: String
    let returnAddress: String
    let returnSymbol: KernelSymbolSummary?
    let vectorAddress: String
    let vectorSymbol: KernelSymbolSummary?
    let count: Int
}

private struct SymbolMapSummary: Encodable {
    let path: String
    let symbolCount: Int
}

private struct KernelSymbolSummary: Encodable, Equatable {
    let name: String
    let type: String
    let address: String
    let offset: String
}

private struct SystemRegisterTraceSummary: Encodable {
    let step: Int
    let pc: String
    let register: String
    let key: String
    let previousValue: String
    let newValue: String
}

private struct SystemRegisterReadTraceSummary: Encodable {
    let step: Int
    let pc: String
    let register: String
    let key: String
    let value: String
}

private struct MMIOTraceSummary: Encodable {
    let step: Int
    let pc: String
    let symbol: KernelSymbolSummary?
    let device: String
    let access: String
    let address: String
    let offset: String
    let width: Int
    let value: String
}

private struct GuestMemoryTraceSummary: Encodable {
    let step: Int
    let pc: String
    let symbol: KernelSymbolSummary?
    let exceptionLevel: String
    let access: String
    let virtualAddress: String
    let physicalAddress: String
    let width: Int
    let value: String
}

private struct MMIOAccessCountSummary: Encodable {
    let device: String
    let access: String
    let offset: String
    let count: UInt64
}

private struct ExecutionStateTraceSummary: Encodable {
    let step: Int
    let reason: String
    let previousPC: String
    let previousSymbol: KernelSymbolSummary?
    let newPC: String
    let newSymbol: KernelSymbolSummary?
    let previousEL: String
    let newEL: String
    let previousPState: String
    let newPState: String
}

private struct InterruptStateSummary: Encodable {
    let pendingLine: UInt32?
    let activeLine: UInt32?
    let physicalTimerIRQ: UInt32
    let physicalTimerEnabled: Bool
    let physicalTimerAsserted: Bool
    let virtualTimerIRQ: UInt32
    let virtualTimerEnabled: Bool
    let virtualTimerAsserted: Bool
}

private struct TranslationWalkSummary: Encodable {
    let virtualAddress: String
    let access: String?
    let usesTTBR1: Bool
    let tcr: String
    let inputAddressSize: Int
    let effectiveAddress: String
    let ttbr: String
    let tableBase: String
    let levels: [TranslationWalkLevelSummary]
}

private struct TranslationWalkLevelSummary: Encodable {
    let level: Int
    let index: String
    let descriptorAddress: String
    let descriptor: String?
    let descriptorType: String?
    let valid: Bool
    let leaf: Bool
}

private struct PreparedLinuxMachine {
    let machine: ResearchMachine
    let loadResult: LinuxBootLoadResult
    let networkBackend: LinkLocalVirtIONetworkBackend
}
