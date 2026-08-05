import Foundation

public typealias MobileOSFileDescriptor = Int32

public enum MobileOSFileType: String, Codable, Equatable {
    case regular
    case directory
    case characterDevice
    case fifo
}

public enum MobileOSOpenFlag: String, Codable, Equatable {
    case readOnly
    case writeOnly
    case readWrite
    case create
    case truncate
    case append
}

public enum MobileOSUnixProcessState: String, Codable, Equatable {
    case ready
    case running
    case waiting
    case stopped
    case zombie
}

public enum MobileOSErrno: Int32, Codable, Equatable {
    case operationNotPermitted = 1
    case noSuchFileOrDirectory = 2
    case interrupted = 4
    case ioError = 5
    case badFileDescriptor = 9
    case permissionDenied = 13
    case fileExists = 17
    case notDirectory = 20
    case isDirectory = 21
    case invalidArgument = 22
    case functionNotImplemented = 38
}

public enum MobileOSSyscallNumber: String, Codable, Equatable {
    case open
    case read
    case write
    case close
    case chdir
    case getcwd
    case mkdir
    case rmdir
    case unlink
    case stat
    case fork
    case execve
    case wait4
    case pipe
    case dup2
    case ioctl
    case exit
}

public struct MobileOSFileStat: Codable, Equatable {
    public let path: String
    public let type: MobileOSFileType
    public let byteCount: Int
    public let mode: UInt16
    public let ownerUID: UInt32
    public let ownerGID: UInt32
}

public struct MobileOSSyscall: Codable, Equatable {
    public let number: MobileOSSyscallNumber
    public let path: String?
    public let fileDescriptor: MobileOSFileDescriptor?
    public let targetFileDescriptor: MobileOSFileDescriptor?
    public let byteCount: Int?
    public let data: Data?
    public let text: String?
    public let flags: [MobileOSOpenFlag]
    public let argv: [String]
    public let mode: UInt16?
    public let request: UInt64?
    public let exitStatus: Int32?

    public init(
        number: MobileOSSyscallNumber,
        path: String? = nil,
        fileDescriptor: MobileOSFileDescriptor? = nil,
        targetFileDescriptor: MobileOSFileDescriptor? = nil,
        byteCount: Int? = nil,
        data: Data? = nil,
        text: String? = nil,
        flags: [MobileOSOpenFlag] = [],
        argv: [String] = [],
        mode: UInt16? = nil,
        request: UInt64? = nil,
        exitStatus: Int32? = nil
    ) {
        self.number = number
        self.path = path
        self.fileDescriptor = fileDescriptor
        self.targetFileDescriptor = targetFileDescriptor
        self.byteCount = byteCount
        self.data = data
        self.text = text
        self.flags = flags
        self.argv = argv
        self.mode = mode
        self.request = request
        self.exitStatus = exitStatus
    }
}

public struct MobileOSSyscallResult: Codable, Equatable {
    public let returnValue: Int64
    public let errno: MobileOSErrno?
    public let data: Data?
    public let text: String?
    public let pid: MobileOSProcessID?
    public let fileDescriptors: [MobileOSFileDescriptor]
    public let stat: MobileOSFileStat?

    public var succeeded: Bool {
        errno == nil
    }

    public init(
        returnValue: Int64,
        errno: MobileOSErrno? = nil,
        data: Data? = nil,
        text: String? = nil,
        pid: MobileOSProcessID? = nil,
        fileDescriptors: [MobileOSFileDescriptor] = [],
        stat: MobileOSFileStat? = nil
    ) {
        self.returnValue = returnValue
        self.errno = errno
        self.data = data
        self.text = text
        self.pid = pid
        self.fileDescriptors = fileDescriptors
        self.stat = stat
    }
}

public struct MobileOSUnixProcess: Codable, Equatable {
    public let pid: MobileOSProcessID
    public let parentPID: MobileOSProcessID?
    public let executable: String
    public let argv: [String]
    public let cwd: String
    public let state: MobileOSUnixProcessState
    public let exitStatus: Int32?
    public let openFileDescriptors: [MobileOSFileDescriptor]
}

public struct MobileOSPTYSession: Codable, Equatable {
    public let id: UInt32
    public let devicePath: String
    public let foregroundPID: MobileOSProcessID
    public let rows: UInt16
    public let columns: UInt16
    public let pendingOutput: String
    public let transcript: String
}

public struct MobileOSUnixReport: Codable, Equatable {
    public let processes: [MobileOSUnixProcess]
    public let ptySessions: [MobileOSPTYSession]
    public let mountedPaths: [String]
    public let supportedSyscalls: [MobileOSSyscallNumber]
    public let primaryPTYID: UInt32?
    public let primaryShellPID: MobileOSProcessID?
}

public final class MobileOSUnixEnvironment {
    private struct VFSNode {
        var type: MobileOSFileType
        var content: [UInt8]
        var mode: UInt16
        var ownerUID: UInt32
        var ownerGID: UInt32
        var readOnly: Bool
    }

    private struct ProcessRecord {
        var pid: MobileOSProcessID
        var parentPID: MobileOSProcessID?
        var executable: String
        var argv: [String]
        var cwd: String
        var state: MobileOSUnixProcessState
        var exitStatus: Int32?
    }

    private enum FileDescriptorTarget {
        case file(String)
        case null
        case ptyMaster(UInt32)
        case ptySlave(UInt32)
        case pipeRead(UInt32)
        case pipeWrite(UInt32)
    }

    private struct FileDescriptorRecord {
        var target: FileDescriptorTarget
        var offset: Int
        var readable: Bool
        var writable: Bool
        var append: Bool
    }

    private struct PTYRecord {
        var id: UInt32
        var foregroundPID: MobileOSProcessID
        var rows: UInt16
        var columns: UInt16
        var pendingOutput: String
        var transcript: String
    }

    private var nextPID: MobileOSProcessID
    private var nextPTYID: UInt32 = 0
    private var nextPipeID: UInt32 = 1
    private var primaryPTYID: UInt32?
    private var primaryShellPID: MobileOSProcessID?
    private var processes: [MobileOSProcessID: ProcessRecord] = [:]
    private var descriptors: [MobileOSProcessID: [MobileOSFileDescriptor: FileDescriptorRecord]] = [:]
    private var nextDescriptor: [MobileOSProcessID: MobileOSFileDescriptor] = [:]
    private var files: [String: VFSNode] = [:]
    private var ptys: [UInt32: PTYRecord] = [:]
    private var pipes: [UInt32: [UInt8]] = [:]

    public init(nextPID: MobileOSProcessID = 100) {
        self.nextPID = nextPID
        mountBaseFilesystem()
        let initPID = allocatePID()
        processes[initPID] = ProcessRecord(
            pid: initPID,
            parentPID: nil,
            executable: "/sbin/init",
            argv: ["/sbin/init"],
            cwd: "/",
            state: .running,
            exitStatus: nil
        )
        descriptors[initPID] = [:]
        nextDescriptor[initPID] = 0
    }

    public var report: MobileOSUnixReport {
        MobileOSUnixReport(
            processes: processes.values
                .sorted { $0.pid < $1.pid }
                .map { process in
                    MobileOSUnixProcess(
                        pid: process.pid,
                        parentPID: process.parentPID,
                        executable: process.executable,
                        argv: process.argv,
                        cwd: process.cwd,
                        state: process.state,
                        exitStatus: process.exitStatus,
                        openFileDescriptors: descriptors[process.pid]?.keys.sorted() ?? []
                    )
                },
            ptySessions: ptys.values
                .sorted { $0.id < $1.id }
                .map { pty in
                    MobileOSPTYSession(
                        id: pty.id,
                        devicePath: "/dev/pts/\(pty.id)",
                        foregroundPID: pty.foregroundPID,
                        rows: pty.rows,
                        columns: pty.columns,
                        pendingOutput: pty.pendingOutput,
                        transcript: pty.transcript
                    )
                },
            mountedPaths: files.keys
                .filter { files[$0]?.type == .directory }
                .sorted(),
            supportedSyscalls: [
                .open, .read, .write, .close, .chdir, .getcwd,
                .mkdir, .rmdir, .unlink, .stat, .fork, .execve,
                .wait4, .pipe, .dup2, .ioctl, .exit
            ],
            primaryPTYID: primaryPTYID,
            primaryShellPID: primaryShellPID
        )
    }

    @discardableResult
    public func spawn(
        executable: String,
        argv: [String] = [],
        parentPID: MobileOSProcessID? = nil,
        cwd: String = "/home/mobile"
    ) throws -> MobileOSProcessID {
        let normalizedExecutable = normalize(executable, cwd: cwd)
        guard isExecutable(normalizedExecutable) else {
            throw VMError.deviceError("execve: \(executable): No such executable")
        }
        guard stat(path: cwd)?.type == .directory else {
            throw VMError.deviceError("spawn: cwd \(cwd) is not a directory")
        }

        let pid = allocatePID()
        let record = ProcessRecord(
            pid: pid,
            parentPID: parentPID,
            executable: normalizedExecutable,
            argv: argv.isEmpty ? [normalizedExecutable] : argv,
            cwd: cwd,
            state: .ready,
            exitStatus: nil
        )
        processes[pid] = record
        descriptors[pid] = [:]
        nextDescriptor[pid] = 0
        return pid
    }

    @discardableResult
    public func openPTY(rows: UInt16 = 24, columns: UInt16 = 80) throws -> MobileOSPTYSession {
        let shellPID = try spawn(
            executable: "/bin/msh",
            argv: ["msh", "-l"],
            parentPID: 100,
            cwd: "/home/mobile"
        )
        let id = nextPTYID
        nextPTYID += 1

        ptys[id] = PTYRecord(
            id: id,
            foregroundPID: shellPID,
            rows: rows,
            columns: columns,
            pendingOutput: "",
            transcript: ""
        )
        primaryPTYID = id
        primaryShellPID = shellPID

        descriptors[shellPID] = [
            0: FileDescriptorRecord(target: .ptySlave(id), offset: 0, readable: true, writable: false, append: false),
            1: FileDescriptorRecord(target: .ptySlave(id), offset: 0, readable: false, writable: true, append: true),
            2: FileDescriptorRecord(target: .ptySlave(id), offset: 0, readable: false, writable: true, append: true)
        ]
        nextDescriptor[shellPID] = 3

        appendPTYOutput(id: id, "MobileOS UNIX tty\(id)\n\(prompt(for: shellPID))")
        return report.ptySessions.first { $0.id == id }!
    }

    public func writePTY(id: UInt32, input: String) throws {
        guard let pty = ptys[id] else {
            throw VMError.deviceError("pty \(id) does not exist")
        }
        guard processes[pty.foregroundPID]?.state != .zombie else {
            appendPTYOutput(id: id, input)
            appendPTYOutput(id: id, "msh: shell has exited\n")
            return
        }

        var lines = input.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        if input.hasSuffix("\n") {
            _ = lines.popLast()
        }

        for command in lines {
            guard !command.isEmpty else {
                appendPTYOutput(id: id, "\n\(prompt(for: pty.foregroundPID))")
                continue
            }
            appendPTYOutput(id: id, "\(command)\n")
            try runShellCommand(command, ptyID: id)
            if processes[pty.foregroundPID]?.state != .zombie {
                appendPTYOutput(id: id, prompt(for: pty.foregroundPID))
            }
        }
    }

    @discardableResult
    public func readPTY(id: UInt32) throws -> String {
        guard var pty = ptys[id] else {
            throw VMError.deviceError("pty \(id) does not exist")
        }
        let output = pty.pendingOutput
        pty.pendingOutput.removeAll()
        ptys[id] = pty
        return output
    }

    public func syscall(pid: MobileOSProcessID, _ request: MobileOSSyscall) throws -> MobileOSSyscallResult {
        guard processes[pid] != nil else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }

        switch request.number {
        case .open:
            return try syscallOpen(pid: pid, request: request)
        case .read:
            return try syscallRead(pid: pid, request: request)
        case .write:
            return try syscallWrite(pid: pid, request: request)
        case .close:
            return syscallClose(pid: pid, request: request)
        case .chdir:
            return syscallChdir(pid: pid, request: request)
        case .getcwd:
            return MobileOSSyscallResult(returnValue: Int64(processes[pid]?.cwd.count ?? 0), text: processes[pid]?.cwd)
        case .mkdir:
            return syscallMkdir(pid: pid, request: request)
        case .rmdir:
            return syscallRmdir(pid: pid, request: request)
        case .unlink:
            return syscallUnlink(pid: pid, request: request)
        case .stat:
            guard let path = request.path else {
                return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
            }
            let normalized = normalize(path, cwd: processes[pid]?.cwd ?? "/")
            guard let stat = stat(path: normalized) else {
                return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
            }
            return MobileOSSyscallResult(returnValue: 0, stat: stat)
        case .fork:
            return syscallFork(pid: pid)
        case .execve:
            return syscallExecve(pid: pid, request: request)
        case .wait4:
            return syscallWait4(pid: pid)
        case .pipe:
            return syscallPipe(pid: pid)
        case .dup2:
            return syscallDup2(pid: pid, request: request)
        case .ioctl:
            return syscallIOCtl(pid: pid, request: request)
        case .exit:
            let status = request.exitStatus ?? 0
            processes[pid]?.state = .zombie
            processes[pid]?.exitStatus = status
            return MobileOSSyscallResult(returnValue: 0)
        }
    }

    private func syscallOpen(pid: MobileOSProcessID, request: MobileOSSyscall) throws -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let cwd = processes[pid]?.cwd ?? "/"
        let path = normalize(rawPath, cwd: cwd)
        let wantsCreate = request.flags.contains(.create)
        let wantsTruncate = request.flags.contains(.truncate)
        let wantsAppend = request.flags.contains(.append)
        let readable = request.flags.contains(.readOnly) || request.flags.contains(.readWrite) || (!request.flags.contains(.writeOnly) && !request.flags.contains(.readWrite))
        let writable = request.flags.contains(.writeOnly) || request.flags.contains(.readWrite) || wantsCreate || wantsTruncate || wantsAppend

        if files[path] == nil {
            guard wantsCreate else {
                return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
            }
            guard ensureParentDirectory(path) else {
                return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
            }
            files[path] = VFSNode(type: .regular, content: [], mode: request.mode ?? 0o644, ownerUID: 501, ownerGID: 20, readOnly: false)
        }

        guard var node = files[path] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        guard node.type != .directory else {
            return MobileOSSyscallResult(returnValue: -1, errno: .isDirectory)
        }
        if node.readOnly && writable {
            return MobileOSSyscallResult(returnValue: -1, errno: .permissionDenied)
        }
        if wantsTruncate {
            node.content = []
            files[path] = node
        }

        let fd = allocateFileDescriptor(pid: pid)
        descriptors[pid]?[fd] = FileDescriptorRecord(
            target: path == "/dev/null" ? .null : .file(path),
            offset: wantsAppend ? node.content.count : 0,
            readable: readable,
            writable: writable,
            append: wantsAppend
        )
        return MobileOSSyscallResult(returnValue: Int64(fd), fileDescriptors: [fd])
    }

    private func syscallRead(pid: MobileOSProcessID, request: MobileOSSyscall) throws -> MobileOSSyscallResult {
        guard let fd = request.fileDescriptor,
              var fdRecord = descriptors[pid]?[fd],
              fdRecord.readable else {
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }

        let byteCount = request.byteCount ?? Int.max
        let bytes: [UInt8]
        switch fdRecord.target {
        case .file(let path):
            guard let node = files[path], node.type == .regular || node.type == .characterDevice else {
                return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
            }
            let start = min(fdRecord.offset, node.content.count)
            let end = min(start + byteCount, node.content.count)
            bytes = Array(node.content[start..<end])
            fdRecord.offset = end
            descriptors[pid]?[fd] = fdRecord
        case .null:
            bytes = []
        case .ptyMaster(let id), .ptySlave(let id):
            bytes = Array((try readPTY(id: id)).utf8.prefix(byteCount))
        case .pipeRead(let id):
            let buffer = pipes[id] ?? []
            let end = min(byteCount, buffer.count)
            bytes = Array(buffer.prefix(end))
            pipes[id] = Array(buffer.dropFirst(end))
        case .pipeWrite:
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }

        return MobileOSSyscallResult(
            returnValue: Int64(bytes.count),
            data: Data(bytes),
            text: String(decoding: bytes, as: UTF8.self)
        )
    }

    private func syscallWrite(pid: MobileOSProcessID, request: MobileOSSyscall) throws -> MobileOSSyscallResult {
        guard let fd = request.fileDescriptor,
              var fdRecord = descriptors[pid]?[fd],
              fdRecord.writable else {
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }

        let bytes = [UInt8](request.data ?? Data(request.text?.utf8 ?? "".utf8))
        switch fdRecord.target {
        case .file(let path):
            guard var node = files[path], node.type == .regular || node.type == .characterDevice else {
                return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
            }
            guard !node.readOnly else {
                return MobileOSSyscallResult(returnValue: -1, errno: .permissionDenied)
            }
            let start = fdRecord.append ? node.content.count : fdRecord.offset
            if start > node.content.count {
                node.content.append(contentsOf: repeatElement(0, count: start - node.content.count))
            }
            let end = start + bytes.count
            if end > node.content.count {
                node.content.append(contentsOf: repeatElement(0, count: end - node.content.count))
            }
            node.content.replaceSubrange(start..<end, with: bytes)
            fdRecord.offset = end
            files[path] = node
            descriptors[pid]?[fd] = fdRecord
        case .null:
            break
        case .ptyMaster(let id), .ptySlave(let id):
            appendPTYOutput(id: id, String(decoding: bytes, as: UTF8.self))
        case .pipeWrite(let id):
            pipes[id, default: []].append(contentsOf: bytes)
        case .pipeRead:
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }

        return MobileOSSyscallResult(returnValue: Int64(bytes.count))
    }

    private func syscallClose(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let fd = request.fileDescriptor,
              descriptors[pid]?[fd] != nil else {
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }
        descriptors[pid]?[fd] = nil
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallChdir(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let path = normalize(rawPath, cwd: processes[pid]?.cwd ?? "/")
        guard let node = files[path] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        guard node.type == .directory else {
            return MobileOSSyscallResult(returnValue: -1, errno: .notDirectory)
        }
        processes[pid]?.cwd = path
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallMkdir(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let path = normalize(rawPath, cwd: processes[pid]?.cwd ?? "/")
        guard files[path] == nil else {
            return MobileOSSyscallResult(returnValue: -1, errno: .fileExists)
        }
        guard ensureParentDirectory(path) else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        files[path] = VFSNode(type: .directory, content: [], mode: request.mode ?? 0o755, ownerUID: 501, ownerGID: 20, readOnly: false)
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallRmdir(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let path = normalize(rawPath, cwd: processes[pid]?.cwd ?? "/")
        guard files[path]?.type == .directory else {
            return MobileOSSyscallResult(returnValue: -1, errno: .notDirectory)
        }
        guard !files.keys.contains(where: { dirname($0) == path }) else {
            return MobileOSSyscallResult(returnValue: -1, errno: .operationNotPermitted)
        }
        files[path] = nil
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallUnlink(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let path = normalize(rawPath, cwd: processes[pid]?.cwd ?? "/")
        guard let node = files[path] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        guard node.type != .directory else {
            return MobileOSSyscallResult(returnValue: -1, errno: .isDirectory)
        }
        guard !node.readOnly else {
            return MobileOSSyscallResult(returnValue: -1, errno: .permissionDenied)
        }
        files[path] = nil
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallFork(pid: MobileOSProcessID) -> MobileOSSyscallResult {
        guard var parent = processes[pid] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        let childPID = allocatePID()
        parent.state = .ready
        parent.exitStatus = nil
        parent.pid = childPID
        parent.parentPID = pid
        processes[childPID] = parent
        descriptors[childPID] = descriptors[pid]
        nextDescriptor[childPID] = nextDescriptor[pid]
        return MobileOSSyscallResult(returnValue: Int64(childPID), pid: childPID)
    }

    private func syscallExecve(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let rawPath = request.path else {
            return MobileOSSyscallResult(returnValue: -1, errno: .invalidArgument)
        }
        let path = normalize(rawPath, cwd: processes[pid]?.cwd ?? "/")
        guard isExecutable(path) else {
            return MobileOSSyscallResult(returnValue: -1, errno: .noSuchFileOrDirectory)
        }
        processes[pid]?.executable = path
        processes[pid]?.argv = request.argv.isEmpty ? [path] : request.argv
        processes[pid]?.state = .running
        processes[pid]?.exitStatus = nil
        return MobileOSSyscallResult(returnValue: 0)
    }

    private func syscallWait4(pid: MobileOSProcessID) -> MobileOSSyscallResult {
        let children = processes.values
            .filter { $0.parentPID == pid }
            .sorted { $0.pid < $1.pid }
        guard let child = children.first(where: { $0.state == .zombie }) else {
            return MobileOSSyscallResult(returnValue: 0)
        }
        let status = child.exitStatus ?? 0
        processes[child.pid]?.state = .stopped
        return MobileOSSyscallResult(returnValue: Int64(child.pid), text: String(status), pid: child.pid)
    }

    private func syscallPipe(pid: MobileOSProcessID) -> MobileOSSyscallResult {
        let id = nextPipeID
        nextPipeID += 1
        pipes[id] = []
        let readFD = allocateFileDescriptor(pid: pid)
        let writeFD = allocateFileDescriptor(pid: pid)
        descriptors[pid]?[readFD] = FileDescriptorRecord(target: .pipeRead(id), offset: 0, readable: true, writable: false, append: false)
        descriptors[pid]?[writeFD] = FileDescriptorRecord(target: .pipeWrite(id), offset: 0, readable: false, writable: true, append: true)
        return MobileOSSyscallResult(returnValue: 0, fileDescriptors: [readFD, writeFD])
    }

    private func syscallDup2(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let source = request.fileDescriptor,
              let target = request.targetFileDescriptor,
              let fdRecord = descriptors[pid]?[source] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }
        descriptors[pid]?[target] = fdRecord
        nextDescriptor[pid] = max(nextDescriptor[pid] ?? 0, target + 1)
        return MobileOSSyscallResult(returnValue: Int64(target), fileDescriptors: [target])
    }

    private func syscallIOCtl(pid: MobileOSProcessID, request: MobileOSSyscall) -> MobileOSSyscallResult {
        guard let fd = request.fileDescriptor,
              let fdRecord = descriptors[pid]?[fd] else {
            return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
        }

        switch fdRecord.target {
        case .ptyMaster(let id), .ptySlave(let id):
            guard let pty = ptys[id] else {
                return MobileOSSyscallResult(returnValue: -1, errno: .badFileDescriptor)
            }
            return MobileOSSyscallResult(returnValue: 0, text: "\(pty.rows)x\(pty.columns)")
        default:
            return MobileOSSyscallResult(returnValue: 0)
        }
    }

    private func runShellCommand(_ line: String, ptyID: UInt32) throws {
        guard let pty = ptys[ptyID] else {
            return
        }
        let pid = pty.foregroundPID
        let tokens = shellTokens(line)
        guard let command = tokens.first else {
            return
        }
        let args = Array(tokens.dropFirst())

        switch command {
        case "exit":
            let status = Int32(args.first ?? "0") ?? 0
            _ = try syscall(pid: pid, MobileOSSyscall(number: .exit, exitStatus: status))
            appendPTYOutput(id: ptyID, "logout\n")
        case "pwd":
            appendPTYOutput(id: ptyID, "\(processes[pid]?.cwd ?? "/")\n")
        case "cd":
            let target = args.first ?? "/home/mobile"
            let result = syscallChdir(pid: pid, request: MobileOSSyscall(number: .chdir, path: target))
            if let errno = result.errno {
                appendPTYOutput(id: ptyID, "cd: \(target): \(message(for: errno))\n")
            }
        case "echo":
            appendPTYOutput(id: ptyID, "\(args.joined(separator: " "))\n")
        case "uname":
            appendPTYOutput(id: ptyID, args.contains("-a") ? "MobileOS mobileos 0.1 arm64-js unix\n" : "MobileOS\n")
        case "whoami":
            appendPTYOutput(id: ptyID, "mobile\n")
        case "ls":
            let target = normalize(args.first ?? ".", cwd: processes[pid]?.cwd ?? "/")
            guard files[target]?.type == .directory else {
                appendPTYOutput(id: ptyID, "ls: \(args.first ?? "."): No such file or directory\n")
                return
            }
            appendPTYOutput(id: ptyID, "\(children(of: target).joined(separator: "  "))\n")
        case "cat":
            for arg in args {
                let path = normalize(arg, cwd: processes[pid]?.cwd ?? "/")
                guard let node = files[path], node.type == .regular || node.type == .characterDevice else {
                    appendPTYOutput(id: ptyID, "cat: \(arg): No such file\n")
                    continue
                }
                appendPTYOutput(id: ptyID, "\(String(decoding: node.content, as: UTF8.self))\n")
            }
        case "touch":
            for arg in args {
                _ = try syscall(pid: pid, MobileOSSyscall(number: .open, path: arg, flags: [.create, .readWrite]))
            }
        case "mkdir":
            for arg in args {
                let result = syscallMkdir(pid: pid, request: MobileOSSyscall(number: .mkdir, path: arg))
                if let errno = result.errno {
                    appendPTYOutput(id: ptyID, "mkdir: \(arg): \(message(for: errno))\n")
                }
            }
        case "rm":
            for arg in args {
                let result = syscallUnlink(pid: pid, request: MobileOSSyscall(number: .unlink, path: arg))
                if let errno = result.errno {
                    appendPTYOutput(id: ptyID, "rm: \(arg): \(message(for: errno))\n")
                }
            }
        case "true":
            break
        case "false":
            appendPTYOutput(id: ptyID, "")
        default:
            appendPTYOutput(id: ptyID, "\(command): command not found\n")
        }
    }

    private func mountBaseFilesystem() {
        ["/", "/bin", "/dev", "/dev/pts", "/etc", "/home", "/home/mobile", "/proc", "/sbin", "/tmp", "/usr", "/usr/bin", "/var", "/var/log"].forEach {
            files[$0] = VFSNode(type: .directory, content: [], mode: 0o755, ownerUID: 0, ownerGID: 0, readOnly: false)
        }
        files["/dev/null"] = VFSNode(type: .characterDevice, content: [], mode: 0o666, ownerUID: 0, ownerGID: 0, readOnly: false)
        writeSystemFile("/etc/os-release", "NAME=MobileOS\nID=mobileos\nVERSION_ID=0.1\n")
        writeSystemFile("/etc/passwd", "mobile:x:501:20:Mobile User:/home/mobile:/bin/msh\n")
        writeSystemFile("/home/mobile/.profile", "export PATH=/bin:/usr/bin\nexport SHELL=/bin/msh\n")

        ["/sbin/init", "/bin/msh", "/bin/sh", "/bin/echo", "/bin/pwd", "/bin/cat", "/bin/ls", "/bin/true", "/bin/false", "/bin/uname", "/bin/mkdir", "/bin/rm", "/bin/touch", "/usr/bin/env", "/usr/bin/apt", "/usr/bin/pkg"].forEach {
            files[$0] = VFSNode(type: .regular, content: Array("#!mobileos\n".utf8), mode: 0o755, ownerUID: 0, ownerGID: 0, readOnly: true)
        }
    }

    private func writeSystemFile(_ path: String, _ text: String) {
        files[path] = VFSNode(type: .regular, content: Array(text.utf8), mode: 0o644, ownerUID: 0, ownerGID: 0, readOnly: true)
    }

    private func allocatePID() -> MobileOSProcessID {
        let pid = nextPID
        nextPID += 1
        return pid
    }

    private func allocateFileDescriptor(pid: MobileOSProcessID) -> MobileOSFileDescriptor {
        let fd = nextDescriptor[pid] ?? 0
        nextDescriptor[pid] = fd + 1
        if descriptors[pid] == nil {
            descriptors[pid] = [:]
        }
        return fd
    }

    private func appendPTYOutput(id: UInt32, _ text: String) {
        guard var pty = ptys[id] else {
            return
        }
        pty.pendingOutput += text
        pty.transcript += text
        ptys[id] = pty
    }

    private func prompt(for pid: MobileOSProcessID) -> String {
        let cwd = processes[pid]?.cwd ?? "/"
        let rendered = cwd == "/home/mobile" ? "~" : cwd
        return "mobile@mobileos:\(rendered)$ "
    }

    private func isExecutable(_ path: String) -> Bool {
        guard let node = files[path], node.type == .regular else {
            return false
        }
        return node.mode & 0o111 != 0
    }

    private func stat(path: String) -> MobileOSFileStat? {
        guard let node = files[path] else {
            return nil
        }
        return MobileOSFileStat(
            path: path,
            type: node.type,
            byteCount: node.content.count,
            mode: node.mode,
            ownerUID: node.ownerUID,
            ownerGID: node.ownerGID
        )
    }

    private func ensureParentDirectory(_ path: String) -> Bool {
        files[dirname(path)]?.type == .directory
    }

    private func children(of path: String) -> [String] {
        files.keys
            .filter { $0 != path && dirname($0) == path }
            .map { basename($0) }
            .sorted()
    }

    private func normalize(_ rawPath: String, cwd: String) -> String {
        let expanded: String
        if rawPath == "~" {
            expanded = "/home/mobile"
        } else if rawPath.hasPrefix("~/") {
            expanded = "/home/mobile" + rawPath.dropFirst()
        } else if rawPath.hasPrefix("/") {
            expanded = rawPath
        } else {
            expanded = "\(cwd)/\(rawPath)"
        }

        var parts: [String] = []
        for part in expanded.split(separator: "/") {
            if part == "." {
                continue
            }
            if part == ".." {
                _ = parts.popLast()
                continue
            }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    private func dirname(_ path: String) -> String {
        guard path != "/" else {
            return "/"
        }
        var parts = path.split(separator: "/").map(String.init)
        _ = parts.popLast()
        return parts.isEmpty ? "/" : "/" + parts.joined(separator: "/")
    }

    private func basename(_ path: String) -> String {
        path.split(separator: "/").last.map(String.init) ?? "/"
    }

    private func shellTokens(_ line: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character?

        for char in line {
            if let activeQuote = quote {
                if char == activeQuote {
                    quote = nil
                } else {
                    current.append(char)
                }
                continue
            }

            if char == "'" || char == "\"" {
                quote = char
                continue
            }
            if char.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current.removeAll()
                }
                continue
            }
            current.append(char)
        }

        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private func message(for errno: MobileOSErrno) -> String {
        switch errno {
        case .operationNotPermitted:
            return "Operation not permitted"
        case .noSuchFileOrDirectory:
            return "No such file or directory"
        case .interrupted:
            return "Interrupted system call"
        case .ioError:
            return "Input/output error"
        case .badFileDescriptor:
            return "Bad file descriptor"
        case .permissionDenied:
            return "Permission denied"
        case .fileExists:
            return "File exists"
        case .notDirectory:
            return "Not a directory"
        case .isDirectory:
            return "Is a directory"
        case .invalidArgument:
            return "Invalid argument"
        case .functionNotImplemented:
            return "Function not implemented"
        }
    }
}
