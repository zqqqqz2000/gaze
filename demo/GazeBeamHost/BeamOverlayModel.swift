import CoreGraphics
import Foundation
import QuartzCore

struct BeamSnapshot {
    var anchorPoint: CGPoint?
    var currentPoint: CGPoint?
    var startRadius: CGFloat
    var endRadius: CGFloat
}

@MainActor
final class BeamOverlayModel: ObservableObject {
    var baseRadius: CGFloat = 88 {
        didSet {
            objectWillChange.send()
        }
    }
    var calibrationTarget: CGPoint? {
        didSet {
            objectWillChange.send()
        }
    }

    private var settledPoint: CGPoint?
    private var transition: BeamTransition?

    func setTarget(_ point: CGPoint, at time: CFTimeInterval = CACurrentMediaTime()) {
        let livePoint = resolvedPoint(at: time) ?? point
        settledPoint = point

        let distance = livePoint.distance(to: point)
        guard distance >= 1 else {
            transition = nil
            objectWillChange.send()
            return
        }

        transition = BeamTransition(
            anchorPoint: livePoint,
            targetPoint: point,
            startTime: time,
            duration: max(0.09, min(0.24, Double(distance / 1300.0)))
        )
        objectWillChange.send()
    }

    func clearTarget() {
        settledPoint = nil
        transition = nil
        objectWillChange.send()
    }

    func snapshot(at time: CFTimeInterval = CACurrentMediaTime()) -> BeamSnapshot {
        guard let currentPoint = resolvedPoint(at: time) else {
            return BeamSnapshot(anchorPoint: nil, currentPoint: nil, startRadius: baseRadius, endRadius: baseRadius)
        }

        guard let transition else {
            return BeamSnapshot(anchorPoint: nil, currentPoint: currentPoint, startRadius: baseRadius, endRadius: baseRadius)
        }

        let progress = transition.progress(at: time)
        if progress >= 1 {
            return BeamSnapshot(anchorPoint: nil, currentPoint: currentPoint, startRadius: baseRadius, endRadius: baseRadius)
        }

        return BeamSnapshot(
            anchorPoint: transition.anchorPoint,
            currentPoint: currentPoint,
            startRadius: baseRadius * (1.0 - 0.62 * progress),
            endRadius: baseRadius * (0.76 + 0.24 * progress)
        )
    }

    private func resolvedPoint(at time: CFTimeInterval) -> CGPoint? {
        guard let transition else {
            return settledPoint
        }

        let progress = transition.progress(at: time)
        if progress >= 1 {
            return settledPoint
        }

        let eased = BeamTransition.easeOutCubic(progress)
        return transition.anchorPoint.lerp(to: transition.targetPoint, t: eased)
    }

    func setCalibrationTarget(_ point: CGPoint?) {
        calibrationTarget = point
    }
}

private struct BeamTransition {
    var anchorPoint: CGPoint
    var targetPoint: CGPoint
    var startTime: CFTimeInterval
    var duration: Double

    func progress(at time: CFTimeInterval) -> CGFloat {
        guard duration > 0 else {
            return 1
        }
        return min(1, max(0, CGFloat((time - startTime) / duration)))
    }

    static func easeOutCubic(_ value: CGFloat) -> CGFloat {
        let inverse = 1 - value
        return 1 - inverse * inverse * inverse
    }
}

private extension CGPoint {
    func lerp(to other: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(
            x: x + (other.x - x) * t,
            y: y + (other.y - y) * t
        )
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}
