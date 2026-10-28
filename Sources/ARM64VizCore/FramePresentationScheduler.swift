import Foundation

/// Serially owned by the presentation thread. Metadata receipt never acquires pixels.
/// One slot is reserved from acquisition through worker/GPU completion, including reset.
public final class FramePresentationScheduler {
    public struct Ticket: Hashable, Sendable {
        fileprivate let epoch: UUID
        fileprivate let identifier = UUID()
    }

    public struct Upload: Sendable {
        public let ticket: Ticket
        public let lease: VirtualFramebufferFrameLease
    }

    public enum UploadDisposition: Equatable, Sendable {
        case ready
        case discarded
    }

    private enum Phase { case uploading, ready, queued }
    private struct Active {
        let upload: Upload
        var phase: Phase
    }

    private var epoch = UUID()
    private var active: Active?
    private var latestMetadata: VirtualFramebufferFrameMetadata?
    private var uploadedMetadata: VirtualFramebufferFrameMetadata?
    private var displayedMetadata: VirtualFramebufferFrameMetadata?
    private var redrawRequested = false

    public var latestGeneration: UInt64? { latestMetadata?.generation }
    public var uploadedGeneration: UInt64? { uploadedMetadata?.generation }
    public var displayedGeneration: UInt64? { displayedMetadata?.generation }
    public private(set) var queuedGeneration: UInt64?
    public var isBusy: Bool { active != nil }

    public init() {}

    public var needsRefresh: Bool {
        if let active { return active.phase == .ready }
        guard let latestMetadata else { return false }
        return redrawRequested || !Self.sameFrame(latestMetadata, displayedMetadata)
    }

    public var readyUpload: Upload? {
        guard let active, active.phase == .ready else { return nil }
        return active.upload
    }

    public func isCurrent(_ ticket: Ticket) -> Bool {
        active?.upload.ticket == ticket && ticket.epoch == epoch
    }

    public func receive(_ metadata: VirtualFramebufferFrameMetadata) {
        // A lease can observe a commit before its metadata notification arrives.
        if let latestMetadata,
           metadata.commitTimestampNanoseconds != 0,
           latestMetadata.commitTimestampNanoseconds > metadata.commitTimestampNanoseconds {
            return
        }
        latestMetadata = metadata
    }

    public func requestRedraw() {
        redrawRequested = true
    }

    /// Called only at refresh, not on each notification. The source accumulates damage
    /// from the slot's last successful upload, never from the last advertised frame.
    public func beginRefresh(
        acquireFrame: (UInt64?) -> VirtualFramebufferFrameLease?
    ) -> Upload? {
        guard active == nil, needsRefresh, let latestMetadata else { return nil }
        var previousGeneration = uploadedMetadata?.generation
        if let uploadedMetadata,
           latestMetadata.generation < uploadedMetadata.generation ||
            !Self.sameLayout(latestMetadata, uploadedMetadata) ||
            Self.sameFrame(latestMetadata, uploadedMetadata) {
            // Generation wrap/reset and redisplay require a full lease. Equality is
            // also used after a successful upload that has not been presented.
            previousGeneration = nil
        }
        guard var lease = acquireFrame(previousGeneration) else { return nil }
        if let previousGeneration, lease.metadata.generation < previousGeneration {
            // The source can wrap after the last metadata notification.
            guard let fullLease = acquireFrame(nil) else { return nil }
            lease = fullLease
        }
        self.latestMetadata = lease.metadata
        redrawRequested = false
        let upload = Upload(ticket: Ticket(epoch: epoch), lease: lease)
        active = Active(upload: upload, phase: .uploading)
        return upload
    }

    @discardableResult
    public func finishUpload(_ ticket: Ticket, succeeded: Bool) -> UploadDisposition {
        guard let active, active.upload.ticket == ticket, active.phase == .uploading else {
            return .discarded
        }
        guard ticket.epoch == epoch else {
            self.active = nil
            return .discarded
        }
        guard succeeded else {
            // A failed partial write must not become the next damage baseline.
            uploadedMetadata = nil
            self.active = nil
            return .discarded
        }
        let metadata = active.upload.lease.metadata
        uploadedMetadata = metadata
        // Coalesce before acquisition, not after staging. An acquired refresh must
        // make progress even when the guest commits continuously during the upload.
        self.active?.phase = .ready
        return .ready
    }

    /// Call only once presentation has actually been submitted.
    @discardableResult
    public func markQueued(_ ticket: Ticket) -> Bool {
        guard let active, active.upload.ticket == ticket, active.phase == .ready,
              ticket.epoch == epoch else { return false }
        queuedGeneration = active.upload.lease.metadata.generation
        self.active?.phase = .queued
        return true
    }

    /// Retires the slot on success or failure; stale callbacks cannot update state.
    @discardableResult
    public func complete(_ ticket: Ticket, succeeded: Bool) -> Bool {
        guard let active, active.upload.ticket == ticket,
              active.phase == .queued || (!succeeded && active.phase == .ready) else {
            return false
        }
        self.active = nil
        guard ticket.epoch == epoch else { return false }
        queuedGeneration = nil
        guard succeeded else {
            uploadedMetadata = nil
            return false
        }
        displayedMetadata = active.upload.lease.metadata
        return true
    }

    public func reset() {
        epoch = UUID()
        latestMetadata = nil
        uploadedMetadata = nil
        displayedMetadata = nil
        queuedGeneration = nil
        redrawRequested = false
        // Do not release a worker/GPU reservation early. Its completion retires it.
        if active?.phase == .ready { active = nil }
    }

    private static func sameFrame(
        _ lhs: VirtualFramebufferFrameMetadata,
        _ rhs: VirtualFramebufferFrameMetadata?
    ) -> Bool {
        guard let rhs else { return false }
        return lhs.generation == rhs.generation &&
            lhs.commitTimestampNanoseconds == rhs.commitTimestampNanoseconds &&
            sameLayout(lhs, rhs)
    }

    private static func sameLayout(
        _ lhs: VirtualFramebufferFrameMetadata,
        _ rhs: VirtualFramebufferFrameMetadata
    ) -> Bool {
        lhs.width == rhs.width && lhs.height == rhs.height &&
            lhs.stride == rhs.stride && lhs.bytesPerPixel == rhs.bytesPerPixel
    }
}

/// Shared validation for Metal staging and the CPU image fallback. An empty damage
/// list is a successful zero-byte update, not an allocation/upload failure.
public struct FramePresentationUploadPlan: Sendable {
    public let byteCount: Int
    public let damage: [VirtualFramebufferDamage]

    public init?(metadata: VirtualFramebufferFrameMetadata, requiresFullUpload: Bool) {
        guard metadata.bytesPerPixel == 4,
              metadata.width > 0, metadata.height > 0,
              metadata.width <= Int.max / 4,
              metadata.stride >= metadata.width * 4,
              metadata.height <= Int.max / metadata.stride else { return nil }
        byteCount = metadata.height * metadata.stride
        guard metadata.damage.allSatisfy({ rectangle in
            rectangle.x >= 0 && rectangle.y >= 0 &&
                rectangle.width >= 0 && rectangle.height >= 0 &&
                rectangle.x <= metadata.width && rectangle.y <= metadata.height &&
                rectangle.width <= metadata.width - rectangle.x &&
                rectangle.height <= metadata.height - rectangle.y
        }) else { return nil }
        damage = requiresFullUpload
            ? [VirtualFramebufferDamage(x: 0, y: 0, width: metadata.width, height: metadata.height)]
            : metadata.damage.filter { $0.width > 0 && $0.height > 0 }
    }
}
