import Foundation

/// Geometric continuity only, never identity or liveness evidence.
public enum FaceTrackContinuity {
    public static func isContinuous(from previous: FaceBounds, to current: FaceBounds) -> Bool {
        guard previous.isValid, current.isValid else { return false }
        let oldArea = previous.width * previous.height
        let newArea = current.width * current.height
        guard newArea / oldArea <= 1.8, oldArea / newArea <= 1.8 else { return false }
        let dx = abs(current.x + current.width / 2 - previous.x - previous.width / 2)
        let dy = abs(current.y + current.height / 2 - previous.y - previous.height / 2)
        guard dx <= max(current.width, previous.width) * 0.5,
              dy <= max(current.height, previous.height) * 0.5 else { return false }
        let width = max(0, min(previous.x + previous.width, current.x + current.width) - max(previous.x, current.x))
        let height = max(0, min(previous.y + previous.height, current.y + current.height) - max(previous.y, current.y))
        let intersection = width * height
        return intersection / (oldArea + newArea - intersection) >= 0.35
    }
}
