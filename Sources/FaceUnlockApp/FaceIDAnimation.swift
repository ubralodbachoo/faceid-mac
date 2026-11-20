import SwiftUI

/// Presentation stages follow observed unlock events, never a decorative success timer.
enum FaceIDAnimationStage: Equatable {
    case scanning, processing, unlocked, fallback

    init(_ phase: LockScreenPhase) {
        switch phase {
        case .waitingForPasswordField, .submitting, .awaitingDesktop: self = .processing
        case .unlocked: self = .unlocked
        case .fallback: self = .fallback
        default: self = .scanning
        }
    }
}

/// Time-based vector animation. The caller requests a 60 Hz timeline; motion remains
/// continuous when the compositor drops a frame or uses a different refresh rate.
struct FaceIDAnimationFrame: View {
    let stage: FaceIDAnimationStage
    let motionTime: TimeInterval
    let stageTime: TimeInterval
    var reduceMotion = false
    var accent = FaceIDAccent.green.color

    var body: some View {
        Canvas { context, size in
            let side = min(size.width, size.height)
            let center = CGPoint(x: size.width / 2, y: size.height / 2)
            let radius = side * 0.345
            let green = accent
            context.opacity = reduceMotion || stage == .fallback ? 1 : smooth(motionTime / 0.2)
            if stage != .unlocked {
                if stage == .fallback && !reduceMotion {
                    let t = max(0, stageTime)
                    let envelope = pow(1 - min(1, t / 0.65), 2)
                    context.translateBy(x: sin(t * .pi * 14) * side * 0.065 * envelope, y: 0)
                }
                let rejected = stage == .fallback
                let pulse = reduceMotion || rejected ? 0.65 : (1 - cos(max(0, motionTime) * .pi / 1.25)) / 2
                let blink = reduceMotion || rejected ? 0 : blinkClosure(at: motionTime)
                let sadness = rejected ? (reduceMotion ? 1 : smooth(stageTime / 0.18)) : 0
                context.opacity *= 0.78 + pulse * 0.22
                drawFace(in: &context, center: center, radius: radius, color: green,
                         blink: blink, sadness: sadness, glow: pulse)
                return
            }

            // A short success flourish starts only after desktop return is confirmed.
            let time = reduceMotion ? 1.8 : 1.8 + max(0, stageTime) * 7
            let settle = reduceMotion ? 1 : smooth((stageTime - 0.32) / 0.2)
            let handoff = reduceMotion ? 1 : smooth(stageTime / 0.12)
            if handoff < 1 {
                var faceContext = context
                faceContext.opacity *= 1 - handoff
                drawFace(in: &faceContext, center: center, radius: radius, color: green)
            }

            // A soft bloom stays inside the black notch; the crisp core remains legible.
            let halo = Path(ellipseIn: CGRect(x: center.x - radius * 1.4, y: center.y - radius * 1.4,
                                               width: radius * 2.8, height: radius * 2.8))
            context.fill(halo, with: .radialGradient(Gradient(colors: [green.opacity(0.045), green.opacity(0)]),
                center: center, startRadius: radius * 0.2, endRadius: radius * 1.4))

            let processing = reduceMotion ? 1 : smooth((stageTime - 0.18) / 0.14)
            for ring in 0..<2 {
                drawOrbit(in: &context, center: center, radius: radius, time: time,
                          ring: ring, settle: settle, processing: processing,
                          alpha: (1 - settle) * handoff, color: green)
            }

            if stage == .processing || stage == .unlocked {
                let rim = Path(ellipseIn: CGRect(x: center.x - radius, y: center.y - radius,
                                                width: radius * 2, height: radius * 2))
                glowStroke(rim, in: &context, color: green,
                           opacity: settle, width: side * 0.018)
            }
            if stage == .unlocked {
                let reveal = reduceMotion ? 1 : smooth((stageTime - 0.45) / 0.18)
                var check = Path()
                check.move(to: CGPoint(x: center.x - radius * 0.43, y: center.y + radius * 0.01))
                check.addLine(to: CGPoint(x: center.x - radius * 0.09, y: center.y + radius * 0.35))
                check.addLine(to: CGPoint(x: center.x + radius * 0.48, y: center.y - radius * 0.38))
                glowStroke(check.trimmedPath(from: 0, to: reveal), in: &context,
                           color: green, opacity: reveal, width: side * 0.025)
            }
        }
        .accessibilityHidden(true)
    }

    private func smooth(_ value: Double) -> Double {
        let t = min(1, max(0, value))
        return t * t * (3 - 2 * t)
    }

    private func blinkClosure(at time: Double) -> Double {
        // A quick close and softer reopening, with a long open-eyed pause.
        let t = max(0, time).truncatingRemainder(dividingBy: 2.8) - 0.85
        if t < 0 || t > 0.24 { return 0 }
        return t < 0.08 ? smooth(t / 0.08) : 1 - smooth((t - 0.08) / 0.16)
    }

    private func drawFace(in context: inout GraphicsContext, center: CGPoint, radius: Double,
                          color: Color, blink: Double = 0, sadness: Double = 0, glow: Double = 0.65) {
        func point(_ x: Double, _ y: Double) -> CGPoint {
            CGPoint(x: center.x + radius * x, y: center.y + radius * y)
        }
        var face = Path()
        for x in [-0.34, 0.34] {
            let halfHeight = 0.09 * (1 - blink)
            let halfWidth = 0.055 * blink
            face.move(to: point(x - halfWidth, -0.16 - halfHeight))
            face.addLine(to: point(x + halfWidth, -0.16 + halfHeight))
        }
        face.move(to: point(0.04, -0.23))
        face.addLine(to: point(0.04, 0.12))
        face.addQuadCurve(to: point(-0.11, 0.19), control: point(0.04, 0.22))
        let mouthEnds = 0.39 + sadness * 0.12
        face.move(to: point(-0.31, mouthEnds))
        face.addQuadCurve(to: point(0.31, mouthEnds), control: point(0, 0.68 - sadness * 0.6))
        if sadness > 0 {
            // Raised inner brows make rejection read as sadness rather than anger.
            var brows = Path()
            brows.move(to: point(-0.46, -0.36)); brows.addLine(to: point(-0.24, -0.48))
            brows.move(to: point(0.24, -0.48)); brows.addLine(to: point(0.46, -0.36))
            glowStroke(brows, in: &context, color: color, opacity: sadness, width: radius * 0.05)
        }
        for quadrant in 0..<4 {
            for sample in 0...32 {
                let corner = faceCorner(Double(sample) / 32, quadrant: quadrant)
                if sample == 0 { face.move(to: point(corner.0, corner.1)) }
                else { face.addLine(to: point(corner.0, corner.1)) }
            }
        }
        var bloom = context
        bloom.addFilter(.blur(radius: radius * (0.06 + glow * 0.06)))
        bloom.stroke(face, with: .color(color.opacity(0.08 + glow * 0.12)),
                     style: StrokeStyle(lineWidth: radius * 0.14, lineCap: .round, lineJoin: .round))
        glowStroke(face, in: &context, color: color, opacity: 1, width: radius * 0.065)
    }

    /// Clockwise corner of the Face ID frame, sampled to match a quarter orbit.
    private func faceCorner(_ fraction: Double, quadrant: Int) -> (Double, Double) {
        let x: Double
        let y: Double
        if fraction < 0.25 {
            x = 0.45 + fraction / 0.25 * 0.17; y = -0.86
        } else if fraction < 0.75 {
            let angle = (fraction - 0.25) / 0.5 * .pi / 2
            x = 0.62 + 0.24 * sin(angle); y = -0.62 - 0.24 * cos(angle)
        } else {
            x = 0.86; y = -0.62 + (fraction - 0.75) / 0.25 * 0.17
        }
        let rotation = Double(quadrant) * .pi / 2
        return (x * cos(rotation) - y * sin(rotation), x * sin(rotation) + y * cos(rotation))
    }

    private func drawOrbit(in context: inout GraphicsContext, center: CGPoint, radius: Double,
                           time: Double, ring: Int, settle: Double, processing: Double, alpha: Double, color: Color) {
        // A short angular trail gives the reference's phosphor-like moving light.
        for trail in (0...2).reversed() {
            let t = time - Double(trail) * 0.055
            let orbitalTime = max(0, t - 1.8)
            let yaw = orbitalTime * 2.4
            let pitch = 0.8 + sin(orbitalTime * 1.3) * 0.9
            let roll = sin(orbitalTime * 1.1) * 0.55
            var front = Path()
            var back = Path()
            var previous: CGPoint?
            for sample in 0...128 {
                let quadrant = min(3, sample / 32)
                let fraction = Double(sample - quadrant * 32) / 32
                let angle = -Double.pi / 2 + Double(quadrant) * .pi / 2 + fraction * .pi / 2
                let x = cos(angle)
                let y = ring == 0 ? sin(angle) : 0
                let z = ring == 0 ? 0 : sin(angle)
                let y1 = y * cos(pitch) - z * sin(pitch)
                let z1 = y * sin(pitch) + z * cos(pitch)
                let x2 = x * cos(yaw) + z1 * sin(yaw)
                let depth = -x * sin(yaw) + z1 * cos(yaw)
                let rx = x2 * cos(roll) - y1 * sin(roll)
                let ry = x2 * sin(roll) + y1 * cos(roll)
                let alignment = processing * 0.75
                let rotatedX = rx * (1 - alignment) + x * alignment
                let rotatedY = ry * (1 - alignment) + sin(angle) * alignment
                let perspective = 1 + depth * 0.035 * (1 - settle)
                let orbitX = (1 - settle) * rotatedX * perspective + settle * x
                let orbitY = (1 - settle) * rotatedY * perspective + settle * sin(angle)
                let point = CGPoint(x: center.x + radius * orbitX, y: center.y + radius * orbitY)
                if let previous {
                    if depth > 0 { front.move(to: previous); front.addLine(to: point) }
                    else { back.move(to: previous); back.addLine(to: point) }
                }
                previous = point
            }
            let trailOpacity = trail == 0 ? 1.0 : (trail == 1 ? 0.22 : 0.09)
            let width = radius * (trail == 0 ? 0.048 : 0.055)
            glowStroke(back, in: &context, color: color, opacity: alpha * trailOpacity * 0.48, width: width)
            glowStroke(front, in: &context, color: color, opacity: alpha * trailOpacity * 0.88, width: width)
        }
    }

    private func glowStroke(_ path: Path, in context: inout GraphicsContext,
                            color: Color, opacity: Double, width: Double) {
        guard opacity > 0 else { return }
        var glow = context
        glow.addFilter(.blur(radius: width * 1.4))
        glow.stroke(path, with: .color(color.opacity(opacity * 0.4)),
                    style: StrokeStyle(lineWidth: width * 2, lineCap: .round, lineJoin: .round))
        context.stroke(path, with: .color(color.opacity(opacity)),
                       style: StrokeStyle(lineWidth: width, lineCap: .round, lineJoin: .round))
    }

}
