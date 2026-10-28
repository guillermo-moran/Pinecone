import Foundation

/// Resource hazards are independent of guest fence retirement order.
struct GPUResourceAccess: Equatable {
    var reads: Set<UInt32> = []
    var writes: Set<UInt32> = []
    var isGlobal = false

    static let global = GPUResourceAccess(isGlobal: true)

    func conflicts(with other: GPUResourceAccess) -> Bool {
        isGlobal || other.isGlobal ||
            !writes.isDisjoint(with: other.writes) ||
            !writes.isDisjoint(with: other.reads) ||
            !reads.isDisjoint(with: other.writes)
    }

    static func parse(_ request: [UInt8]) -> GPUResourceAccess {
        guard request.count >= 24,
              let command = VirtIOGPUDevice.Command(rawValue: read32(request, 0)) else {
            return .global
        }
        switch command {
        case .transferToHost2D:
            guard request.count >= 56 else { return .global }
            return GPUResourceAccess(writes: [read32(request, 48)])
        case .submit3D:
            return parseSubmission(request)
        default:
            // Lifecycle, presentation, cursor, and unknown commands may change
            // shared device state, not just the resource named in their payload.
            return .global
        }
    }

    private static func parseSubmission(_ request: [UInt8]) -> GPUResourceAccess {
        let payloadStart = 32
        guard request.count >= payloadStart + 8 else { return .global }
        let payloadSize = Int(read32(request, 24))
        guard payloadSize >= 8, payloadSize <= request.count - payloadStart,
              read32(request, payloadStart) == PineconeGraphicsProtocol.magic else {
            return .global
        }
        let version = read16(request, payloadStart + 4)
        let starts: [Int]
        switch version {
        case PineconeGraphicsProtocol.version, PineconeGraphicsProtocol.exactCompositeVersion:
            guard payloadSize == PineconeGraphicsProtocol.payloadByteCount else { return .global }
            starts = [payloadStart]
        case PineconeGraphicsProtocol.batchVersion:
            guard payloadSize >= PineconeGraphicsProtocol.batchHeaderByteCount else { return .global }
            let count = Int(read16(request, payloadStart + 6))
            let stride = Int(read16(request, payloadStart + 8))
            guard count > 0, count <= PineconeGraphicsProtocol.maximumBatchCommandCount,
                  stride == PineconeGraphicsProtocol.batchRecordByteCount,
                  read16(request, payloadStart + 10) == 0,
                  payloadSize == PineconeGraphicsProtocol.batchHeaderByteCount + count * stride,
                  Int(read32(request, payloadStart + 12)) == payloadSize else { return .global }
            starts = (0..<count).map {
                payloadStart + PineconeGraphicsProtocol.batchHeaderByteCount + $0 * stride
            }
        default:
            return .global
        }
        var access = GPUResourceAccess()
        for start in starts {
            guard start + PineconeGraphicsProtocol.payloadByteCount <= request.count,
                  read32(request, start) == PineconeGraphicsProtocol.magic else { return .global }
            let recordVersion = read16(request, start + 4)
            let operation = read16(request, start + 6)
            let flags = read32(request, start + 8)
            if recordVersion == PineconeGraphicsProtocol.version {
                guard PineconeGraphicsOperation(rawValue: operation) != nil,
                      flags & ~PineconeGraphicsProtocol.legacySupportedFlags == 0 else { return .global }
            } else if recordVersion == PineconeGraphicsProtocol.exactCompositeVersion {
                guard PineconeGraphicsBlendOperator(rawValue: operation) != nil,
                      flags & ~PineconeGraphicsProtocol.supportedFlags == 0 else { return .global }
            } else {
                return .global
            }
            let destination = read32(request, start + 16)
            guard destination != 0 else { return .global }
            access.writes.insert(destination)
            for offset in [12, 56] {
                let resource = read32(request, start + offset)
                if resource != 0 { access.reads.insert(resource) }
            }
        }
        return access
    }

    private static func read16(_ bytes: [UInt8], _ offset: Int) -> UInt16 {
        UInt16(bytes[offset]) | UInt16(bytes[offset + 1]) << 8
    }

    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 {
        UInt32(read16(bytes, offset)) | UInt32(read16(bytes, offset + 2)) << 16
    }
}
