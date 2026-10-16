// Adapted from Moonglade (MIT, Copyright (c) 2026 Josemi Hernandez), Sources/MoongladeCore/Presentation/HangingNotchGeometry.swift; see docs/licences.md.
import CoreGraphics
import SwiftUI

/// The radii of the hanging silhouette. Compact and expanded use the same curves; growing only adds straight sides
/// and a longer bottom edge between them, so the capsule and the card are one shape at two sizes.
public enum HangingNotchMetrics {
    /// Concave shoulders where the shape meets the screen's top edge. The straight sides sit this far inside the
    /// shape's rect on each side.
    public static let topShoulderRadius: CGFloat = VT.Radius.islandShoulder
    public static let bottomCornerRadius: CGFloat = VT.Radius.islandBottom
}

/// Path of the top-attached notch silhouette: the top edge flares into the screen edge with concave shoulders, then
/// runs down straight sides into round lower corners. A rounded rectangle cannot express the shoulders.
public enum HangingNotchGeometry {
    public static func path(in rect: CGRect,
                            topShoulderRadius requestedTop: CGFloat = HangingNotchMetrics.topShoulderRadius,
                            bottomCornerRadius requestedBottom: CGFloat = HangingNotchMetrics.bottomCornerRadius) -> CGPath {
        let path = CGMutablePath()
        guard rect.width.isFinite, rect.height.isFinite, rect.width > 0, rect.height > 0 else { return path }

        let top0 = min(sanitized(requestedTop), rect.width / 2)
        let bottom0 = min(sanitized(requestedBottom), max(0, (rect.width - 2 * top0) / 2))
        // A short rect (the compact capsule) shrinks both arcs evenly instead of letting them overlap.
        let total = top0 + bottom0
        let scale = total > 0 ? min(1, rect.height / total) : 1
        let top = top0 * scale
        let bottom = bottom0 * scale
        let leftX = rect.minX + top
        let rightX = rect.maxX - top
        let upperY = rect.minY + top
        let lowerY = rect.maxY - bottom
        // Standard quarter-circle cubic constant.
        let k: CGFloat = 0.552_284_75
        let tc = top * k
        let bc = bottom * k

        path.move(to: CGPoint(x: rect.minX, y: rect.minY))
        path.addCurve(to: CGPoint(x: leftX, y: upperY),
                      control1: CGPoint(x: rect.minX + tc, y: rect.minY),
                      control2: CGPoint(x: leftX, y: upperY - tc))
        path.addLine(to: CGPoint(x: leftX, y: lowerY))
        path.addCurve(to: CGPoint(x: leftX + bottom, y: rect.maxY),
                      control1: CGPoint(x: leftX, y: lowerY + bc),
                      control2: CGPoint(x: leftX + bottom - bc, y: rect.maxY))
        path.addLine(to: CGPoint(x: rightX - bottom, y: rect.maxY))
        path.addCurve(to: CGPoint(x: rightX, y: lowerY),
                      control1: CGPoint(x: rightX - bottom + bc, y: rect.maxY),
                      control2: CGPoint(x: rightX, y: lowerY + bc))
        path.addLine(to: CGPoint(x: rightX, y: upperY))
        path.addCurve(to: CGPoint(x: rect.maxX, y: rect.minY),
                      control1: CGPoint(x: rightX, y: upperY - tc),
                      control2: CGPoint(x: rect.maxX - tc, y: rect.minY))
        path.closeSubpath()
        return path
    }

    /// Hit test in a top-left-origin rect of `size` (transparent shoulders and corner pockets are outside).
    public static func contains(_ point: CGPoint, size: CGSize) -> Bool {
        guard point.x.isFinite, point.y.isFinite else { return false }
        return path(in: CGRect(origin: .zero, size: size)).contains(point)
    }

    private static func sanitized(_ r: CGFloat) -> CGFloat { r.isFinite ? max(0, r) : 0 }
}

/// SwiftUI face of the silhouette.
struct HangingNotchShape: Shape {
    var topShoulderRadius = HangingNotchMetrics.topShoulderRadius
    var bottomCornerRadius = HangingNotchMetrics.bottomCornerRadius

    func path(in rect: CGRect) -> Path {
        Path(HangingNotchGeometry.path(in: rect, topShoulderRadius: topShoulderRadius, bottomCornerRadius: bottomCornerRadius))
    }
}
