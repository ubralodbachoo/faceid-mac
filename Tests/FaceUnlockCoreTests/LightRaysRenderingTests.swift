import Metal
import XCTest
@testable import FaceUnlockApp

final class LightRaysRenderingTests: XCTestCase {
    @MainActor
    func testNativeShaderRendersIntroRaysAndClickPulse() throws {
        guard ProcessInfo.processInfo.environment["FACEUNLOCK_TEST_LIGHT_RAYS"] == "1" else {
            throw XCTSkip("Native Metal rendering is opt-in")
        }
        let device = try XCTUnwrap(MTLCreateSystemDefaultDevice())
        let pipeline = try LightRaysRenderer.makePipeline(device: device)
        let queue = try XCTUnwrap(device.makeCommandQueue())
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .bgra8Unorm, width: 64, height: 64, mipmapped: false)
        descriptor.usage = .renderTarget
        descriptor.storageMode = .shared
        let texture = try XCTUnwrap(device.makeTexture(descriptor: descriptor))

        func render(opening: Float, pulseAge: Float = -1) throws -> [UInt8] {
            let pass = MTLRenderPassDescriptor()
            pass.colorAttachments[0].texture = texture
            pass.colorAttachments[0].loadAction = .clear
            pass.colorAttachments[0].storeAction = .store
            let command = try XCTUnwrap(queue.makeCommandBuffer())
            let encoder = try XCTUnwrap(command.makeRenderCommandEncoder(descriptor: pass))
            let uniforms: [SIMD4<Float>] = [SIMD4(760, 740, 1, opening), SIMD4(0.5, 0.5, 0, 0),
                SIMD4(pulseAge, -1, -1, -1), SIMD4(0.5, 3, 0.35, 1), SIMD4(0.6, 0.25, 1, 1), SIMD4(1, 1, 0.1, 1)]
            encoder.setRenderPipelineState(pipeline)
            uniforms.withUnsafeBytes { encoder.setFragmentBytes($0.baseAddress!, length: $0.count, index: 0) }
            encoder.drawPrimitives(type: .triangle, vertexStart: 0, vertexCount: 3)
            encoder.endEncoding()
            command.commit(); command.waitUntilCompleted()
            XCTAssertNil(command.error)
            var pixels = [UInt8](repeating: 0, count: 64 * 64 * 4)
            texture.getBytes(&pixels, bytesPerRow: 64 * 4, from: MTLRegionMake2D(0, 0, 64, 64), mipmapLevel: 0)
            return stride(from: 0, to: pixels.count, by: 4).map { pixels[$0] }
        }
        let intro = try render(opening: 0)
        let rays = try render(opening: 2)
        let pulsed = try render(opening: 2, pulseAge: 0.4)
        XCTAssertEqual(intro.max(), 0)
        XCTAssertGreaterThan(Int(rays.max()!) - Int(rays.min()!), 40, "Actual light shafts must render rather than a flat fallback")
        XCTAssertNotEqual(rays, pulsed, "The click pulse must reach the rendered light")
    }
}
