import ARM64VizNative
import Foundation

struct VirGLCapset: Equatable {
    let id: UInt32
    let version: UInt32
    let size: UInt32
}

enum VirGLGPUError: Error {
    case invalidContext, invalidResource, invalidParameter, rendererFailure
}

/// Device commands are serialized by VirtIOGPUDevice; the native implementation
/// additionally owns one dedicated EGL thread and completes GPU work before reply.
protocol VirGLRenderer: AnyObject {
    var name: String { get }
    var capsets: [VirGLCapset] { get }
    func reset() throws
    func finish() throws
    func caps(id: UInt32, version: UInt32) throws -> [UInt8]
    func createContext(id: UInt32, name: [UInt8]) throws
    func destroyContext(id: UInt32) throws
    func createResource(_ descriptor: AVZVirGLResource) throws
    func unrefResource(id: UInt32) throws
    func contextResource(context: UInt32, resource: UInt32, attach: Bool) throws
    func attachBacking(resource: UInt32, size: Int) throws
    func detachBacking(resource: UInt32) throws
    func copyBacking(resource: UInt32, offset: Int, bytes: inout [UInt8], toHost: Bool) throws
    func transfer(_ descriptor: AVZVirGLTransfer, toHost: Bool) throws
    func submit(context: UInt32, words: [UInt32]) throws
    func readPixels(resource: UInt32, width: Int, height: Int) throws -> [UInt8]
}

final class NativeVirGLRenderer: VirGLRenderer {
    private let handle: OpaquePointer
    let name: String
    let capsets: [VirGLCapset]
    private var loggedErrors = 0

    static func requested() -> NativeVirGLRenderer? {
        guard ProcessInfo.processInfo.environment["PINECONE_VIRGL"] == "1" else { return nil }
        let path = ProcessInfo.processInfo.environment["PINECONE_VIRGL_LIBRARY_DIRECTORY"]
            ?? Bundle.main.privateFrameworksPath ?? ""
        do {
            let renderer = try NativeVirGLRenderer(frameworkDirectory: path)
            fputs("Pinecone VirGL renderer: \(renderer.name)\n", stderr)
            return renderer
        }
        catch {
            // Capability negotiation remains 2D when initialization fails.
            fputs("Pinecone VirGL unavailable: \(error)\n", stderr)
            return nil
        }
    }

    init(frameworkDirectory: String) throws {
        var status = [CChar](repeating: 0, count: 256)
        guard let handle = frameworkDirectory.withCString({ path in
            avz_virgl_create(path, &status, status.count)
        }) else { throw NSError(domain: "Pinecone.VirGL", code: 1,
                                userInfo: [NSLocalizedDescriptionKey: String(cString: status)]) }
        var available: [VirGLCapset] = []
        for id: UInt32 in [1, 2] {
            var version: UInt32 = 0, size: UInt32 = 0
            if avz_virgl_capset(handle, id, &version, &size) == 0,
               size > 0, size <= 1_048_576 {
                available.append(VirGLCapset(id: id, version: version, size: size))
            }
        }
        guard !available.isEmpty else {
            avz_virgl_destroy(handle)
            throw VirGLGPUError.rendererFailure
        }
        self.handle = handle
        name = String(cString: status)
        capsets = available
    }

    deinit { avz_virgl_destroy(handle) }
    private func check(_ status: Int32, operation: StaticString = #function) throws {
        guard status == 0 else {
            if loggedErrors < 16 {
                fputs("Pinecone VirGL \(operation) failed: \(status)\n", stderr)
                loggedErrors += 1
            }
            throw VirGLGPUError.rendererFailure
        }
    }
    func reset() throws { try check(avz_virgl_reset(handle)) }
    func finish() throws { try check(avz_virgl_finish(handle)) }
    func caps(id: UInt32, version: UInt32) throws -> [UInt8] {
        guard let cap = capsets.first(where: { $0.id == id }), version <= cap.version else {
            throw VirGLGPUError.invalidParameter
        }
        var bytes = [UInt8](repeating: 0, count: Int(cap.size))
        try bytes.withUnsafeMutableBytes { try check(avz_virgl_caps(handle, id, version, $0.baseAddress, $0.count)) }
        return bytes
    }
    func createContext(id: UInt32, name: [UInt8]) throws {
        try name.withUnsafeBytes { try check(avz_virgl_context_create(handle, id,
            $0.baseAddress?.assumingMemoryBound(to: CChar.self), UInt32($0.count))) }
    }
    func destroyContext(id: UInt32) throws { try check(avz_virgl_context_destroy(handle, id)) }
    func createResource(_ descriptor: AVZVirGLResource) throws {
        var descriptor = descriptor
        try check(avz_virgl_resource_create(handle, &descriptor))
    }
    func unrefResource(id: UInt32) throws { try check(avz_virgl_resource_unref(handle, id)) }
    func contextResource(context: UInt32, resource: UInt32, attach: Bool) throws {
        try check(avz_virgl_context_resource(handle, context, resource, attach ? 1 : 0))
    }
    func attachBacking(resource: UInt32, size: Int) throws { try check(avz_virgl_backing_attach(handle, resource, size)) }
    func detachBacking(resource: UInt32) throws { try check(avz_virgl_backing_detach(handle, resource)) }
    func copyBacking(resource: UInt32, offset: Int, bytes: inout [UInt8], toHost: Bool) throws {
        try bytes.withUnsafeMutableBytes { try check(avz_virgl_backing_copy(handle, resource, offset,
            $0.baseAddress, $0.count, toHost ? 1 : 0)) }
    }
    func transfer(_ descriptor: AVZVirGLTransfer, toHost: Bool) throws {
        var descriptor = descriptor
        try check(avz_virgl_transfer(handle, &descriptor, toHost ? 1 : 0))
    }
    func submit(context: UInt32, words: [UInt32]) throws {
        try words.withUnsafeBufferPointer { try check(avz_virgl_submit(handle, context, $0.baseAddress, $0.count)) }
    }
    func readPixels(resource: UInt32, width: Int, height: Int) throws -> [UInt8] {
        guard width > 0, height > 0, width <= 16384, height <= 16384,
              width <= (256 * 1024 * 1024) / height / 4 else { throw VirGLGPUError.invalidParameter }
        var pixels = [UInt8](repeating: 0, count: width * height * 4)
        try pixels.withUnsafeMutableBytes { try check(avz_virgl_read_pixels(handle, resource,
            UInt32(width), UInt32(height), $0.baseAddress, $0.count)) }
        return pixels
    }
}

/// Standard VirtIO 3D resource state. Guest addresses are validated RAM ranges;
/// renderer backing is a private snapshot, never a borrowed guest pointer.
final class VirGLGPUState {
    struct Backing { let address: UInt64; let count: Int }
    let renderer: VirGLRenderer
    private(set) var contexts: Set<UInt32> = []
    private(set) var resources: [UInt32: AVZVirGLResource] = [:]
    private var backings: [UInt32: [Backing]] = [:]
    private var attachments: [UInt32: Set<UInt32>] = [:]
    var submitCount: UInt64 = 0
    var readbackCount: UInt64 = 0

    init(renderer: VirGLRenderer) { self.renderer = renderer }
    func reset() throws {
        try renderer.reset()
        contexts.removeAll(); resources.removeAll(); backings.removeAll(); attachments.removeAll()
        submitCount = 0; readbackCount = 0
    }
    func createContext(id: UInt32, name: [UInt8]) throws {
        guard id > 0, id <= UInt32(Int32.max), !contexts.contains(id), contexts.count < 256,
              name.count <= 64 else { throw VirGLGPUError.invalidContext }
        try renderer.createContext(id: id, name: name)
        contexts.insert(id); attachments[id] = []
    }
    func destroyContext(id: UInt32) throws {
        guard contexts.contains(id) else { throw VirGLGPUError.invalidContext }
        try renderer.destroyContext(id: id)
        contexts.remove(id); attachments[id] = nil
    }
    func createResource(_ descriptor: AVZVirGLResource) throws {
        guard descriptor.handle > 0, descriptor.handle <= UInt32(Int32.max),
              resources[descriptor.handle] == nil, resources.count < 4096 else { throw VirGLGPUError.invalidResource }
        guard descriptor.target <= 9, descriptor.width > 0, descriptor.height > 0,
              descriptor.depth > 0, descriptor.array_size > 0,
              descriptor.width <= (descriptor.target == 0 ? 256 * 1024 * 1024 : 16384),
              descriptor.height <= 16384, descriptor.depth <= 2048,
              descriptor.array_size <= 2048, descriptor.last_level <= 14,
              descriptor.nr_samples <= 16, descriptor.flags & ~1 == 0 else { throw VirGLGPUError.invalidParameter }
        try renderer.createResource(descriptor)
        resources[descriptor.handle] = descriptor
    }
    func unrefResource(id: UInt32) throws {
        guard resources[id] != nil else { throw VirGLGPUError.invalidResource }
        try renderer.unrefResource(id: id)
        resources[id] = nil; backings[id] = nil
        for context in contexts { attachments[context]?.remove(id) }
    }
    func contextResource(context: UInt32, resource: UInt32, attach: Bool) throws {
        guard contexts.contains(context) else { throw VirGLGPUError.invalidContext }
        guard resources[resource] != nil else { throw VirGLGPUError.invalidResource }
        try renderer.contextResource(context: context, resource: resource, attach: attach)
        if attach { attachments[context, default: []].insert(resource) }
        else { attachments[context]?.remove(resource) }
    }
    func attachBacking(resource: UInt32, entries: [Backing], memory: PhysicalMemory) throws {
        guard resources[resource] != nil else { throw VirGLGPUError.invalidResource }
        guard backings[resource] == nil, !entries.isEmpty, entries.count <= 16384 else { throw VirGLGPUError.invalidParameter }
        var total = 0
        for entry in entries {
            guard entry.count > 0, entry.address >= memory.base,
                  entry.address - memory.base <= UInt64(memory.size),
                  UInt64(entry.count) <= UInt64(memory.size) - (entry.address - memory.base),
                  entry.count <= 256 * 1024 * 1024 - total else { throw VirGLGPUError.invalidParameter }
            total += entry.count
        }
        try renderer.attachBacking(resource: resource, size: total)
        backings[resource] = entries
    }
    func detachBacking(resource: UInt32) throws {
        guard resources[resource] != nil else { throw VirGLGPUError.invalidResource }
        try renderer.detachBacking(resource: resource); backings[resource] = nil
    }
    private func copyBacking(resource: UInt32, memory: PhysicalMemory, toHost: Bool) throws {
        guard let entries = backings[resource] else { throw VirGLGPUError.invalidParameter }
        var offset = 0
        for entry in entries {
            var copied = 0
            while copied < entry.count {
                let count = min(entry.count - copied, 1_048_576)
                var bytes = toHost ? try memory.readBytes(at: entry.address + UInt64(copied), count: count)
                    : [UInt8](repeating: 0, count: count)
                try renderer.copyBacking(resource: resource, offset: offset + copied, bytes: &bytes, toHost: toHost)
                if !toHost { try memory.writeBytes(bytes, at: entry.address + UInt64(copied)) }
                copied += count
            }
            offset += entry.count
        }
    }
    func transfer(_ descriptor: AVZVirGLTransfer, memory: PhysicalMemory, toHost: Bool) throws {
        guard let resource = resources[descriptor.handle] else { throw VirGLGPUError.invalidResource }
        if descriptor.context != 0 {
            guard contexts.contains(descriptor.context) else { throw VirGLGPUError.invalidContext }
            guard attachments[descriptor.context]?.contains(descriptor.handle) == true else { throw VirGLGPUError.invalidResource }
        }
        guard descriptor.level <= resource.last_level,
              descriptor.width > 0, descriptor.height > 0, descriptor.depth > 0 else { throw VirGLGPUError.invalidParameter }
        guard let entries = backings[descriptor.handle],
              descriptor.offset < UInt64(entries.reduce(0) { $0 + $1.count }) else { throw VirGLGPUError.invalidParameter }
        let width = max(1, resource.width >> descriptor.level)
        let height = max(1, resource.height >> descriptor.level)
        let depth = resource.target == 3 ? max(1, resource.depth >> descriptor.level)
            : max(resource.depth, resource.array_size)
        guard descriptor.x <= width, descriptor.width <= width - descriptor.x,
              descriptor.y <= height, descriptor.height <= height - descriptor.y,
              descriptor.z <= depth, descriptor.depth <= depth - descriptor.z else { throw VirGLGPUError.invalidParameter }
        // A readback can touch only part of an iovec. Preserve current guest
        // bytes outside that region before the renderer updates the snapshot.
        try copyBacking(resource: descriptor.handle, memory: memory, toHost: true)
        try renderer.transfer(descriptor, toHost: toHost)
        if !toHost { try copyBacking(resource: descriptor.handle, memory: memory, toHost: false) }
    }
    func submit(context: UInt32, words: [UInt32], memory: PhysicalMemory) throws {
        guard contexts.contains(context) else { throw VirGLGPUError.invalidContext }
        guard !words.isEmpty, words.count <= 262144 else { throw VirGLGPUError.invalidParameter }
        // Mesa batches transfers inside SUBMIT3D as well as issuing separate
        // VirtIO transfer requests. Native iovecs point at our snapshots, not
        // guest RAM, so refresh each referenced backing before decoding the
        // stream and publish any readbacks after its synchronous completion.
        var snapshots: Set<UInt32> = [], readbacks: Set<UInt32> = []
        var cursor = 0
        while cursor < words.count {
            let length = Int(words[cursor] >> 16)
            guard length < words.count - cursor else { throw VirGLGPUError.invalidParameter }
            let opcode = words[cursor] & 0xff
            var backing: UInt32?
            var writesGuest = false
            switch opcode {
            case 43: // VIRGL_CCMD_TRANSFER3D
                guard length >= 13 else { throw VirGLGPUError.invalidParameter }
                backing = words[cursor + 1]
                let direction = words[cursor + 13]
                guard direction == 1 || direction == 2 else { throw VirGLGPUError.invalidParameter }
                writesGuest = direction == 2
            case 45: // VIRGL_CCMD_COPY_TRANSFER3D
                guard length == 14 else { throw VirGLGPUError.invalidParameter }
                let texture = words[cursor + 1]
                guard resources[texture] != nil,
                      attachments[context]?.contains(texture) == true else { throw VirGLGPUError.invalidResource }
                backing = words[cursor + 12]
                writesGuest = words[cursor + 14] & 2 != 0
            default: break
            }
            if let backing {
                guard resources[backing] != nil,
                      attachments[context]?.contains(backing) == true else { throw VirGLGPUError.invalidResource }
                guard backings[backing] != nil else { throw VirGLGPUError.invalidParameter }
                snapshots.insert(backing)
                if writesGuest { readbacks.insert(backing) }
            }
            cursor += length + 1
        }
        for resource in snapshots.sorted() { try copyBacking(resource: resource, memory: memory, toHost: true) }
        try renderer.submit(context: context, words: words)
        for resource in readbacks.sorted() { try copyBacking(resource: resource, memory: memory, toHost: false) }
        submitCount &+= 1
        if submitCount == 1 { fputs("Pinecone VirGL: first guest GPU submission completed (context \(context), \(words.count) words)\n", stderr) }
    }
    func readPixels(resource: UInt32) throws -> [UInt8] {
        guard let descriptor = resources[resource] else { throw VirGLGPUError.invalidResource }
        let pixels = try renderer.readPixels(resource: resource, width: Int(descriptor.width), height: Int(descriptor.height))
        guard pixels.count == Int(descriptor.width) * Int(descriptor.height) * 4 else { throw VirGLGPUError.rendererFailure }
        readbackCount &+= 1; return pixels
    }
}
