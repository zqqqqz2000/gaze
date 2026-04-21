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
    private let transitionSpeed: CGFloat = 1600

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
        settledPoint = point

        let distance = livePoint.distance(to: point)
        guard distance >= 1 else {
            transition = nil
            objectWillChange.send()
            return
        }

        transition = BeamTransition(
            startPoint: livePoint,
            targetPoint: point,
            startTime: time,
            duration: max(Double(1.0 / 120.0), Double(distance / transitionSpeed)),
            trailStartRadius: baseRadius
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
            trailPoint: transition.trailPoint(at: time),
            leadPoint: leadPoint,
            trailRadius: max(1, transition.trailStartRadius * (1.0 - progress)),
            leadRadius: baseRadius
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

        return transition.targetPoint
    }

    func setCalibrationTarget(_ point: CGPoint?) {
        calibrationTarget = point
    }
}

private struct BeamTransition {
    var startPoint: CGPoint
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

    func trailPoint(at time: CFTimeInterval) -> CGPoint {
        startPoint.lerp(to: targetPoint, t: progress(at: time))
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
