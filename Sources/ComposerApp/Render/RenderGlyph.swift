import CoreGraphics
import Foundation

/// The handful of pictograms board elements carry, as plain vector paths: they stay crisp at any
/// zoom and draw on any thread, which rasterized SF Symbols would not.
enum RenderGlyph {
  case photo, lock, viewfinder, warning
  case circle, circleChecked, square, squareChecked

  func draw(in context: CGContext, rect: CGRect, color: CGColor) {
    guard rect.width > 0, rect.height > 0 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    let unit = min(rect.width, rect.height)
    let line = max(unit * 0.085, 0.5)
    context.setStrokeColor(color)
    context.setFillColor(color)
    context.setLineWidth(line)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    func point(_ x: CGFloat, _ y: CGFloat) -> CGPoint {
      CGPoint(x: rect.minX + x * rect.width, y: rect.minY + y * rect.height)
    }

    switch self {
    case .photo:
      let frame = CGRect(x: rect.minX + line / 2, y: rect.minY + rect.height * 0.14,
                         width: rect.width - line, height: rect.height * 0.72)
      context.addPath(CGPath(roundedRect: frame, cornerWidth: unit * 0.12, cornerHeight: unit * 0.12, transform: nil))
      context.strokePath()
      context.fillEllipse(in: CGRect(x: rect.minX + rect.width * 0.24, y: rect.minY + rect.height * 0.28,
                                     width: unit * 0.16, height: unit * 0.16))
      context.move(to: point(0.08, 0.76))
      context.addLine(to: point(0.38, 0.5))
      context.addLine(to: point(0.56, 0.66))
      context.addLine(to: point(0.72, 0.52))
      context.addLine(to: point(0.92, 0.72))
      context.strokePath()

    case .lock:
      let body = CGRect(x: rect.minX + rect.width * 0.2, y: rect.minY + rect.height * 0.46,
                        width: rect.width * 0.6, height: rect.height * 0.46)
      context.addPath(CGPath(roundedRect: body, cornerWidth: unit * 0.1, cornerHeight: unit * 0.1, transform: nil))
      context.fillPath()
      context.setLineWidth(unit * 0.12)
      context.addArc(center: point(0.5, 0.42), radius: rect.width * 0.19,
                     startAngle: .pi, endAngle: 0, clockwise: false)
      context.strokePath()

    case .viewfinder:
      let reach = 0.26
      for (cx, cy, dx, dy) in [(0.08, 0.08, 1.0, 1.0), (0.92, 0.08, -1.0, 1.0),
                               (0.08, 0.92, 1.0, -1.0), (0.92, 0.92, -1.0, -1.0)] {
        context.move(to: point(cx + dx * reach, cy))
        context.addLine(to: point(cx, cy))
        context.addLine(to: point(cx, cy + dy * reach))
      }
      for y in [0.38, 0.5, 0.62] {
        context.move(to: point(0.3, y))
        context.addLine(to: point(y == 0.62 ? 0.58 : 0.7, y))
      }
      context.strokePath()

    case .warning:
      context.move(to: point(0.5, 0.1))
      context.addLine(to: point(0.94, 0.88))
      context.addLine(to: point(0.06, 0.88))
      context.closePath()
      context.strokePath()
      context.move(to: point(0.5, 0.4))
      context.addLine(to: point(0.5, 0.62))
      context.strokePath()
      context.fillEllipse(in: CGRect(x: rect.midX - line * 0.7, y: rect.minY + rect.height * 0.72,
                                     width: line * 1.4, height: line * 1.4))

    case .circle:
      context.strokeEllipse(in: rect.insetBy(dx: line / 2 + unit * 0.04, dy: line / 2 + unit * 0.04))

    case .circleChecked:
      context.fillEllipse(in: rect.insetBy(dx: unit * 0.04, dy: unit * 0.04))
      knockOutCheck(in: context, rect: rect, unit: unit)

    case .square:
      let box = rect.insetBy(dx: line / 2 + unit * 0.06, dy: line / 2 + unit * 0.06)
      context.addPath(CGPath(roundedRect: box, cornerWidth: unit * 0.18, cornerHeight: unit * 0.18, transform: nil))
      context.strokePath()

    case .squareChecked:
      let box = rect.insetBy(dx: unit * 0.06, dy: unit * 0.06)
      context.addPath(CGPath(roundedRect: box, cornerWidth: unit * 0.2, cornerHeight: unit * 0.2, transform: nil))
      context.fillPath()
      knockOutCheck(in: context, rect: rect, unit: unit)
    }
  }

  /// The check mark cut out of a filled box, so whatever is behind the element shows through it.
  private func knockOutCheck(in context: CGContext, rect: CGRect, unit: CGFloat) {
    context.setBlendMode(.destinationOut)
    context.setLineWidth(unit * 0.11)
    context.move(to: CGPoint(x: rect.minX + rect.width * 0.3, y: rect.minY + rect.height * 0.52))
    context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.45, y: rect.minY + rect.height * 0.67))
    context.addLine(to: CGPoint(x: rect.minX + rect.width * 0.71, y: rect.minY + rect.height * 0.35))
    context.strokePath()
  }
}
