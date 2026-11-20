import AppKit
import Combine
import MetalKit
import SwiftUI

/// Native rendering of the requested top-center, white LightRays treatment.
/// Pointer observation is local to this window; clicks pass through unchanged.
struct LightRaysBackground: NSViewRepresentable {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.appAnimationsEnabled) private var animations

    func makeNSView(context: Context) -> LightRaysView {
        let view = LightRaysView()
        view.configure(reduceMotion: reduceMotion || !animations)
        return view
    }

    func updateNSView(_ view: LightRaysView, context: Context) { view.configure(reduceMotion: reduceMotion || !animations) }
    static func dismantleNSView(_ view: LightRaysView, coordinator: ()) { view.stop() }
}

@MainActor
final class LightRaysView: MTKView {
    private var renderer: LightRaysRenderer?
    private var observations: Set<AnyCancellable> = []
    private var clickMonitor: Any?
    private var reduceMotion = false

    init() {
        super.init(frame: .zero, device: MTLCreateSystemDefaultDevice())
        colorPixelFormat = .bgra8Unorm
        clearColor = MTLClearColor(red: 0, green: 0, blue: 0, alpha: 1)
        autoResizeDrawable = false
        preferredFramesPerSecond = 60
        enableSetNeedsDisplay = true
        isPaused = true
        setAccessibilityElement(false)
        if let device {
            do {
                let renderer = try LightRaysRenderer(device: device)
                self.renderer = renderer
                delegate = renderer
            } catch { NSLog("Light-rays rendering unavailable: %@", error.localizedDescription) }
        }
    }

    required init(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }
    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    override func layout() {
        super.layout()
        // Soft light needs no Retina-sized render target. Keep a bounded pixel budget.
        let ratio = min(1, sqrt(750_000 / max(1, bounds.width * bounds.height)))
        drawableSize = CGSize(width: max(1, bounds.width * ratio), height: max(1, bounds.height * ratio))
    }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        stop()
        guard let window else { return }
        let center = NotificationCenter.default
        for name in [NSWindow.didChangeOcclusionStateNotification, NSWindow.didMiniaturizeNotification,
                     NSWindow.didDeminiaturizeNotification, NSWindow.didBecomeKeyNotification,
                     NSWindow.didResignKeyNotification] {
            center.publisher(for: name, object: window).sink { [weak self] _ in self?.updatePlayback() }.store(in: &observations)
        }
        for name in [NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification,
                     NSApplication.didHideNotification, NSApplication.didUnhideNotification] {
            center.publisher(for: name).sink { [weak self] _ in self?.updatePlayback() }.store(in: &observations)
        }
        center.publisher(for: NSWindow.willCloseNotification, object: window)
            .sink { [weak self] _ in
                self?.isPaused = true
                self?.renderer?.resetFrameClock()
            }.store(in: &observations)
        clickMonitor = NSEvent.addLocalMonitorForEvents(matching: .leftMouseDown) { [weak self] event in
            MainActor.assumeIsolated {
                if let self, !self.reduceMotion, event.window === self.window,
                   self.bounds.contains(self.convert(event.locationInWindow, from: nil)) {
                    self.renderer?.pulse()
                }
            }
            return event
        }
        updatePlayback()
    }

    func configure(reduceMotion: Bool) {
        self.reduceMotion = reduceMotion
        renderer?.reduceMotion = reduceMotion
        updatePlayback()
    }

    private func updatePlayback() {
        let visible = window.map { $0.isVisible && !$0.isMiniaturized && $0.occlusionState.contains(.visible) } ?? false
        isPaused = reduceMotion || !visible || !NSApp.isActive
        renderer?.resetFrameClock()
        if visible { setNeedsDisplay(bounds) }
    }

    func stop() {
        isPaused = true
        observations.removeAll()
        if let clickMonitor { NSEvent.removeMonitor(clickMonitor); self.clickMonitor = nil }
        renderer?.resetFrameClock()
    }
}

@MainActor
final class LightRaysRenderer: NSObject, MTKViewDelegate {
    var reduceMotion = false
    private let pipeline: any MTLRenderPipelineState
    private let queue: any MTLCommandQueue
    private var time: Float = 0
    private var lastFrame: TimeInterval?
    private var aim = SIMD2<Float>(0.5, 0.5)
    private var shadow: Float = 0
    private var pulses: [Float] = []

    init(device: any MTLDevice) throws {
        pipeline = try Self.makePipeline(device: device)
        guard let queue = device.makeCommandQueue() else { throw RenderingError.unavailable }
        self.queue = queue
        super.init()
    }

    static func makePipeline(device: any MTLDevice) throws -> any MTLRenderPipelineState {
        let library = try device.makeLibrary(source: shaderSource, options: nil)
        let descriptor = MTLRenderPipelineDescriptor()
        descriptor.vertexFunction = library.makeFunction(name: "raysVertex")
        descriptor.fragmentFunction = library.makeFunction(name: "raysFragment")
        descriptor.colorAttachments[0].pixelFormat = .bgra8Unorm
        return try device.makeRenderPipelineState(descriptor: descriptor)
    }

    func resetFrameClock() { lastFrame = nil }
    func pulse() { pulses.append(time); pulses = Array(pulses.suffix(4)) }
    func mtkView(_ view: MTKView, drawableSizeWillChange size: CGSize) {}

    func draw(in view: MTKView) {
        guard view.bounds.width > 0, view.bounds.height > 0,
              let drawable = view.currentDrawable, let pass = view.currentRenderPassDescriptor,
              let command = queue.makeCommandBuffer(), let encoder = command.makeRenderCommandEncoder(descriptor: pass) else { return }
        let now = ProcessInfo.processInfo.systemUptime
        let dt = Float(min(0.05, max(0, lastFrame.map { now - $0 } ?? 0)))
        lastFrame = now
        if !reduceMotion { time += dt }
        let point = view.convert(view.window?.mouseLocationOutsideOfEventStream ?? .zero, from: nil)
        let inside = view.bounds.contains(point) && view.window?.isKeyWindow == true && !reduceMotion
        let target = inside ? SIMD2<Float>(Float(point.x / view.bounds.width), Float(1 - point.y / view.bounds.height)) : SIMD2<Float>(0.5, 0.5)
        aim += (target - aim) * (1 - exp(-dt / 0.2))
        shadow += ((inside ? 1 : 0) - shadow) * (1 - exp(-dt / 0.25))
        pulses.removeAll { time - $0 > 2 }
        var ages = SIMD4<Float>(repeating: -1)
        for (index, born) in pulses.enumerated() { ages[index] = time - born }
        let uniforms: [SIMD4<Float>] = [
            SIMD4(Float(view.bounds.width), Float(view.bounds.height), reduceMotion ? 1 : time, reduceMotion ? 2 : time),
            SIMD4(aim.x, aim.y, reduceMotion ? 0 : shadow, 0), ages,
            SIMD4(0.5, 3, 0.35, 1), // spread, length, sharpness, density
            SIMD4(0.6, 0.25, 1, 1), // glow, haze, atmosphere, intensity
            SIMD4(1, 1, 0.1, 1)    // fade, saturation, mouse influence, speed
        ]
        encoder.setRenderPipelineState(pipeline)
        uniforms.withUnsafeBytes { bytes in
            encoder.setFragmentBytes(bytes.baseAddress!, length: bytes.count, index: 0)
        }
        encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
        encoder.endEncoding()
        command.present(drawable)
        command.commit()
    }

    private enum RenderingError: Error { case unavailable }

    // Procedural Metal light: no web view, image assets, camera input or external runtime.
    static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;
    struct RayVertex { float4 position [[position]]; float2 uv; };
    vertex RayVertex raysVertex(uint index [[vertex_id]]) {
        const float2 corners[] = { float2(-1,-1), float2(3,-1), float2(-1,3) };
        float2 p = corners[index];
        return { float4(p, 0, 1), float2((p.x + 1) * 0.5, (1 - p.y) * 0.5) };
    }
    fragment float4 raysFragment(RayVertex v [[stage_in]], constant float4 *u [[buffer(0)]]) {
        float2 size = max(u[0].xy, float2(1));
        float2 origin = float2(size.x * 0.5, -size.y * 0.2);
        float2 delta = v.uv * size - origin;
        float reach = max(size.x, size.y);
        float distance = max(length(delta), 0.001);
        float depth = distance / reach;
        float2 direction = delta / distance;
        float2 cursor = u[1].xy * size;
        float2 aim = normalize(mix(float2(0, 1), normalize(cursor - origin), u[5].z));
        float angle = atan2(direction.x, direction.y) - atan2(aim.x, aim.y);
        float t = u[0].z * u[5].w;
        float light = 0;
        for (int i = 0; i < 13; ++i) {
            float n = float(i);
            float center = (n - 6) * 0.13 / u[3].w + sin(t * 0.12 + n * 1.71) * 0.045;
            float width = mix(0.062, 0.024, u[3].z) * (0.8 + 0.25 * sin(n * 2.17));
            float offset = (angle - center) / width;
            float shaft = exp(-offset * offset * 0.5);
            float drift = 0.72 + 0.28 * sin(t * 0.45 + n * 2.4 + depth * 0.8);
            light += shaft * drift * (0.32 + 0.18 * cos(n * 1.3));
        }
        float cone = pow(max(dot(direction, aim), 0.0), 1.0 / u[3].x);
        float attenuation = max(0.0, 1.0 - depth / u[3].y) * clamp(1.0 - depth / u[5].x, 0.5, 1.0);
        float haze = 0.55 + 0.22 * sin(angle * 9 + t * 0.09) + 0.17 * cos(depth * 6 - t * 0.13);
        light *= mix(1.0, haze, u[4].y) * cone * attenuation;
        // The cursor occludes light only downstream from its position.
        float2 toCursor = cursor - origin;
        float cursorDistance = max(length(toCursor), 0.001);
        float along = dot(delta, toCursor) / (cursorDistance * cursorDistance);
        float side = abs(delta.x * toCursor.y - delta.y * toCursor.x) / cursorDistance;
        float trail = max(along - 1.0, 0.0);
        float shadowWidth = 16 * max(along, 0.0) + trail * cursorDistance * 0.2;
        float shade = (1 - smoothstep(shadowWidth * 0.3, shadowWidth * 1.6 + 0.01, side))
                      * smoothstep(1.0, 1.3, along) * exp(-trail);
        light *= 1 - u[1].z * shade * 0.62;
        float boost = 0;
        for (int i = 0; i < 4; ++i) {
            float age = u[2][i];
            if (age >= 0) {
                float wave = (depth - 0.05 - age * 1.05) / (0.14 + age * 0.14);
                boost += exp(-wave * wave) * smoothstep(0.0, 0.15, age) * (1 - smoothstep(0.0, 2.0, age)) * 0.9;
            }
        }
        float glow = u[4].x * (exp(-depth * depth * 9) * 0.9 + exp(-depth * 3.2) * 0.25);
        float opening = clamp(u[0].w / 1.8, 0.0, 1.0);
        float reveal = 1 - pow(1 - opening, 3.0);
        float front = 1 - smoothstep(reveal * 2.6 - 0.35, reveal * 2.6, depth);
        float energy = (light * (1 + boost) + glow) * u[4].w * reveal * front;
        float level = 1 - exp(-energy);
        float3 tint = mix(float3(1), float3(0.88, 0.94, 1), clamp(depth * 0.2, 0.0, 0.25) * u[4].z);
        float gray = dot(tint, float3(0.299, 0.587, 0.114));
        tint = mix(float3(gray), tint, u[5].y);
        return float4(tint * level, 1);
    }
    """
}
