import SwiftUI

struct BeamOverlayRootView: View {
    @ObservedObject var model: BeamOverlayModel
    let screenFrame: CGRect

    private let beamColor = Color(red: 0.46, green: 0.41, blue: 1.0)
    private let edgeColor = Color.white.opacity(0.92)

    var body: some View {
        TimelineView(.animation(minimumInterval: 1.0 / 60.0)) { _ in
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

                guard let currentPoint = snapshot.leadPoint else {
                    return
                }

                let current = localPoint(for: currentPoint)
                let beamPath: Path

                if let trailPoint = snapshot.trailPoint {
                    let trail = localPoint(for: trailPoint)
                    beamPath = mergedBeamPath(
                        from: trail,
                        to: current,
                        startRadius: snapshot.trailRadius,
                        endRadius: snapshot.leadRadius
                    )
                } else {
                    beamPath = circlePath(center: current, radius: snapshot.leadRadius)
                }

                drawGlow(for: beamPath, in: &context)
                context.fill(beamPath, with: .color(beamColor.opacity(0.18)))
                context.stroke(beamPath, with: .color(edgeColor), lineWidth: 2.4)
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

    private func mergedBeamPath(from start: CGPoint, to end: CGPoint, startRadius: CGFloat, endRadius: CGFloat) -> Path {
        let distance = start.distance(to: end)
        guard distance > 1 else {
            return circlePath(center: end, radius: max(startRadius, endRadius))
        }

        if distance <= abs(endRadius - startRadius) + 1 {
            if startRadius >= endRadius {
                return circlePath(center: start, radius: startRadius)
            }
            return circlePath(center: end, radius: endRadius)
        }

        let centerAngle = atan2(end.y - start.y, end.x - start.x)
        let tangentOffset = acos((startRadius - endRadius) / distance)
        let sourceReference = centerAngle + .pi
        let targetReference = centerAngle

        let sourceTop = point(on: start, radius: startRadius, angle: centerAngle + tangentOffset)
        let sourceBottom = point(on: start, radius: startRadius, angle: centerAngle - tangentOffset)
        let targetTop = point(on: end, radius: endRadius, angle: centerAngle + tangentOffset)
        let targetBottom = point(on: end, radius: endRadius, angle: centerAngle - tangentOffset)

        let handle = min(distance * 0.35, max(startRadius, endRadius) * 1.1)

        var path = Path()
        path.move(to: sourceTop)
        path.addCurve(
            to: targetTop,
            control1: sourceTop.offset(dx: handle * cos(centerAngle), dy: handle * sin(centerAngle)),
            control2: targetTop.offset(dx: -handle * cos(centerAngle), dy: -handle * sin(centerAngle))
        )

        for point in arcPoints(
            center: end,
            radius: endRadius,
            startAngle: centerAngle + tangentOffset,
            endAngle: centerAngle - tangentOffset,
            referenceAngle: targetReference
        ).dropFirst() {
            path.addLine(to: point)
        }

        path.addCurve(
            to: sourceBottom,
            control1: targetBottom.offset(dx: -handle * cos(centerAngle), dy: -handle * sin(centerAngle)),
            control2: sourceBottom.offset(dx: handle * cos(centerAngle), dy: handle * sin(centerAngle))
        )

        for point in arcPoints(
            center: start,
            radius: startRadius,
            startAngle: centerAngle - tangentOffset,
            endAngle: centerAngle + tangentOffset,
            referenceAngle: sourceReference
        ).dropFirst() {
            path.addLine(to: point)
        }

        path.closeSubpath()
        return path
    }

    private func arcPoints(
        center: CGPoint,
        radius: CGFloat,
        startAngle: CGFloat,
        endAngle: CGFloat,
        referenceAngle: CGFloat
    ) -> [CGPoint] {
        let normalizedStart = normalize(startAngle - referenceAngle)
        let normalizedEnd = normalize(endAngle - referenceAngle)
        let steps = 12

        let sampledAngles: [CGFloat]
        if normalizedStart >= normalizedEnd {
            sampledAngles = stride(from: normalizedStart, through: normalizedEnd, by: -(normalizedStart - normalizedEnd) / CGFloat(steps)).map {
                referenceAngle + $0
            }
        } else {
            sampledAngles = stride(from: normalizedStart, through: normalizedEnd, by: (normalizedEnd - normalizedStart) / CGFloat(steps)).map {
                referenceAngle + $0
            }
        }

        return sampledAngles.map { point(on: center, radius: radius, angle: $0) }
    }

    private func point(on center: CGPoint, radius: CGFloat, angle: CGFloat) -> CGPoint {
        CGPoint(
            x: center.x + cos(angle) * radius,
            y: center.y + sin(angle) * radius
        )
    }

    private func normalize(_ angle: CGFloat) -> CGFloat {
        var adjusted = angle.truncatingRemainder(dividingBy: .pi * 2)
        if adjusted > .pi {
            adjusted -= .pi * 2
        } else if adjusted < -.pi {
            adjusted += .pi * 2
        }
        return adjusted
    }
}

private extension CGPoint {
    func offset(dx: CGFloat, dy: CGFloat) -> CGPoint {
        CGPoint(x: x + dx, y: y + dy)
    }

    func distance(to other: CGPoint) -> CGFloat {
        hypot(other.x - x, other.y - y)
    }
}
