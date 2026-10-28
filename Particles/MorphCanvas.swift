import MetalKit
import SwiftUI
import simd

/// Mirrors `MorphUniforms` in `MorphShaders.metal` (size 40, alignment 8).
nonisolated struct MorphUniforms {
    var viewport: SIMD2<Float>
    var origin: SIMD2<Float>
    var side: Float
    var progress: Float
    var time: Float
    var pointSize: Float
    var scale: Float
    var fade: Float
    var spread: Float
    var swirl: Float
    var wander: Float
}

/// One leg of the cycle. The token is what tells the canvas a fresh tap has
/// happened, rather than the same pair coming round again.
struct MorphStep: Equatable {
    var from: Int
    var to: Int
    var token: Int
}

/// Breaks one picture into its motes and gathers them into the next.
///
/// Subclassing `MTKView` and overriding `draw(_:)` keeps the whole render loop
/// on the main actor, which `MTKViewDelegate` would not. The canvas idles
/// paused and blank — the real pictures are SwiftUI's job, and this only takes
/// over for the flight between them.
final class MorphCanvasView: MTKView {
    /// How much of the morph the pictures hand over on. The motes are solid by
    /// `handoverIn`, so the first picture can leave underneath them, and the
    /// second one is back by `handoverOut`, before they start to go. Neither
    /// pair ever fades at the same time, which is what keeps the picture from
    /// blinking at either end.
    static let handoverIn = 0.07
    static let handoverOut = 0.90

    private var pipeline: MTLRenderPipelineState?
    private var queue: MTLCommandQueue?
    private var swarms: [MTLBuffer] = []
    private var count = 0
    private var pitch: Float = 0

    private var from = 0
    private var to = 0
    private var startTime: CFTimeInterval?

    /// Every knob on the screen, read fresh on each frame.
    var settings = MorphSettings()
    /// The square the pictures are drawn in, in this view's coordinates.
    var box: CGRect = .zero
    /// Called once the swarm has settled and the canvas has gone blank again.
    var onSettle: (() -> Void)?

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        configure()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }

    func load(_ shapes: [MorphShape]) {
        guard let device, let first = shapes.first, !first.points.isEmpty else { return }

        count = first.points.count
        pitch = first.pitch
        swarms = shapes.compactMap { shape in
            device.makeBuffer(
                bytes: shape.points,
                length: MemoryLayout<MorphPoint>.stride * shape.points.count,
                options: .storageModeShared
            )
        }
    }

    func morph(from source: Int, to destination: Int) {
        guard swarms.indices.contains(source), swarms.indices.contains(destination) else { return }
        from = source
        to = destination
        startTime = CACurrentMediaTime()
        isPaused = false
    }

    // MARK: - Setup

    private func configure() {
        // Transparent: the white screen and the picture itself sit behind it.
        isOpaque = false
        backgroundColor = .clear
        layer.isOpaque = false
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 0)
        colorPixelFormat = .bgra8Unorm
        framebufferOnly = true
        enableSetNeedsDisplay = false
        isPaused = true
        preferredFramesPerSecond = 120
        isUserInteractionEnabled = false

        guard let device,
              let library = device.makeDefaultLibrary(),
              let commandQueue = device.makeCommandQueue()
        else { return }

        queue = commandQueue

        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "morph_vertex")
        descriptor.fragmentFunction = library.makeFunction(name: "morph_fragment")
        descriptor.colorAttachments[0].pixelFormat = colorPixelFormat
        descriptor.colorAttachments[0].isBlendingEnabled = true
        descriptor.colorAttachments[0].rgbBlendOperation = .add
        descriptor.colorAttachments[0].alphaBlendOperation = .add
        descriptor.colorAttachments[0].sourceRGBBlendFactor = .one
        descriptor.colorAttachments[0].sourceAlphaBlendFactor = .one
        descriptor.colorAttachments[0].destinationRGBBlendFactor = .oneMinusSourceAlpha
        descriptor.colorAttachments[0].destinationAlphaBlendFactor = .oneMinusSourceAlpha

        pipeline = try? device.makeRenderPipelineState(descriptor: descriptor)
    }

    // MARK: - Drawing

    override func draw(_ rect: CGRect) {
        guard let queue,
              let descriptor = currentRenderPassDescriptor,
              let drawable = currentDrawable,
              let commands = queue.makeCommandBuffer(),
              let encoder = commands.makeRenderCommandEncoder(descriptor: descriptor)
        else { return }

        var settled = false

        if let pipeline,
           let startTime,
           count > 0,
           box.width > 0,
           bounds.width > 0,
           swarms.indices.contains(from),
           swarms.indices.contains(to) {
            let elapsed = CACurrentMediaTime() - startTime
            let progress = settings.progress(after: elapsed)
            settled = elapsed >= settings.duration

            var uniforms = MorphUniforms(
                viewport: SIMD2(Float(bounds.width), Float(bounds.height)),
                origin: SIMD2(Float(box.minX), Float(box.minY)),
                side: Float(box.width),
                progress: Float(progress),
                time: Float(elapsed),
                // Measured in lattice cells: just over one and the motes
                // close up into a picture at rest, under one and they stay
                // separate grains.
                pointSize: Float(box.width) * pitch * Float(settings.pointSize),
                scale: Float(drawableSize.width / bounds.width),
                fade: Float(handover(at: progress)),
                spread: Float(settings.spread),
                swirl: Float(settings.swirl),
                wander: Float(settings.wander)
            )

            encoder.setRenderPipelineState(pipeline)
            encoder.setVertexBuffer(swarms[from], offset: 0, index: 0)
            encoder.setVertexBuffer(swarms[to], offset: 0, index: 1)
            encoder.setVertexBytes(&uniforms, length: MemoryLayout<MorphUniforms>.stride, index: 2)
            encoder.drawPrimitives(type: .point, vertexStart: 0, vertexCount: count)
        }

        encoder.endEncoding()
        commands.present(drawable)
        commands.commit()

        // The last frame is the empty one, so pausing on it leaves the canvas
        // blank and the real picture alone underneath.
        if settled {
            self.startTime = nil
            isPaused = true
            onSettle?()
        }
    }

    /// How solid the motes are: they come up as the first picture goes and
    /// bow out as the second one arrives.
    private func handover(at progress: Double) -> Double {
        let rise = smoothstep(0, Self.handoverIn, progress)
        let fall = smoothstep(Self.handoverOut, 1, progress)
        return rise * (1 - fall)
    }

    private func smoothstep(_ edge0: Double, _ edge1: Double, _ x: Double) -> Double {
        let t = min(max((x - edge0) / (edge1 - edge0), 0), 1)
        return t * t * (3 - 2 * t)
    }
}

struct MorphCanvas: UIViewRepresentable {
    var shapes: [MorphShape]
    /// Bumped whenever the pictures have been cut up again, so the canvas
    /// knows to take the new swarm rather than keep the one it has.
    var shapesToken: Int
    var step: MorphStep?
    var box: CGRect
    var settings: MorphSettings
    var onSettle: () -> Void

    func makeUIView(context: Context) -> MorphCanvasView {
        let view = MorphCanvasView()
        apply(to: view, coordinator: context.coordinator)
        return view
    }

    func updateUIView(_ uiView: MorphCanvasView, context: Context) {
        apply(to: uiView, coordinator: context.coordinator)
    }

    func makeCoordinator() -> Coordinator { Coordinator() }

    private func apply(to view: MorphCanvasView, coordinator: Coordinator) {
        view.box = box
        view.settings = settings
        view.onSettle = onSettle

        if !shapes.isEmpty, coordinator.loaded != shapesToken {
            view.load(shapes)
            coordinator.loaded = shapesToken
        }

        if let step, step.token != coordinator.token, coordinator.loaded == shapesToken {
            coordinator.token = step.token
            view.morph(from: step.from, to: step.to)
        }
    }

    final class Coordinator {
        /// The `shapesToken` of the swarm the canvas is holding, or -1.
        var loaded = -1
        var token = 0
    }
}
