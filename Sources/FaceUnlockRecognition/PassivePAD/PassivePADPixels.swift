import CoreGraphics
import CoreML
import Foundation

/// Reproduces the upstream inclusive, edge-shifted crops. No alignment or /255 normalization.
enum PassivePADPixels {
    static func crop(width: Int, height: Int, face: CGRect, scale requestedScale: Double) throws -> CGRect {
        guard width > 1, height > 1, requestedScale.isFinite, requestedScale > 0,
              [face.minX, face.minY, face.width, face.height].allSatisfy(\.isFinite),
              face.minX >= 0, face.minY >= 0, face.maxX <= Double(width), face.maxY <= Double(height),
              face.width >= 1, face.height >= 1 else { throw RecognitionError.passivePADContract }
        let x = Double(Int(face.minX)), y = Double(Int(face.minY))
        let w = Double(Int(face.width)), h = Double(Int(face.height))
        let scale = min(Double(height - 1) / h, Double(width - 1) / w, requestedScale)
        let centerX = x + w / 2, centerY = y + h / 2
        var left = centerX - w * scale / 2, top = centerY - h * scale / 2
        var right = centerX + w * scale / 2, bottom = centerY + h * scale / 2
        if left < 0 { right -= left; left = 0 }
        if top < 0 { bottom -= top; top = 0 }
        if right > Double(width - 1) { left -= right - Double(width - 1); right = Double(width - 1) }
        if bottom > Double(height - 1) { top -= bottom - Double(height - 1); bottom = Double(height - 1) }
        return CGRect(x: Int(left), y: Int(top), width: Int(right) - Int(left) + 1, height: Int(bottom) - Int(top) + 1)
    }

    static func tensor(image: CGImage, face: CGRect, scale: Double) throws -> MLMultiArray {
        let box = try crop(width: image.width, height: image.height, face: face, scale: scale)
        guard let crop = image.cropping(to: box) else { throw RecognitionError.passivePADContract }
        let width = crop.width, height = crop.height
        var bytes = [UInt8](repeating: 0, count: width * height * 4)
        let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
            guard let colorSpace = CGColorSpace(name: CGColorSpace.sRGB),
                  let context = CGContext(data: buffer.baseAddress, width: width, height: height,
                    bitsPerComponent: 8, bytesPerRow: width * 4, space: colorSpace,
                    bitmapInfo: CGBitmapInfo.byteOrder32Big.rawValue | CGImageAlphaInfo.premultipliedLast.rawValue) else { return false }
            context.draw(crop, in: CGRect(x: 0, y: 0, width: width, height: height))
            return true
        }
        guard rendered else { throw RecognitionError.passivePADContract }
        let result = try MLMultiArray(shape: [1, 3, 80, 80], dataType: .float32)
        let output = result.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<80 {
            let sy = max(0, (Double(y) + 0.5) * Double(height) / 80 - 0.5)
            let y0 = min(Int(sy), height - 1), y1 = min(y0 + 1, height - 1)
            let wy = sy - Double(y0)
            for x in 0..<80 {
                let sx = max(0, (Double(x) + 0.5) * Double(width) / 80 - 0.5)
                let x0 = min(Int(sx), width - 1), x1 = min(x0 + 1, width - 1)
                let wx = sx - Double(x0)
                for channel in 0..<3 {
                    let offset = 2 - channel // RGBA decode -> planar BGR.
                    let a = Double(bytes[(y0 * width + x0) * 4 + offset])
                    let b = Double(bytes[(y0 * width + x1) * 4 + offset])
                    let c = Double(bytes[(y1 * width + x0) * 4 + offset])
                    let d = Double(bytes[(y1 * width + x1) * 4 + offset])
                    output[channel * 6_400 + y * 80 + x] = Float(((a * (1-wx) + b * wx) * (1-wy) +
                        (c * (1-wx) + d * wx) * wy).rounded())
                }
            }
        }
        return result
    }

    static func synthetic(seed: Int) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: [1, 3, 80, 80], dataType: .float32)
        let values = result.dataPointer.assumingMemoryBound(to: Float.self)
        for y in 0..<80 {
            for x in 0..<80 {
                let i = y * 80 + x
                values[i] = Float((x * 53 + y * 7 + seed * 47) % 256)
                values[6_400 + i] = Float((x * 11 + y * 43 + seed * 29) % 256)
                values[12_800 + i] = Float((x * 37 + y * 17 + seed * 13) % 256)
            }
        }
        return result
    }
}
