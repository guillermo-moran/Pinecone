import ARM64VizCore
import CoreGraphics
import Darwin
import MetalKit
import SwiftUI
import UIKit

typealias GuestDisplayFrameSource = (
    _ previousGeneration: UInt64?
) -> VirtualFramebufferFrameLease?

typealias GuestDisplayPresentedHandler = (
    _ generation: UInt64,
    _ uploadedBytes: Int,
    _ presentedAtNanoseconds: UInt64
) -> Void

struct GuestDisplayLayout: Equatable, Sendable {
    let width: Int
    let height: Int
}

@MainActor
final class GuestDisplayFeed: ObservableObject {
    @Published private(set) var layout: GuestDisplayLayout?

    private var latestMetadata: VirtualFramebufferFrameMetadata?
    private let surfaces = NSHashTable<GuestDisplaySurfaceView>.weakObjects()

    func publish(_ metadata: VirtualFramebufferFrameMetadata) {
        latestMetadata = metadata
        let nextLayout = GuestDisplayLayout(width: metadata.width, height: metadata.height)
        if layout != nextLayout {
            layout = nextLayout
        }
        for surface in surfaces.allObjects {
            surface.present(advertisedMetadata: metadata)
        }
    }

    func reset() {
        latestMetadata = nil
        layout = nil
        for surface in surfaces.allObjects {
            surface.resetFrame()
        }
    }

    fileprivate func attach(_ surface: GuestDisplaySurfaceView) {
        surfaces.add(surface)
        if let latestMetadata {
            surface.present(advertisedMetadata: latestMetadata)
        }
    }

    fileprivate func detach(_ surface: GuestDisplaySurfaceView) {
        surfaces.remove(surface)
    }
}

struct GuestDisplaySurface: UIViewRepresentable {
    let feed: GuestDisplayFeed
    let copyFrame: GuestDisplayFrameSource
    let onPresented: GuestDisplayPresentedHandler

    func makeUIView(context: Context) -> GuestDisplaySurfaceView {
        let view = GuestDisplaySurfaceView()
        view.configure(feed: feed, copyFrame: copyFrame, onPresented: onPresented)
        return view
    }

    func updateUIView(_ view: GuestDisplaySurfaceView, context: Context) {
        view.configure(
            feed: feed,
            copyFrame: copyFrame,
            onPresented: onPresented
        )
    }

    static func dismantleUIView(_ uiView: GuestDisplaySurfaceView, coordinator: ()) {
        uiView.disconnect()
    }
}

@MainActor
final class GuestDisplaySurfaceView: UIView {
    private let metalPresenter: MetalFramebufferPresenter?
    private let fallbackImageView = UIImageView()
    private let scheduler = FramePresentationScheduler()
    private let stagingQueue = DispatchQueue(label: "pinecone.display-staging", qos: .userInteractive)
    private var stagedFrame: StagedFramebuffer?
    private var metalDisabled = false
    private var displayLink: CADisplayLink?
    private var lastLayoutSize: CGSize = .zero
    private weak var feed: GuestDisplayFeed?
    private var copyFrame: GuestDisplayFrameSource?
    private var onPresented: GuestDisplayPresentedHandler?

    override init(frame: CGRect) {
        metalPresenter = MTLCreateSystemDefaultDevice().flatMap(MetalFramebufferPresenter.init)
        super.init(frame: frame)
        backgroundColor = .black
        isOpaque = true
        if let metalPresenter {
            metalPresenter.view.isHidden = true
            addSubview(metalPresenter.view)
        }
        fallbackImageView.backgroundColor = .black
        fallbackImageView.contentMode = .scaleToFill
        fallbackImageView.layer.magnificationFilter = .nearest
        fallbackImageView.layer.minificationFilter = .nearest
        addSubview(fallbackImageView)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    deinit {
        displayLink?.invalidate()
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalPresenter?.view.frame = bounds
        fallbackImageView.frame = bounds
        if lastLayoutSize != bounds.size {
            lastLayoutSize = bounds.size
            scheduler.requestRedraw()
            updateDisplayLink()
        }
    }

    override func didMoveToWindow() {
        super.didMoveToWindow()
        updateDisplayLink()
    }

    func configure(
        feed: GuestDisplayFeed,
        copyFrame: @escaping GuestDisplayFrameSource,
        onPresented: @escaping GuestDisplayPresentedHandler
    ) {
        self.copyFrame = copyFrame
        self.onPresented = onPresented
        if displayLink == nil {
            let target = GuestFramebufferDisplayLinkTarget(owner: self)
            let link = CADisplayLink(target: target, selector: #selector(
                GuestFramebufferDisplayLinkTarget.displayRefresh
            ))
            link.preferredFramesPerSecond = 60
            link.isPaused = true
            link.add(to: .main, forMode: .common)
            displayLink = link
        }
        guard self.feed !== feed else { return }
        self.feed?.detach(self)
        resetFrame()
        self.feed = feed
        feed.attach(self)
    }

    func disconnect() {
        feed?.detach(self)
        feed = nil
        copyFrame = nil
        onPresented = nil
        resetFrame()
        displayLink?.invalidate()
        displayLink = nil
    }

    func resetFrame() {
        scheduler.reset()
        stagedFrame = nil
        metalDisabled = false
        fallbackImageView.image = nil
        fallbackImageView.isHidden = false
        metalPresenter?.view.isHidden = true
        // A worker/command buffer still owns its slot and lease until completion.
        updateDisplayLink()
    }

    fileprivate func present(advertisedMetadata: VirtualFramebufferFrameMetadata) {
        scheduler.receive(advertisedMetadata)
        updateDisplayLink()
    }

    private func updateDisplayLink() {
        displayLink?.isPaused = window == nil || copyFrame == nil || !scheduler.needsRefresh
    }

    fileprivate func displayRefresh() {
        guard window != nil, let copyFrame else {
            updateDisplayLink()
            return
        }
        if scheduler.readyUpload != nil {
            presentReadyFrame()
            updateDisplayLink()
            return
        }
        guard let upload = scheduler.beginRefresh(acquireFrame: copyFrame) else {
            updateDisplayLink()
            return
        }

        // This is the only staging dispatch. The scheduler holds the reservation
        // until upload/presentation retires, so neither reset nor bursts add jobs.
        let previousFrame = stagedFrame
        let device = metalDisabled ? nil : metalPresenter?.device
        stagedFrame = nil
        stagingQueue.async { [weak self] in
            let frame = FramebufferStager.prepare(
                lease: upload.lease, device: device, previousFrame: previousFrame
            )
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                let disposition = self.scheduler.finishUpload(upload.ticket, succeeded: frame != nil)
                if disposition != .discarded {
                    self.stagedFrame = frame
                }
                if disposition == .ready {
                    // Refresh already paced acquisition; no second display-link delay.
                    self.presentReadyFrame()
                }
                self.updateDisplayLink()
            }
        }
        updateDisplayLink()
    }

    private func presentReadyFrame() {
        guard window != nil, let upload = scheduler.readyUpload,
              let frame = stagedFrame else { return }
        if let image = frame.image {
            fallbackImageView.image = UIImage(cgImage: image)
            fallbackImageView.isHidden = false
            metalPresenter?.view.isHidden = true
            guard scheduler.markQueued(upload.ticket),
                  scheduler.complete(upload.ticket, succeeded: true) else { return }
            onPresented?(upload.lease.metadata.generation, frame.uploadedBytes,
                         DispatchTime.now().uptimeNanoseconds)
            return
        }
        guard frame.texture != nil, let metalPresenter else {
            _ = scheduler.complete(upload.ticket, succeeded: false)
            stagedFrame = nil
            return
        }
        // Unhide before obtaining a drawable, but leave the CPU fallback visible
        // until a successful Metal completion.
        metalPresenter.view.isHidden = false
        let submission = metalPresenter.present(frame: frame, lease: upload.lease) { [weak self, frame] succeeded, time in
            guard let self else { return }
            let current = self.scheduler.isCurrent(upload.ticket)
            let presented = self.scheduler.complete(upload.ticket, succeeded: succeeded)
            if presented {
                self.fallbackImageView.isHidden = true
                self.onPresented?(upload.lease.metadata.generation, frame.uploadedBytes, time)
            } else if current && !succeeded {
                self.metalDisabled = true
                self.stagedFrame = nil
            }
            self.updateDisplayLink()
        }
        switch submission {
        case .submitted:
            _ = scheduler.markQueued(upload.ticket)
        case .unavailable:
            break // Keep the ready slot and retry drawable acquisition next refresh.
        case .failed:
            _ = scheduler.complete(upload.ticket, succeeded: false)
            stagedFrame = nil
            metalDisabled = true
        }
    }
}

// Ownership moves to the serial worker only after the GPU reservation retires.
// Shared textures are immutable and retain their source for the entire slot lifetime.
private struct StagedFramebuffer: @unchecked Sendable {
    let texture: MTLTexture?
    let image: CGImage?
    let uploadedBytes: Int
    let sharedBuffer: MTLBuffer?
    let sourceLease: VirtualFramebufferFrameLease?
}

private enum FramebufferStager {
    private static let directSharedScanoutEnabled =
        ProcessInfo.processInfo.environment["PINECONE_DIRECT_SHARED_SCANOUT"] == "1"

    static func prepare(
        lease: VirtualFramebufferFrameLease,
        device: MTLDevice?,
        previousFrame: StagedFramebuffer?
    ) -> StagedFramebuffer? {
        if let device, directSharedScanoutEnabled,
           let frame = bindSharedTexture(lease: lease, device: device) {
            return frame
        }
        // A shared texture is never a replace-region destination.
        let texture = previousFrame?.sourceLease == nil ? previousFrame?.texture : nil
        if let device, let frame = upload(lease: lease, device: device, previousTexture: texture) {
            return frame
        }
        return makeFallbackImage(lease: lease)
    }

    private static func upload(
        lease: VirtualFramebufferFrameLease,
        device: MTLDevice,
        previousTexture: MTLTexture?
    ) -> StagedFramebuffer? {
        let metadata = lease.metadata
        let canReuseTexture = previousTexture?.width == metadata.width &&
            previousTexture?.height == metadata.height
        guard let plan = FramePresentationUploadPlan(
            metadata: metadata, requiresFullUpload: !canReuseTexture
        ) else { return nil }
        return lease.withUnsafeBytes { bytes in
            guard bytes.count >= plan.byteCount, let baseAddress = bytes.baseAddress else { return nil }
            let texture: MTLTexture
            if canReuseTexture, let previousTexture {
                texture = previousTexture
            } else {
                let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                    pixelFormat: .bgra8Unorm, width: metadata.width, height: metadata.height,
                    mipmapped: false
                )
                descriptor.storageMode = .shared
                descriptor.usage = .shaderRead
                guard let allocated = device.makeTexture(descriptor: descriptor) else { return nil }
                texture = allocated
            }
            var uploadedBytes = 0
            for rectangle in plan.damage {
                let offset = rectangle.y * metadata.stride + rectangle.x * metadata.bytesPerPixel
                texture.replace(
                    region: MTLRegionMake2D(rectangle.x, rectangle.y, rectangle.width, rectangle.height),
                    mipmapLevel: 0, withBytes: baseAddress.advanced(by: offset),
                    bytesPerRow: metadata.stride
                )
                uploadedBytes += rectangle.width * rectangle.height * metadata.bytesPerPixel
            }
            return StagedFramebuffer(texture: texture, image: nil, uploadedBytes: uploadedBytes,
                                     sharedBuffer: nil, sourceLease: nil)
        }
    }

    private static func bindSharedTexture(
        lease: VirtualFramebufferFrameLease,
        device: MTLDevice
    ) -> StagedFramebuffer? {
#if targetEnvironment(simulator)
        // MTLSimDevice cannot wrap external storage through XPC.
        return nil
#else
        let metadata = lease.metadata
        guard metadata.hasStableStorage,
              let plan = FramePresentationUploadPlan(metadata: metadata, requiresFullUpload: true) else {
            return nil
        }
        return lease.withUnsafeBytes { bytes in
            let pageSize = Int(getpagesize())
            let rowAlignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
            guard let baseAddress = bytes.baseAddress, bytes.count >= plan.byteCount,
                  pageSize > 0, rowAlignment > 0,
                  Int(bitPattern: baseAddress) % pageSize == 0,
                  bytes.count % pageSize == 0,
                  metadata.stride % rowAlignment == 0,
                  let buffer = device.makeBuffer(
                    bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
                    length: bytes.count, options: .storageModeShared, deallocator: nil
                  ) else { return nil }
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm, width: metadata.width, height: metadata.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            guard let texture = buffer.makeTexture(
                descriptor: descriptor, offset: 0, bytesPerRow: metadata.stride
            ) else { return nil }
            // No address cache: a binding belongs to this exact immutable lease.
            return StagedFramebuffer(texture: texture, image: nil, uploadedBytes: 0,
                                     sharedBuffer: buffer, sourceLease: lease)
        }
#endif
    }

    private static func makeFallbackImage(lease: VirtualFramebufferFrameLease) -> StagedFramebuffer? {
        let metadata = lease.metadata
        guard let plan = FramePresentationUploadPlan(metadata: metadata, requiresFullUpload: true) else {
            return nil
        }
        return lease.withUnsafeBytes { bytes in
            guard bytes.count >= plan.byteCount, let baseAddress = bytes.baseAddress else { return nil }
            let data = Data(bytes: baseAddress, count: plan.byteCount)
            guard let provider = CGDataProvider(data: data as CFData) else { return nil }
            let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
                CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
            )
            guard let image = CGImage(
                width: metadata.width, height: metadata.height,
                bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: metadata.stride,
                space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: bitmapInfo,
                provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent
            ) else { return nil }
            return StagedFramebuffer(texture: nil, image: image, uploadedBytes: plan.byteCount,
                                     sharedBuffer: nil, sourceLease: nil)
        }
    }
}

@MainActor
private final class MetalFramebufferPresenter: NSObject, MTKViewDelegate {
    enum Submission { case submitted, unavailable, failed }

    let device: MTLDevice
    let view: MTKView
    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var drawFrame: (() -> Void)?

    init?(device: MTLDevice) {
        guard let commandQueue = device.makeCommandQueue(),
              let library = try? device.makeLibrary(source: Self.shaderSource, options: nil),
              let vertexFunction = library.makeFunction(name: "pineconeDisplayVertex"),
              let fragmentFunction = library.makeFunction(name: "pineconeDisplayFragment") else {
            return nil
        }
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = vertexFunction
        descriptor.fragmentFunction = fragmentFunction
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else { return nil }
        self.device = device
        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.view = MTKView(frame: .zero, device: device)
        super.init()
        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = false
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
    }

    func present(
        frame: StagedFramebuffer,
        lease: VirtualFramebufferFrameLease,
        completion: @escaping @MainActor @Sendable (Bool, UInt64) -> Void
    ) -> Submission {
        guard let texture = frame.texture else { return .failed }
        var submission = Submission.unavailable
        drawFrame = { [self] in
            guard let descriptor = view.currentRenderPassDescriptor,
                  let drawable = view.currentDrawable else { return }
            guard let commandBuffer = commandQueue.makeCommandBuffer(),
                  let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
                submission = .failed
                return
            }
            encoder.setRenderPipelineState(pipeline)
            encoder.setFragmentTexture(texture, index: 0)
            encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
            encoder.endEncoding()
            commandBuffer.present(drawable)
            commandBuffer.addCompletedHandler { [frame, lease] buffer in
                let succeeded = buffer.status == .completed
                let time = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    // Explicitly retain both source and destination across reset and
                    // through GPU completion. No externally mutable scanout binding.
                    withExtendedLifetime((frame, lease)) { completion(succeeded, time) }
                }
            }
            commandBuffer.commit()
            submission = .submitted
        }
        view.draw()
        drawFrame = nil
        return submission
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}
    func draw(in view: MTKView) { drawFrame?() }

    private static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct PineconeDisplayVertexOut {
        float4 position [[position]];
        float2 textureCoordinate;
    };

    vertex PineconeDisplayVertexOut pineconeDisplayVertex(
        uint vertexID [[vertex_id]]
    ) {
        constexpr float2 positions[] = {
            float2(-1.0, -1.0),
            float2(-1.0,  1.0),
            float2( 1.0, -1.0),
            float2( 1.0,  1.0)
        };
        constexpr float2 textureCoordinates[] = {
            float2(0.0, 1.0),
            float2(0.0, 0.0),
            float2(1.0, 1.0),
            float2(1.0, 0.0)
        };
        PineconeDisplayVertexOut output;
        output.position = float4(positions[vertexID], 0.0, 1.0);
        output.textureCoordinate = textureCoordinates[vertexID];
        return output;
    }

    fragment half4 pineconeDisplayFragment(
        PineconeDisplayVertexOut input [[stage_in]],
        texture2d<half> framebuffer [[texture(0)]]
    ) {
        constexpr sampler nearestSampler(
            coord::normalized,
            address::clamp_to_edge,
            filter::nearest
        );
        return framebuffer.sample(nearestSampler, input.textureCoordinate);
    }
    """
}

@MainActor
private final class GuestFramebufferDisplayLinkTarget: NSObject {
    private weak var owner: GuestDisplaySurfaceView?

    init(owner: GuestDisplaySurfaceView) {
        self.owner = owner
    }

    @objc func displayRefresh() {
        owner?.displayRefresh()
    }
}
