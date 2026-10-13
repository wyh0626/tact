import MetalKit
import SwiftUI

/// The art behind onboarding and the status banner: a sphere drawn in one ink
/// colour with an 8×8 ordered (Bayer) dither, lit by a light that slowly
/// circles it, over a faint dot grid. One colour and visible pixels instead of
/// glowing gradients. The shader is compiled from source at runtime, so
/// building the app needs no Metal toolchain.
/// Where the sphere sits: its centre as a fraction of the panel (0,0 top
/// left) and its radius as a fraction of the panel's shorter side.
struct DitherLayout {
    var centerX: Float
    var centerY: Float
    var radius: Float

    static let hero = DitherLayout(centerX: 1.0, centerY: 0.62, radius: 0.62)
}

/// Compiles the shader once; each view draws through its own `DitherDrawer`.
@MainActor
final class DitherRenderer {
    static let shared = DitherRenderer(shaderSource: source)

    let device: MTLDevice
    private let queue: MTLCommandQueue
    private let pipeline: MTLRenderPipelineState
    private let started = CACurrentMediaTime()
    static let pixelFormat = MTLPixelFormat.bgra8Unorm

    private init?(shaderSource: String) {
        guard let device = MTLCreateSystemDefaultDevice(), let queue = device.makeCommandQueue() else { return nil }
        do {
            let library = try device.makeLibrary(source: shaderSource, options: nil)
            let descriptor = MTLRenderPipelineDescriptor()
            descriptor.vertexFunction = library.makeFunction(name: "art_vertex")
            descriptor.fragmentFunction = library.makeFunction(name: "art_fragment")
            descriptor.colorAttachments[0].pixelFormat = Self.pixelFormat
            pipeline = try device.makeRenderPipelineState(descriptor: descriptor)
        } catch {
            Log.info("⚠️ 着色器编译失败，改用纯色背景：\(error.localizedDescription)")
            return nil
        }
        self.device = device
        self.queue = queue
    }

    var elapsed: Float { Float(CACurrentMediaTime() - started) }

    func makeCommandBuffer() -> MTLCommandBuffer? { queue.makeCommandBuffer() }

    /// `cell` is the size of one dither pixel in drawable pixels.
    func encode(into buffer: MTLCommandBuffer, pass: MTLRenderPassDescriptor, size: CGSize, time: Float, cell: Float,
                layout: DitherLayout) {
        guard let encoder = buffer.makeRenderCommandEncoder(descriptor: pass) else { return }
        var params = SIMD4<Float>(time, Float(size.width), Float(size.height), cell)
        var shape = SIMD4<Float>(layout.centerX, layout.centerY, layout.radius, 0)
        encoder.setRenderPipelineState(pipeline)
        encoder.setFragmentBytes(&params, length: MemoryLayout<SIMD4<Float>>.stride, index: 0)
        encoder.setFragmentBytes(&shape, length: MemoryLayout<SIMD4<Float>>.stride, index: 1)
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
    }

    /// One frame as an image, for places that cannot host a live Metal view.
    func image(width: Int, height: Int, time: Float, cell: Float, layout: DitherLayout) -> CGImage? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: Self.pixelFormat, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = [.renderTarget, .shaderRead]
        descriptor.storageMode = .shared
        guard let texture = device.makeTexture(descriptor: descriptor), let buffer = queue.makeCommandBuffer() else { return nil }
        let pass = MTLRenderPassDescriptor()
        pass.colorAttachments[0].texture = texture
        pass.colorAttachments[0].loadAction = .clear
        pass.colorAttachments[0].storeAction = .store
        encode(into: buffer, pass: pass, size: CGSize(width: width, height: height), time: time, cell: cell, layout: layout)
        buffer.commit()
        buffer.waitUntilCompleted()

        let bytesPerRow = width * 4
        var pixels = [UInt8](repeating: 0, count: bytesPerRow * height)
        texture.getBytes(&pixels, bytesPerRow: bytesPerRow, from: MTLRegionMake2D(0, 0, width, height), mipmapLevel: 0)
        guard let provider = CGDataProvider(data: Data(pixels) as CFData) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: bytesPerRow,
                       space: CGColorSpaceCreateDeviceRGB(),
                       bitmapInfo: CGBitmapInfo(rawValue: CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.noneSkipFirst.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }

    private static let source = """
    #include <metal_stdlib>
    using namespace metal;

    struct VOut { float4 position [[position]]; };

    vertex VOut art_vertex(uint vid [[vertex_id]]) {
        float2 p = float2((vid << 1) & 2, vid & 2);
        VOut out;
        out.position = float4(p * 2.0 - 1.0, 0.0, 1.0);
        return out;
    }

    // Classic 8x8 Bayer threshold, from bit-interleaving x^y and x.
    static float bayer8(uint2 p) {
        uint x = p.x & 7u;
        uint y = p.y & 7u;
        uint xy = x ^ y;
        uint v = ((xy & 1u) << 5) | ((x & 1u) << 4) | ((xy & 2u) << 2)
               | ((x & 2u) << 1) | ((xy & 4u) >> 1) | ((x & 4u) >> 2);
        return (float(v) + 0.5) / 64.0;
    }

    // params: x time, yz drawable size in pixels, w dither pixel size in pixels.
    // shape: xy sphere centre (fraction of the panel), z radius (fraction of the shorter side).
    fragment float4 art_fragment(VOut in [[stage_in]], constant float4 &params [[buffer(0)]],
                                 constant float4 &shape [[buffer(1)]]) {
        const float3 paper = float3(0.051, 0.051, 0.055);
        const float3 ink = float3(0.247, 0.420, 1.000);
        const float3 grid = float3(0.16, 0.16, 0.17);

        float cell = max(params.w, 1.0);
        uint2 cellIndex = uint2(in.position.xy / cell);
        float2 centre = (float2(cellIndex) + 0.5) * cell;
        float2 size = params.yz;
        float2 uv = centre / size;                          // 0,0 top-left
        float aspect = size.x / max(size.y, 1.0);

        float radius = shape.z * min(aspect, 1.0);          // in units of the panel height
        float2 p = float2((uv.x - shape.x) * aspect, uv.y - shape.y) / radius;
        float r2 = dot(p, p);
        float t = params.x * 0.18;
        float3 light = normalize(float3(cos(t) * 0.8, -0.55 + 0.25 * sin(t * 0.7), 0.65));
        float value = 0.0;
        if (r2 < 1.0) {
            float3 normal = float3(p, sqrt(1.0 - r2));
            float diffuse = max(dot(normal, light), 0.0);
            float rim = pow(1.0 - normal.z, 3.0) * 0.25;
            value = 0.03 + 0.8 * pow(diffuse, 1.6) + rim;
        }
        if (value > bayer8(cellIndex)) { return float4(ink, 1.0); }

        // A faint dot grid on the rest of the panel.
        uint2 gridIndex = cellIndex % uint2(8u);
        if (gridIndex.x == 0u && gridIndex.y == 0u) { return float4(grid, 1.0); }
        return float4(paper, 1.0);
    }
    """
}

/// The live art, or a still frame where a Metal view cannot be drawn
/// (rendering windows to images), or plain black when Metal is unavailable.
struct DitherArtView: View {
    @MainActor static var renderStill = false
    var layout = DitherLayout.hero
    var stillTime: Float = 6
    /// Dither pixel size in points for still frames; the live view uses 2.
    var pixelSize: CGFloat = 2
    var isActive = true

    var body: some View {
        GeometryReader { geo in
            if let renderer = DitherRenderer.shared {
                if DitherArtView.renderStill {
                    let scale: CGFloat = 2
                    if let image = renderer.image(width: max(1, Int(geo.size.width * scale)),
                                                  height: max(1, Int(geo.size.height * scale)),
                                                  time: stillTime, cell: Float(pixelSize * scale), layout: layout) {
                        Image(decorative: image, scale: scale).resizable().interpolation(.none)
                    }
                } else {
                    DitherMetalView(renderer: renderer, layout: layout, isActive: isActive)
                }
            } else {
                Color(red: 0.051, green: 0.051, blue: 0.055)
            }
        }
    }
}

private struct DitherMetalView: NSViewRepresentable {
    let renderer: DitherRenderer
    let layout: DitherLayout
    let isActive: Bool

    func makeCoordinator() -> DitherDrawer { DitherDrawer(renderer: renderer, layout: layout) }

    func makeNSView(context: Context) -> DitherMTKView {
        let view = DitherMTKView(frame: .zero, device: renderer.device)
        view.colorPixelFormat = DitherRenderer.pixelFormat
        view.framebufferOnly = true
        view.preferredFramesPerSecond = 24
        view.delegate = context.coordinator
        view.layer?.isOpaque = true
        view.animationEnabled = isActive
        return view
    }

    func updateNSView(_ view: DitherMTKView, context: Context) {
        context.coordinator.layout = layout
        view.animationEnabled = isActive
    }

    static func dismantleNSView(_ view: DitherMTKView, coordinator: DitherDrawer) {
        view.isPaused = true
        view.delegate = nil
    }
}

/// Cached pages are detached from the window while another tab is shown.
/// Stop their display loop, including when the settings window is closed.
@MainActor
final class DitherMTKView: MTKView {
    var animationEnabled = true { didSet { updateAnimation() } }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        updateAnimation()
    }

    override func viewDidHide() {
        super.viewDidHide()
        updateAnimation()
    }

    override func viewDidUnhide() {
        super.viewDidUnhide()
        updateAnimation()
    }

    private func updateAnimation() {
        isPaused = !animationEnabled || window == nil || isHiddenOrHasHiddenAncestor
    }
}

/// Draws one live view; holds that view's layout.
@MainActor
final class DitherDrawer: NSObject, MTKViewDelegate {
    let renderer: DitherRenderer
    var layout: DitherLayout

    init(renderer: DitherRenderer, layout: DitherLayout) {
        self.renderer = renderer
        self.layout = layout
    }

    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard let pass = view.currentRenderPassDescriptor, let drawable = view.currentDrawable,
              let buffer = renderer.makeCommandBuffer() else { return }
        let cell = Float(2 * (view.window?.backingScaleFactor ?? 2))
        renderer.encode(into: buffer, pass: pass, size: view.drawableSize, time: renderer.elapsed, cell: cell, layout: layout)
        buffer.present(drawable)
        buffer.commit()
    }
}
