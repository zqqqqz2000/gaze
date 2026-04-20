import SwiftUI

struct BeamOverlayRootView: View {
    @ObservedObject var model: BeamOverlayModel
    let screenFrame: CGRect

    private let beamColor = Color(red: 0.46, green: 0.41, blue: 1.0)
    private let edgeColor = Color.white.opacity(0.92)

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1.0 / 60.0)) { _ in
            Canvas { context, _ in
                let snapshot = model.snapshot()
                if let calibrationTarget = model.calibrationTarget {
                    let localTarget = localPoint(for: calibrationTarget)
                    let outerRing = circlePath(center: localTarget, radius: 26)
                    let innerRing = circlePath(center: localTarget, radius: 10)
                    drawGlow(for: outerRing, in: &context)
                    context.stroke(outerRing, with: .color(edgeColor.opacity(0.94)), lineWidth: 2.4)
                    context.fill(innerRing, with: .color(beamColor.opacity(0.22)))
                    context.stroke(innerRing, with: .color(edgeColor.opacity(0.84)), lineWidth: 1.6)
                }

                guard let currentPoint = snapshot.currentPoint else {
                    return
                }

                let current = localPoint(for: currentPoint)
                let endCircle = circlePath(center: current, radius: snapshot.endRadius)

                if let anchorPoint = snapshot.anchorPoint {
                    let anchor = localPoint(for: anchorPoint)
                    let startCircle = circlePath(center: anchor, radius: snapshot.startRadius)
                    let bridge = bridgePath(
                        from: anchor,
                        to: current,
                        startRadius: snapshot.startRadius,
                        endRadius: snapshot.endRadius
                    )

                    drawGlow(for: bridge, in: &context)
                    context.fill(bridge, with: .color(beamColor.opacity(0.14)))
                    context.stroke(bridge, with: .color(edgeColor.opacity(0.82)), lineWidth: 2.0)

                    drawGlow(for: startCircle, in: &context)
                    context.fill(startCircle, with: .color(beamColor.opacity(0.10)))
                    context.stroke(startCircle, with: .color(edgeColor.opacity(0.78)), lineWidth: 1.8)
                }

                drawGlow(for: endCircle, in: &context)
                context.fill(endCircle, with: .color(beamColor.opacity(0.18)))
                context.stroke(endCircle, with: .color(edgeColor), lineWidth: 2.4)
            }
            .ignoresSafeArea()
            .allowsHitTesting(false)
            .background(Color.clear)
        }
    }

    private func drawGlow(for path: Path, in context: inout GraphicsContext) {
        context.stroke(path, with: .color(beamColor.opacity(0.10)), lineWidth: 18)
        context.stroke(path, with: .color(beamColor.opacity(0.18)), lineWidth: 8)
    }

    private func localPoint(for globalPoint: CGPoint) -> CGPoint {
        CGPoint(
            x: globalPoint.x - screenFrame.minX,
            y: screenFrame.maxY - globalPoint.y
        )
    }

    private func circlePath(center: CGPoint, radius: CGFloat) -> Path {
        Path(ellipseIn: CGRect(
            x: center.x - radius,
            y: center.y - radius,
            width: radius * 2,
            height: radius * 2
        ))
    }

    private func bridgePath(from start: CGPoint, to end: CGPoint, startRadius: CGFloat, endRadius: CGFloat) -> Path {
        let distance = start.distance(to: end)
        guard distance > 1 else {
            return Path()
        }

        let direction = CGPoint(x: (end.x - start.x) / distance, y: (end.y - start.y) / distance)
        let normal = CGPoint(x: -direction.y, y: direction.x)
        let stepCount = max(16, Int(distance / 14))

        var left: [CGPoint] = []
        var right: [CGPoint] = []
        left.reserveCapacity(stepCount + 1)
        right.reserveCapacity(stepCount + 1)

        for index in 0...stepCount {
            let t = CGFloat(index) / CGFloat(stepCount)
            let point = start.lerp(to: end, t: t)
            let radius = startRadius + (endRadius - startRadius) * t
            left.append(point.offset(by: normal, scale: radius))
            right.append(point.offset(by: normal, scale: -radius))
        }

        var path = Path()
        path.move(to: left[0])
        for point in left.dropFirst() {
            path.addLine(to: point)
        }
        for point in right.reversed() {
            path.addLine(to: point)
        }
        path.closeSubpath()
        return path
    }
}

private extension CGPoint {
    func lerp(to other: CGPoint, t: CGFloat) -> CGPoint {
        CGPoint(x: x + (other.x - x) * t, y: y + (other.y - y) * t)
    }

    func offset(by normal: CGPoint, scale: CGFloat) -> CGPoint {
        CGPoint(x: x + normal.x * scale, y: y + normal.y * scale)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}
