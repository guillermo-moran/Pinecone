import ARM64VizCore
import CoreGraphics
import Darwin
import MetalKit
import SwiftUI
import UIKit

typealias GuestDisplayFrameSource = (
    _ previousGeneration: UInt64?,
    _ body: (
        _ metadata: VirtualFramebufferFrameMetadata,
        _ bytes: UnsafeRawBufferPointer
    ) -> Void
) -> VirtualFramebufferFrameMetadata?

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

final class GuestDisplaySurfaceView: UIView {
    private let metalPresenter: MetalFramebufferPresenter?
    private let fallbackImageView: UIImageView?
    private var uploadedGeneration: UInt64?
    private weak var feed: GuestDisplayFeed?
    private var copyFrame: GuestDisplayFrameSource?
    private var onPresented: GuestDisplayPresentedHandler?

    override init(frame: CGRect) {
        if let device = MTLCreateSystemDefaultDevice(),
           let presenter = MetalFramebufferPresenter(device: device) {
            metalPresenter = presenter
            fallbackImageView = nil
        } else {
            metalPresenter = nil
            fallbackImageView = UIImageView()
        }
        super.init(frame: frame)

        backgroundColor = .black
        isOpaque = true
        if let metalPresenter {
            addSubview(metalPresenter.view)
        } else if let fallbackImageView {
            fallbackImageView.backgroundColor = .black
            fallbackImageView.contentMode = .scaleToFill
            fallbackImageView.layer.magnificationFilter = .nearest
            fallbackImageView.layer.minificationFilter = .nearest
            addSubview(fallbackImageView)
        }
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    override func layoutSubviews() {
        super.layoutSubviews()
        metalPresenter?.view.frame = bounds
        fallbackImageView?.frame = bounds
        metalPresenter?.requestDraw()
    }

    func configure(
        feed: GuestDisplayFeed,
        copyFrame: @escaping GuestDisplayFrameSource,
        onPresented: @escaping GuestDisplayPresentedHandler
    ) {
        self.copyFrame = copyFrame
        self.onPresented = onPresented
        guard self.feed !== feed else { return }
        self.feed?.detach(self)
        self.feed = feed
        feed.attach(self)
    }

    func disconnect() {
        feed?.detach(self)
        feed = nil
        copyFrame = nil
        onPresented = nil
    }

    func resetFrame() {
        uploadedGeneration = nil
        fallbackImageView?.image = nil
        metalPresenter?.reset()
    }

    fileprivate func present(advertisedMetadata: VirtualFramebufferFrameMetadata) {
        guard let copyFrame, let onPresented else { return }
        guard advertisedMetadata.generation != uploadedGeneration else {
            metalPresenter?.requestDraw()
            return
        }

        if let metalPresenter {
            var uploadedBytes = 0
            let copiedMetadata = copyFrame(uploadedGeneration) { metadata, bytes in
                uploadedBytes = metalPresenter.upload(metadata: metadata, bytes: bytes)
            }
            guard let copiedMetadata else { return }
            uploadedGeneration = copiedMetadata.generation
            metalPresenter.submit(
                generation: copiedMetadata.generation,
                uploadedBytes: uploadedBytes,
                onPresented: onPresented
            )
            return
        }

        var frameData: Data?
        let copiedMetadata = copyFrame(uploadedGeneration) { metadata, bytes in
            guard bytes.count >= metadata.stride * metadata.height,
                  let baseAddress = bytes.baseAddress else {
                return
            }
            frameData = Data(
                bytes: baseAddress,
                count: metadata.stride * metadata.height
            )
        }
        guard let copiedMetadata,
              let frameData,
              let image = Self.makeFallbackImage(metadata: copiedMetadata, data: frameData) else {
            return
        }
        uploadedGeneration = copiedMetadata.generation
        fallbackImageView?.image = UIImage(cgImage: image)
        onPresented(
            copiedMetadata.generation,
            frameData.count,
            DispatchTime.now().uptimeNanoseconds
        )
    }

    private static func makeFallbackImage(
        metadata: VirtualFramebufferFrameMetadata,
        data: Data
    ) -> CGImage? {
        guard metadata.bytesPerPixel == 4,
              metadata.stride >= metadata.width * metadata.bytesPerPixel,
              data.count >= metadata.stride * metadata.height,
              let provider = CGDataProvider(data: data as CFData) else {
            return nil
        }
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.union(
            CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipFirst.rawValue)
        )
        return CGImage(
            width: metadata.width,
            height: metadata.height,
            bitsPerComponent: 8,
            bitsPerPixel: 32,
            bytesPerRow: metadata.stride,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: bitmapInfo,
            provider: provider,
            decode: nil,
            shouldInterpolate: false,
            intent: .defaultIntent
        )
    }
}

private final class MetalFramebufferPresenter: NSObject, MTKViewDelegate {
    let view: MTKView

    private let commandQueue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private var texture: MTLTexture?
    private var sharedBuffer: MTLBuffer?
    private var sharedBufferAddress: UnsafeRawPointer?
    private var sharedBufferLength = 0
    private var textureUsesSharedStorage = false
    private var pendingPresentation: (
        generation: UInt64,
        uploadedBytes: Int,
        handler: GuestDisplayPresentedHandler
    )?

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
        guard let pipeline = try? device.makeRenderPipelineState(descriptor: descriptor) else {
            return nil
        }

        self.commandQueue = commandQueue
        self.pipeline = pipeline
        self.view = MTKView(frame: .zero, device: device)
        super.init()

        view.delegate = self
        view.colorPixelFormat = .bgra8Unorm
        view.clearColor = MTLClearColorMake(0, 0, 0, 1)
        view.framebufferOnly = true
        view.isPaused = true
        view.enableSetNeedsDisplay = true
        view.autoResizeDrawable = true
        view.isOpaque = true
        view.backgroundColor = .black
    }

    func upload(
        metadata: VirtualFramebufferFrameMetadata,
        bytes: UnsafeRawBufferPointer
    ) -> Int {
        guard metadata.bytesPerPixel == 4,
              metadata.width > 0,
              metadata.height > 0,
              metadata.stride >= metadata.width * metadata.bytesPerPixel,
              bytes.count >= metadata.stride * metadata.height,
              let baseAddress = bytes.baseAddress,
              let device = view.device else {
            return 0
        }

        if metadata.hasStableStorage,
           bindSharedTexture(
               device: device,
               metadata: metadata,
               bytes: bytes,
               baseAddress: baseAddress
           ) {
            return 0
        }

        sharedBuffer = nil
        sharedBufferAddress = nil
        sharedBufferLength = 0

        let textureWasRecreated: Bool
        if textureUsesSharedStorage ||
            texture?.width != metadata.width || texture?.height != metadata.height {
            let descriptor = MTLTextureDescriptor.texture2DDescriptor(
                pixelFormat: .bgra8Unorm,
                width: metadata.width,
                height: metadata.height,
                mipmapped: false
            )
            descriptor.storageMode = .shared
            descriptor.usage = .shaderRead
            texture = device.makeTexture(descriptor: descriptor)
            textureUsesSharedStorage = false
            textureWasRecreated = true
        } else {
            textureWasRecreated = false
        }
        guard let texture else { return 0 }

        let damage = textureWasRecreated
            ? [VirtualFramebufferDamage(
                x: 0,
                y: 0,
                width: metadata.width,
                height: metadata.height
            )]
            : metadata.damage
        var uploadedBytes = 0
        for rectangle in damage {
            guard rectangle.width > 0,
                  rectangle.height > 0,
                  rectangle.x >= 0,
                  rectangle.y >= 0,
                  rectangle.x + rectangle.width <= metadata.width,
                  rectangle.y + rectangle.height <= metadata.height else {
                continue
            }
            let sourceOffset = rectangle.y * metadata.stride +
                rectangle.x * metadata.bytesPerPixel
            texture.replace(
                region: MTLRegionMake2D(
                    rectangle.x,
                    rectangle.y,
                    rectangle.width,
                    rectangle.height
                ),
                mipmapLevel: 0,
                withBytes: baseAddress.advanced(by: sourceOffset),
                bytesPerRow: metadata.stride
            )
            uploadedBytes += rectangle.width * rectangle.height * metadata.bytesPerPixel
        }
        return uploadedBytes
    }

    private func bindSharedTexture(
        device: MTLDevice,
        metadata: VirtualFramebufferFrameMetadata,
        bytes: UnsafeRawBufferPointer,
        baseAddress: UnsafeRawPointer
    ) -> Bool {
#if targetEnvironment(simulator)
        // MTLSimDevice traps while wrapping external storage through XPC.
        // The simulator keeps the incremental replace-region path below.
        return false
#else
        let pageSize = Int(getpagesize())
        let rowAlignment = device.minimumLinearTextureAlignment(for: .bgra8Unorm)
        guard pageSize > 0, rowAlignment > 0,
              Int(bitPattern: baseAddress) % pageSize == 0,
              bytes.count % pageSize == 0,
              metadata.stride % rowAlignment == 0 else {
            return false
        }

        if textureUsesSharedStorage,
           sharedBufferAddress == baseAddress,
           sharedBufferLength == bytes.count,
           texture?.width == metadata.width,
           texture?.height == metadata.height {
            return true
        }

        guard let buffer = device.makeBuffer(
            bytesNoCopy: UnsafeMutableRawPointer(mutating: baseAddress),
            length: bytes.count,
            options: .storageModeShared,
            deallocator: nil
        ) else {
            return false
        }
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(
            pixelFormat: .bgra8Unorm,
            width: metadata.width,
            height: metadata.height,
            mipmapped: false
        )
        descriptor.storageMode = .shared
        descriptor.usage = .shaderRead
        guard let sharedTexture = buffer.makeTexture(
            descriptor: descriptor,
            offset: 0,
            bytesPerRow: metadata.stride
        ) else {
            return false
        }

        sharedBuffer = buffer
        sharedBufferAddress = baseAddress
        sharedBufferLength = bytes.count
        texture = sharedTexture
        textureUsesSharedStorage = true
        return true
#endif
    }

    func submit(
        generation: UInt64,
        uploadedBytes: Int,
        onPresented: @escaping GuestDisplayPresentedHandler
    ) {
        let accumulatedBytes = uploadedBytes + (pendingPresentation?.uploadedBytes ?? 0)
        pendingPresentation = (generation, accumulatedBytes, onPresented)
        requestDraw()
    }

    func reset() {
        texture = nil
        sharedBuffer = nil
        sharedBufferAddress = nil
        sharedBufferLength = 0
        textureUsesSharedStorage = false
        pendingPresentation = nil
    }

    func requestDraw() {
        guard pendingPresentation != nil else { return }
        view.setNeedsDisplay()
        DispatchQueue.main.async { [weak self] in
            guard let self, self.pendingPresentation != nil else { return }
            self.view.draw()
        }
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let texture,
              let descriptor = view.currentRenderPassDescriptor,
              let drawable = view.currentDrawable,
              let commandBuffer = commandQueue.makeCommandBuffer(),
              let encoder = commandBuffer.makeRenderCommandEncoder(descriptor: descriptor) else {
            return
        }

        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentTexture(texture, index: 0)
        encoder.drawPrimitives(type: .triangleStrip, vertexStart: 0, vertexCount: 4)
        encoder.endEncoding()
        commandBuffer.present(drawable)
        let completedPresentation = pendingPresentation
        pendingPresentation = nil
        if let completedPresentation {
            commandBuffer.addCompletedHandler { _ in
                let completedAt = DispatchTime.now().uptimeNanoseconds
                DispatchQueue.main.async {
                    completedPresentation.handler(
                        completedPresentation.generation,
                        completedPresentation.uploadedBytes,
                        completedAt
                    )
                }
            }
        }
        commandBuffer.commit()
    }

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
