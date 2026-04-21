import CoreGraphics
import Foundation
import QuartzCore

struct BeamSnapshot {
    var trailPoint: CGPoint?
    var leadPoint: CGPoint?
    var trailRadius: CGFloat
    var leadRadius: CGFloat
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
        let livePoint = resolvedLeadPoint(at: time) ?? point
        let liveTrailRadius = resolvedTrailRadius(at: time)
        settledPoint = point

        let distance = livePoint.distance(to: point)
        guard distance >= 1 else {
            transition = nil
            objectWillChange.send()
            return
        }

        transition = BeamTransition(
            trailPoint: transition?.trailPoint ?? livePoint,
            leadStartPoint: livePoint,
            targetPoint: point,
            startTime: time,
            duration: max(0.09, min(0.24, Double(distance / 1300.0))),
            trailStartRadius: max(8, liveTrailRadius)
        )
        objectWillChange.send()
    }

    func clearTarget() {
        settledPoint = nil
        transition = nil
        objectWillChange.send()
    }

    func snapshot(at time: CFTimeInterval = CACurrentMediaTime()) -> BeamSnapshot {
        guard let leadPoint = resolvedLeadPoint(at: time) else {
            return BeamSnapshot(trailPoint: nil, leadPoint: nil, trailRadius: baseRadius, leadRadius: baseRadius)
        }

        guard let transition else {
            return BeamSnapshot(trailPoint: nil, leadPoint: leadPoint, trailRadius: baseRadius, leadRadius: baseRadius)
        }

        let progress = transition.progress(at: time)
        if progress >= 1 {
            return BeamSnapshot(trailPoint: nil, leadPoint: leadPoint, trailRadius: baseRadius, leadRadius: baseRadius)
        }

        return BeamSnapshot(
            trailPoint: transition.trailPoint,
            leadPoint: leadPoint,
            trailRadius: max(4, transition.trailStartRadius * (1.0 - 0.72 * progress)),
            leadRadius: baseRadius * (0.82 + 0.18 * progress)
        )
    }

    private func resolvedLeadPoint(at time: CFTimeInterval) -> CGPoint? {
        guard let transition else {
            return settledPoint
        }

        let progress = transition.progress(at: time)
        if progress >= 1 {
            return settledPoint
        }

        let eased = BeamTransition.easeOutCubic(progress)
        return transition.leadStartPoint.lerp(to: transition.targetPoint, t: eased)
    }

    private func resolvedTrailRadius(at time: CFTimeInterval) -> CGFloat {
        guard let transition else {
            return baseRadius
        }

        let progress = transition.progress(at: time)
        if progress >= 1 {
            return baseRadius
        }

        return max(4, transition.trailStartRadius * (1.0 - 0.72 * progress))
    }

    func setCalibrationTarget(_ point: CGPoint?) {
        calibrationTarget = point
    }
}

private struct BeamTransition {
    var trailPoint: CGPoint
    var leadStartPoint: CGPoint
    var targetPoint: CGPoint
    var startTime: CFTimeInterval
    var duration: Double
    var trailStartRadius: CGFloat

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
