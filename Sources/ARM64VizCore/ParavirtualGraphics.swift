import Foundation

/// Pinecone's private 2D protocol carried inside VIRTIO_GPU_CMD_SUBMIT_3D.
///
/// The outer virtio command remains standards-compliant. A patched open-source
/// guest driver opts into this payload; unmodified guests continue using the
/// regular virtio-gpu 2D commands.
public enum PineconeGraphicsProtocol {
    public static let magic: UInt32 = 0x504e_3244 // "PN2D"
    public static let version: UInt16 = 3
    /// Version 5 keeps the 64-byte record layout but carries the exact Pixman
    /// operator and explicit source/mask semantics.
    public static let exactCompositeVersion: UInt16 = 5
    public static let payloadByteCount = 64

    /// Version 4 wraps complete v3 records in a bounded command list. Keeping
    /// the records unchanged makes the ABI easy to validate at every layer and
    /// preserves v3 as a compatibility path for older guest bridges.
    public static let batchVersion: UInt16 = 4
    public static let batchHeaderByteCount = 16
    public static let batchRecordByteCount = payloadByteCount
    public static let maximumBatchCommandCount = 64

    public static let sourceContainsAlphaFlag: UInt32 = 1 << 0
    public static let bilinearFilterFlag: UInt32 = 1 << 1
    public static let hasMaskFlag: UInt32 = 1 << 2
    public static let solidMaskFlag: UInt32 = 1 << 3
    public static let solidSourceFlag: UInt32 = 1 << 4
    public static let componentAlphaMaskFlag: UInt32 = 1 << 5
    public static let packedA8MaskFlag: UInt32 = 1 << 6
    public static let legacySupportedFlags = sourceContainsAlphaFlag |
        bilinearFilterFlag | hasMaskFlag | solidMaskFlag
    public static let supportedFlags = legacySupportedFlags | solidSourceFlag |
        componentAlphaMaskFlag | packedA8MaskFlag
}

/// Pixman's stable operator values used by protocol v5.
public enum PineconeGraphicsBlendOperator: UInt16, Sendable {
    case clear = 0x00
    case source = 0x01
    case destination = 0x02
    case sourceOver = 0x03
    case add = 0x0c
}

public enum PineconeGraphicsOperation: UInt16, Sendable {
    case source = 1
    case sourceOver = 2
    case fill = 3
    case fillOver = 4
}

public enum PineconeGraphicsPixelFormat: UInt32, Sendable {
    case bgra8Premultiplied = 1
    case bgrx8 = 2
}

public struct PineconeGraphicsRectangle: Equatable, Sendable {
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
}

public struct PineconeGraphicsCommand: Equatable, Sendable {
    public let operation: PineconeGraphicsOperation
    public let blendOperator: PineconeGraphicsBlendOperator
    public let sourceIsSolid: Bool
    public let sourceResourceID: UInt32
    public let destinationResourceID: UInt32
    public let sourceX: Int
    public let sourceY: Int
    public let sourceWidth: Int
    public let sourceHeight: Int
    public let destinationRectangle: PineconeGraphicsRectangle
    /// Premultiplied BGRA8, packed as a little-endian UInt32.
    public let color: UInt32
    /// The source bytes carry premultiplied alpha even when their reusable
    /// upload resource was allocated as a DRM XRGB dumb buffer.
    public let sourceContainsAlpha: Bool
    /// Samples scaled sources with bilinear filtering. Nearest-neighbor is the
    /// protocol default and remains exact for unscaled copies.
    public let usesBilinearFiltering: Bool
    /// A mask stored as BGRA8 whose alpha byte modulates the premultiplied
    /// source. Zero means no image mask.
    public let maskResourceID: UInt32
    /// Scalar alpha used when `maskResourceID` is zero and a solid mask exists.
    public let maskAlpha: UInt8?
    public let componentAlphaMask: Bool
    public let maskIsPackedA8: Bool

    public init(
        operation: PineconeGraphicsOperation,
        sourceResourceID: UInt32,
        destinationResourceID: UInt32,
        sourceX: Int,
        sourceY: Int,
        sourceWidth: Int? = nil,
        sourceHeight: Int? = nil,
        destinationRectangle: PineconeGraphicsRectangle,
        color: UInt32 = 0,
        sourceContainsAlpha: Bool = false,
        usesBilinearFiltering: Bool = false,
        maskResourceID: UInt32 = 0,
        maskAlpha: UInt8? = nil,
        blendOperator: PineconeGraphicsBlendOperator? = nil,
        sourceIsSolid: Bool? = nil,
        componentAlphaMask: Bool = false,
        maskIsPackedA8: Bool = false
    ) {
        self.operation = operation
        self.blendOperator = blendOperator ?? (
            operation == .source || operation == .fill ? .source : .sourceOver
        )
        self.sourceIsSolid = sourceIsSolid ?? (
            operation == .fill || operation == .fillOver
        )
        self.sourceResourceID = sourceResourceID
        self.destinationResourceID = destinationResourceID
        self.sourceX = sourceX
        self.sourceY = sourceY
        self.sourceWidth = sourceWidth ?? destinationRectangle.width
        self.sourceHeight = sourceHeight ?? destinationRectangle.height
        self.destinationRectangle = destinationRectangle
        self.color = color
        self.sourceContainsAlpha = sourceContainsAlpha
        self.usesBilinearFiltering = usesBilinearFiltering
        self.maskResourceID = maskResourceID
        self.maskAlpha = maskAlpha
        self.componentAlphaMask = componentAlphaMask
        self.maskIsPackedA8 = maskIsPackedA8
    }
}

/// A page-aligned host allocation whose address remains stable until the
/// corresponding virtio-gpu resource is destroyed.
public struct PineconeGraphicsSurface {
    public let resourceID: UInt32
    public let width: Int
    public let height: Int
    public let stride: Int
    public let pixelFormat: PineconeGraphicsPixelFormat
    public let bytes: UnsafeMutableRawBufferPointer
    public let allocationByteCount: Int

    public init(
        resourceID: UInt32,
        width: Int,
        height: Int,
        stride: Int,
        pixelFormat: PineconeGraphicsPixelFormat,
        bytes: UnsafeMutableRawBufferPointer,
        allocationByteCount: Int
    ) {
        self.resourceID = resourceID
        self.width = width
        self.height = height
        self.stride = stride
        self.pixelFormat = pixelFormat
        self.bytes = bytes
        self.allocationByteCount = allocationByteCount
    }
}

/// One fully resolved operation in a host graphics batch. Resource IDs have
/// already been translated and all surfaces have passed Core validation.
public struct PineconeGraphicsWorkItem {
    public let command: PineconeGraphicsCommand
    public let source: PineconeGraphicsSurface?
    public let mask: PineconeGraphicsSurface?
    public let destination: PineconeGraphicsSurface

    public init(
        command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) {
        self.command = command
        self.source = source
        self.mask = mask
        self.destination = destination
    }
}

/// Implementations execute synchronously. Returning false asks Core to use its
/// native C implementation for this host graphics operation; it never invokes
/// the ARM64 instruction fallback interpreter.
public protocol PineconeGraphicsAccelerator: AnyObject {
    func execute(
        _ command: PineconeGraphicsCommand,
        source: PineconeGraphicsSurface?,
        mask: PineconeGraphicsSurface?,
        destination: PineconeGraphicsSurface
    ) -> Bool

    /// Executes the complete list atomically from Core's perspective. A false
    /// result means no command may have modified a destination.
    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool

    func discardSurface(resourceID: UInt32)
    func reset()
}

public extension PineconeGraphicsAccelerator {
    func executeBatch(_ workItems: [PineconeGraphicsWorkItem]) -> Bool {
        guard workItems.count == 1, let item = workItems.first else {
            return workItems.isEmpty
        }
        return execute(
            item.command,
            source: item.source,
            mask: item.mask,
            destination: item.destination
        )
    }

    func discardSurface(resourceID: UInt32) {}
    func reset() {}
}
