import AppKit
import os
import CoreText

/// How a render target maps board units onto pixels, and what detail is worth drawing there.
struct RenderEnvironment: Sendable {
  /// Device pixels per board unit in the target bitmap.
  let pixelScale: CGFloat
  /// On-screen points per board unit — the zoom the result is viewed at.
  let zoom: CGFloat
  let images: any RenderImageSource

  /// Soft shadows vanish into a pixel or two once zoomed out; skipping them there is invisible
  /// and removes the most expensive part of a dark-theme redraw.
  var drawsShadows: Bool { zoom >= 0.4 }
  /// Strokes never thin below ~¾ of a screen point, so an overview of a large board stays legible.
  var minimumStroke: CGFloat { 0.75 / max(zoom, 0.01) }
  /// Text smaller than this on screen is drawn as bars instead of being laid out.
  func greeks(fontSize: CGFloat) -> Bool { fontSize * zoom < 2.4 }
}

/// One board element resolved for drawing: the card as currently shown (any in-flight gesture
/// applied), its live text, and the theme it draws in.
///
/// Immutable once built. The scene swaps in a new instance when anything it draws from changes,
/// so background tile renders can hold on to the old one safely. Derived layout (wrapped text,
/// paths) is computed on first draw and cached behind a lock.
///
/// All drawing is in board space with y pointing DOWN. A target context maps that onto its pixels
/// without a flip (bitmap rows run bottom-up); the board layer mirrors tiles back on display and
/// the exporter flips its one bitmap. Text and images are flipped locally where they draw.
final class RenderElement: @unchecked Sendable {
  /// Presentation state that changes how an element draws without changing its card.
  struct Variant: Equatable, Sendable {
    /// A text element mid corner-scale: its base layout drawn at this geometric scale.
    var textPreviewScale: CGFloat = 1
    /// A graph an equation is being dragged over.
    var isDropTarget = false
    /// A selected graph's legend is drawn by its interactive overlay instead.
    var hidesLegend = false
  }

  let card: CardState
  let text: String
  let ink: [InkRun]
  let variant: Variant
  let style: RenderStyle
  /// Everything this element can paint, in board space: its frame plus stroke, shadow, label and
  /// badge overhang. Tiles are invalidated and culled by this rectangle.
  let paintBounds: CGRect
  /// Paint order within the scene (main-thread bookkeeping).
  var order = 0
  /// Unique to this instance for the life of the process. An element never changes, so two tiles
  /// that list the same serials hold the same picture — which is how a tile knows it is current.
  let serial: Int = RenderElement.serials.withLock { counter in
    counter += 1
    return counter
  }
  private static let serials = OSAllocatedUnfairLock(initialState: 0)

  /// A line or arrow's paint bounds are the box around a thin diagonal. This is the part of that
  /// box it actually touches, so it is neither drawn into nor repaints the tiles it only spans.
  private struct Stroke {
    var start: CGPoint
    var end: CGPoint
    var reach: CGFloat
    /// The label and the lock badge.
    var boxes: [CGRect]
  }
  private let stroke: Stroke?

  private let lock = NSLock()
  private var payload: Any?

  /// - Parameter previous: the element this one replaces. Cached layout is card-local, so an
  ///   element that only moved (a drag frame) inherits it instead of laying out again.
  init(card: CardState, text: String, ink: [InkRun], variant: Variant, style: RenderStyle,
       reusing previous: RenderElement? = nil) {
    self.card = card
    self.text = text
    self.ink = ink
    self.variant = variant
    self.style = style
    paintBounds = Self.paintBounds(of: card, text: text, style: style)
    stroke = Self.stroke(of: card, text: text, style: style)
    if let previous, previous.style === style, previous.variant == variant, previous.text == text,
       previous.ink == ink, Self.sameContent(previous.card, card) {
      payload = previous.currentPayload()
    }
  }

  /// True when `b` is `a` moved: identical in everything but its origin.
  static func sameContent(_ a: CardState, _ b: CardState) -> Bool {
    var moved = a
    moved.x = b.x
    moved.y = b.y
    return moved == b
  }

  private func currentPayload() -> Any? {
    lock.lock()
    defer { lock.unlock() }
    return payload
  }

  func matches(card: CardState, text: String, ink: [InkRun], variant: Variant, style: RenderStyle) -> Bool {
    self.style === style && self.variant == variant && self.text == text && self.ink == ink && self.card == card
  }

  /// The cached derived layout for this element's kind, built once.
  func prepared<T>(_ make: () -> T) -> T {
    lock.lock()
    defer { lock.unlock() }
    if let existing = payload as? T { return existing }
    let made = make()
    payload = made
    return made
  }

  var frame: CGRect { card.frame }
  var tint: CGColor? { style.tint(card.tint) }
  var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

  // MARK: Bounds

  static func paintBounds(of card: CardState, text: String, style: RenderStyle) -> CGRect {
    let shadow: CGFloat = style.isDark ? 36 : 0
    var bounds: CGRect
    switch card.elementKind {
    case .line, .arrow:
      let ends = ConnectorGeometry.endpoints(of: card)
      let span = ends.map { ElementGeometry.rect(spanning: [$0.start, $0.end]) } ?? card.frame
      bounds = span.insetBy(dx: -20 - shadow, dy: -20 - shadow)
      if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
        let label = CGRect(x: card.frame.midX - 140, y: card.frame.midY - 44, width: 280, height: 88)
        bounds = bounds.union(label.insetBy(dx: -shadow / 2, dy: -shadow / 2))
      }
    case .freehand, .vectorPath:
      bounds = card.frame.insetBy(dx: -10 - shadow, dy: -10 - shadow)
    case .text:
      // Text takes the height it needs. The frame was fitted to the PLAIN text, so styled text
      // (headings up to 1.5×, bold, code) can run well past it; bound that without a layout.
      let line = max(style.bodyFontSize * card.textScale * 1.4, 18)
      let styled = text.utf8.contains { $0 == UInt8(ascii: "#") || $0 == UInt8(ascii: "*") || $0 == UInt8(ascii: "`") }
      bounds = card.frame.insetBy(dx: -6, dy: -6)
      bounds.size.height = max(bounds.height * (styled ? 2.4 : 1.15), bounds.height) + line * 2
    case .table:
      var natural = card.frame
      natural.size.height = max(natural.height, tableHeight(card.table ?? CardState.TableSpec()))
      bounds = natural.insetBy(dx: -6 - shadow, dy: -6 - shadow)
    default:
      bounds = card.frame.insetBy(dx: -6 - shadow, dy: -6 - shadow)
    }
    if card.locked {
      bounds = bounds.union(CGRect(x: card.frame.minX - 16, y: card.frame.minY - 16, width: 44, height: 44))
    }
    return bounds
  }

  private static func stroke(of card: CardState, text: String, style: RenderStyle) -> Stroke? {
    guard card.elementKind == .line || card.elementKind == .arrow,
          let ends = ConnectorGeometry.endpoints(of: card) else { return nil }
    let shadow: CGFloat = style.isDark ? 36 : 0
    var boxes: [CGRect] = []
    if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      boxes.append(CGRect(x: card.frame.midX - 140, y: card.frame.midY - 44, width: 280, height: 88)
        .insetBy(dx: -shadow / 2, dy: -shadow / 2))
    }
    if card.locked {
      boxes.append(CGRect(x: card.frame.minX - 16, y: card.frame.minY - 16, width: 44, height: 44))
    }
    return Stroke(start: ends.start, end: ends.end, reach: 20 + shadow, boxes: boxes)
  }

  /// Whether this element can put a pixel in `rect`.
  func paints(in rect: CGRect) -> Bool {
    guard paintBounds.intersects(rect) else { return false }
    guard let stroke else { return true }
    if stroke.boxes.contains(where: { $0.intersects(rect) }) { return true }
    return Self.segment(from: stroke.start, to: stroke.end,
                        touches: rect.insetBy(dx: -stroke.reach, dy: -stroke.reach))
  }

  /// The part of `rect` this element can put a pixel in (null when none).
  func coverage(in rect: CGRect) -> CGRect {
    guard let stroke else { return paintBounds.intersection(rect) }
    var covered = CGRect.null
    for box in stroke.boxes { covered = covered.union(box.intersection(rect)) }
    if let run = Self.clip(from: stroke.start, to: stroke.end,
                           to: rect.insetBy(dx: -stroke.reach, dy: -stroke.reach)) {
      let reached = CGRect(x: min(run.0.x, run.1.x), y: min(run.0.y, run.1.y),
                           width: abs(run.1.x - run.0.x), height: abs(run.1.y - run.0.y))
        .insetBy(dx: -stroke.reach, dy: -stroke.reach)
      covered = covered.union(reached.intersection(rect))
    }
    return covered.intersection(paintBounds)
  }

  static func segment(from a: CGPoint, to b: CGPoint, touches rect: CGRect) -> Bool {
    clip(from: a, to: b, to: rect) != nil
  }

  /// Liang–Barsky: the part of the segment inside `rect`, or nil when it misses.
  static func clip(from a: CGPoint, to b: CGPoint, to rect: CGRect) -> (CGPoint, CGPoint)? {
    var enter: CGFloat = 0, leave: CGFloat = 1
    let dx = b.x - a.x, dy = b.y - a.y
    for (direction, distance) in [(-dx, a.x - rect.minX), (dx, rect.maxX - a.x),
                                  (-dy, a.y - rect.minY), (dy, rect.maxY - a.y)] {
      if direction == 0 {
        if distance < 0 { return nil }
      } else {
        let t = distance / direction
        if direction < 0 {
          if t > leave { return nil }
          enter = max(enter, t)
        } else {
          if t < enter { return nil }
          leave = min(leave, t)
        }
      }
    }
    return (CGPoint(x: a.x + dx * enter, y: a.y + dy * enter), CGPoint(x: a.x + dx * leave, y: a.y + dy * leave))
  }

  // MARK: Drawing

  func draw(in context: CGContext, environment: RenderEnvironment) {
    guard frame.width.isFinite, frame.height.isFinite, frame.width > 0, frame.height > 0 else { return }
    context.saveGState()
    defer { context.restoreGState() }
    // Nothing may land outside the bounds tiles are invalidated by, or it would linger as a ghost.
    context.clip(to: paintBounds)
    let faded = card.isArchived
    if faded {
      context.setAlpha(0.4)
      context.beginTransparencyLayer(in: paintBounds, auxiliaryInfo: nil)
    }
    switch card.elementKind {
    case .text: drawText(in: context, environment: environment)
    case .rectangle, .ellipse, .diamond: drawShape(in: context, environment: environment)
    case .line, .arrow: drawConnector(in: context, environment: environment)
    case .freehand: drawFreehand(in: context, environment: environment)
    case .vectorPath: drawVectorPath(in: context, environment: environment)
    case .image: drawImage(in: context, environment: environment)
    case .equation: drawEquation(in: context, environment: environment)
    case .graph: drawGraph(in: context, environment: environment)
    case .sticky: drawSticky(in: context, environment: environment)
    case .checklist: drawChecklist(in: context, environment: environment)
    case .table: drawTable(in: context, environment: environment)
    }
    if card.locked { drawLockBadge(in: context, environment: environment) }
    if faded { context.endTransparencyLayer() }
  }

  /// Run `body` with the element shadow cast beneath everything it draws (one silhouette, so a
  /// filled-and-stroked shape casts a single shadow).
  ///
  /// A soft shadow carries no detail, so it is blurred at a fraction of the output resolution and
  /// scaled up: the same picture as a full-resolution Core Graphics shadow at a few percent of
  /// its cost — which was over nine tenths of a dark-theme repaint.
  func withShadow(_ context: CGContext, _ environment: RenderEnvironment,
                  radius: CGFloat, y: CGFloat, opacity: CGFloat = 1,
                  _ body: (CGContext) -> Void) {
    if let color = style.elementShadow, environment.drawsShadows {
      castShadow(in: context, environment, radius: radius, y: y,
                 color: opacity == 1 ? color : color.alpha(opacity), body)
    }
    body(context)
  }

  private func castShadow(in context: CGContext, _ environment: RenderEnvironment,
                          radius: CGFloat, y: CGFloat, color: CGColor,
                          _ body: (CGContext) -> Void) {
    // Shadow blur and offset are device-pixel quantities.
    let blur = radius * 2 * environment.pixelScale
    let offset = y * environment.pixelScale
    // Low enough that the blur is a few pixels wide, never so low that scaling it back up shows.
    let reduction = min(1, max(0.125, 4 / max(radius * environment.pixelScale, 0.01)))
    let ctm = context.ctm
    // What can show: the clip (this tile's share of the element), plus the reach of a shadow cast
    // from just outside it.
    let reach = blur + abs(offset) + 2
    let target = context.boundingBoxOfClipPath.applying(ctm).standardized.integral
      .insetBy(dx: -reach, dy: -reach)
    let width = Int((target.width * reduction).rounded(.up)), height = Int((target.height * reduction).rounded(.up))
    guard width > 0, height > 0, width <= 4_096, height <= 4_096,
          // In the target's own color space, so neither blit below has to convert a pixel.
          let silhouette = RenderBitmap.context(width: width, height: height,
                                                space: context.colorSpace ?? RenderBitmap.colorSpace),
          let shadow = RenderBitmap.context(width: width, height: height,
                                            space: context.colorSpace ?? RenderBitmap.colorSpace) else { return }

    // 1. What casts the shadow, small.
    silhouette.scaleBy(x: reduction, y: reduction)
    silhouette.translateBy(x: -target.minX, y: -target.minY)
    silhouette.concatenate(ctm)
    body(silhouette)
    guard let caster = silhouette.makeImage() else { return }

    // 2. Its shadow alone: the caster is drawn off the bitmap and its shadow thrown back onto it.
    let away = CGFloat(width) + blur * reduction + 8
    shadow.setShadow(offset: CGSize(width: -away, height: offset * reduction), blur: blur * reduction, color: color)
    shadow.draw(caster, in: CGRect(x: away, y: 0, width: CGFloat(width), height: CGFloat(height)))
    guard let cast = shadow.makeImage() else { return }

    // 3. Scaled back up, in device space so no transform of the caller's can turn it over.
    context.saveGState()
    context.concatenate(ctm.inverted())
    context.interpolationQuality = .low
    context.draw(cast, in: CGRect(x: target.minX, y: target.minY,
                                  width: CGFloat(width) / reduction, height: CGFloat(height) / reduction))
    context.restoreGState()
  }

  func strokeWidth(_ width: CGFloat, _ environment: RenderEnvironment) -> CGFloat {
    max(width, environment.minimumStroke)
  }

  // MARK: Shapes

  private func shapePath() -> CGPath {
    let rect = frame.insetBy(dx: ShapeLabelGeometry.shapePathInset, dy: ShapeLabelGeometry.shapePathInset)
    switch card.elementKind {
    case .ellipse:
      return CGPath(ellipseIn: rect, transform: nil)
    case .diamond:
      let path = CGMutablePath()
      path.move(to: CGPoint(x: rect.midX, y: rect.minY))
      path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
      path.addLine(to: CGPoint(x: rect.midX, y: rect.maxY))
      path.addLine(to: CGPoint(x: rect.minX, y: rect.midY))
      path.closeSubpath()
      return path
    default:
      let radius = min(8, rect.width / 2, rect.height / 2)
      return CGPath(roundedRect: rect, cornerWidth: max(radius, 0), cornerHeight: max(radius, 0), transform: nil)
    }
  }

  private func drawShape(in context: CGContext, environment: RenderEnvironment) {
    guard frame.width > ShapeLabelGeometry.shapePathInset * 2,
          frame.height > ShapeLabelGeometry.shapePathInset * 2 else { return }
    let path = shapePath()
    let fill = tint.map { $0.alpha(style.isDark ? 0.16 : 0.10) } ?? style.elementFill
    withShadow(context, environment, radius: 10, y: 4) { context in
      if let fill {
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
      }
      context.addPath(path)
      context.setStrokeColor(tint ?? style.elementStroke)
      context.setLineWidth(strokeWidth(2, environment))
      context.setLineJoin(.miter)
      context.strokePath()
    }
    drawNodeLabel(in: context, environment: environment)
  }

  /// The centered label inside a diagram node — the surrounding shape is its container.
  private func drawNodeLabel(in context: CGContext, environment: RenderEnvironment) {
    let label = trimmedText
    guard !label.isEmpty else { return }
    let fontSize = 14 * card.textScale
    let color = tint ?? style.body
    let wrap = max(min(ShapeLabelGeometry.defaultMaximumContentWidth * card.textScale,
                       frame.width - ShapeLabelGeometry.horizontalPadding * 2), 12)
    if environment.greeks(fontSize: fontSize) {
      let width = min(CGFloat(label.count) * fontSize * 0.5, wrap)
      context.setFillColor(color.alpha(0.35))
      context.fill(CGRect(x: frame.midX - width / 2, y: frame.midY - fontSize * 0.25, width: width, height: fontSize * 0.5))
      return
    }
    let layout: TextLayout = prepared {
      TextLayout(NSAttributedString(render: label, font: style.font(fontSize, weight: .semibold), color: color),
                 width: wrap, alignment: .center)
    }
    let origin = CGPoint(x: frame.midX - wrap / 2, y: frame.midY - layout.size.height / 2)
    withShadow(context, environment, radius: 3, y: 1) { context in
      layout.draw(in: context, at: origin)
    }
  }

  // MARK: Lines and arrows

  private func drawConnector(in context: CGContext, environment: RenderEnvironment) {
    guard let ends = ConnectorGeometry.endpoints(of: card) else { return }
    let path = CGMutablePath()
    path.move(to: ends.start)
    path.addLine(to: ends.end)
    if card.elementKind == .arrow {
      let angle = atan2(ends.end.y - ends.start.y, ends.end.x - ends.start.x)
      let head: CGFloat = 15
      for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
        path.move(to: ends.end)
        path.addLine(to: CGPoint(x: ends.end.x + cos(angle + side) * head,
                                 y: ends.end.y + sin(angle + side) * head))
      }
    }
    strokeInk(path, in: context, environment: environment)
    drawConnectorLabel(in: context, environment: environment)
  }

  /// The 3pt round-capped ink stroke shared by lines, arrows, freehand and pen paths.
  private func strokeInk(_ path: CGPath, in context: CGContext, environment: RenderEnvironment) {
    withShadow(context, environment, radius: 6, y: 3) { context in
      context.addPath(path)
      context.setStrokeColor(tint ?? style.elementStroke)
      context.setLineWidth(strokeWidth(3, environment))
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.strokePath()
    }
  }

  /// A connector's label: a solid pill at its middle so the text stays legible over the stroke.
  private func drawConnectorLabel(in context: CGContext, environment: RenderEnvironment) {
    let label = trimmedText
    guard !label.isEmpty else { return }
    let fontSize = 14 * card.textScale
    guard !environment.greeks(fontSize: fontSize) else { return }
    let layout: TextLayout = prepared {
      let string = NSAttributedString(render: label, font: style.font(fontSize, weight: .semibold), color: style.body)
      // Measure first so the pill hugs short labels, then wrap long ones at the cap.
      let natural = TextLayout(string, width: .greatestFiniteMagnitude, maxLines: 1)
      let wrap = min(natural.size.width + 1, 222)
      return TextLayout(string, width: wrap, maxLines: 2, alignment: .center)
    }
    let textWidth = layout.lines.map(\.width).max() ?? 0
    let wrap = max(layout.size.width, textWidth)
    let pill = CGRect(x: frame.midX - wrap / 2 - 9, y: frame.midY - layout.size.height / 2 - 5,
                      width: wrap + 18, height: layout.size.height + 10)
    let shape = CGPath(roundedRect: pill, cornerWidth: 7, cornerHeight: 7, transform: nil)
    withShadow(context, environment, radius: 4, y: 1) { context in
      context.addPath(shape)
      context.setFillColor(style.labelChipFill)
      context.fillPath()
    }
    context.addPath(CGPath(roundedRect: pill.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 6.5, cornerHeight: 6.5, transform: nil))
    context.setStrokeColor(style.panelHairline)
    context.setLineWidth(1)
    context.strokePath()
    // Lines were aligned within `wrap`; shift so that block is centred on the connector.
    let blockWidth = layout.lines.first.map { $0.x * 2 + $0.width } ?? wrap
    layout.draw(in: context, at: CGPoint(x: frame.midX - blockWidth / 2, y: pill.minY + 5))
  }

  // MARK: Freehand and pen paths

  private func drawFreehand(in context: CGContext, environment: RenderEnvironment) {
    let points = card.points ?? CardState.defaultFreehandPoints()
    guard points.count > 1 else { return }
    // Below ~¾ of a pixel a vertex changes nothing; dropping those keeps a zoomed-out board of
    // long strokes cheap to redraw.
    let tolerance = 0.75 / max(environment.pixelScale, 0.01)
    let path: CGPath
    if tolerance > 0.6, points.count > 16 {
      path = Self.polyline(points, size: frame.size, tolerance: tolerance)
    } else {
      let box: PathBox = prepared { PathBox(path: Self.polyline(points, size: self.frame.size, tolerance: 0)) }
      path = box.path
    }
    context.translateBy(x: frame.minX, y: frame.minY)
    strokeInk(path, in: context, environment: environment)
  }

  private static func polyline(_ points: [CanvasPoint], size: CGSize, tolerance: CGFloat) -> CGPath {
    let path = CGMutablePath()
    var last = CGPoint.zero
    let lastIndex = points.count - 1
    for (index, point) in points.enumerated() {
      let mapped = CGPoint(x: point.x * size.width, y: point.y * size.height)
      if index == 0 {
        path.move(to: mapped)
      } else if index == lastIndex || abs(mapped.x - last.x) >= tolerance || abs(mapped.y - last.y) >= tolerance {
        path.addLine(to: mapped)
      } else {
        continue
      }
      last = mapped
    }
    return path
  }

  private func drawVectorPath(in context: CGContext, environment: RenderEnvironment) {
    guard let spec = card.vectorPath else { return }
    let box: PathBox = prepared {
      PathBox(path: VectorPathGeometry.path(for: spec, in: CGRect(origin: .zero, size: self.frame.size)))
    }
    let path = box.path
    let fill = spec.isClosed ? (tint.map { $0.alpha(style.isDark ? 0.13 : 0.08) } ?? style.elementFill) : nil
    context.translateBy(x: frame.minX, y: frame.minY)
    withShadow(context, environment, radius: 6, y: 3) { context in
      if let fill {
        context.addPath(path)
        context.setFillColor(fill)
        context.fillPath()
      }
      context.addPath(path)
      context.setStrokeColor(tint ?? style.elementStroke)
      context.setLineWidth(strokeWidth(3, environment))
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.strokePath()
    }
  }

  // MARK: Text

  /// A text element's content, laid out at 100% in board units.
  struct TextBody: @unchecked Sendable {
    struct Row {
      var layout: TextLayout
      var origin: CGPoint
      /// The checkbox this row leads with, in card-local board units.
      var checkbox: CGRect?
      var checked = false
    }
    var rows: [Row]
    /// Checkbox rows by line index — what a click toggles.
    var checkboxFrames: [Int: CGRect]
    var isPlaceholder = false
  }

  static let textInset = CGSize(width: 16, height: 18)

  /// Lay out a text element's body. `width` is the card width the layout wraps in.
  static func textBody(text: String, ink: [InkRun], card: CardState, width: CGFloat, style: RenderStyle) -> TextBody {
    let scale = max(card.textScale, 0.01)
    let fontSize = style.bodyFontSize * scale
    let lineSpacing = Theme.Typography.bodyLineSpacing * scale
    let wrap = max(width - textInset.width * 2, 40)
    let tint = style.tint(card.tint)
    let origin = CGPoint(x: textInset.width, y: textInset.height)

    if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
      let string = NSAttributedString(render: "Brain dump...".localizedUI, font: style.font(fontSize), color: style.placeholder)
      let layout = TextLayout(string, width: wrap, lineSpacing: lineSpacing)
      return TextBody(rows: [.init(layout: layout, origin: origin)], checkboxFrames: [:], isPlaceholder: true)
    }

    let lines = text.components(separatedBy: "\n")
    let isChecklist = lines.contains { $0.hasPrefix("- [ ] ") || $0.lowercased().hasPrefix("- [x] ") }
    guard isChecklist else {
      let string = MarkdownStyle.renderedAttributedString(
        text, ink: ink, fontSize: fontSize, baseColor: tint ?? style.body, style: style)
      let layout = TextLayout(string, width: wrap, lineSpacing: lineSpacing)
      return TextBody(rows: [.init(layout: layout, origin: origin)], checkboxFrames: [:])
    }

    // A text card holding task lines reads as a list: one row per line, a tappable box on tasks.
    let font = style.font(fontSize)
    let box = (fontSize * 1.13).rounded()
    let gap = 8 * scale
    var rows: [TextBody.Row] = []
    var frames: [Int: CGRect] = [:]
    var y = origin.y
    for (index, line) in lines.enumerated() {
      let lower = line.lowercased()
      let isTask = line.hasPrefix("- [ ] ") || lower.hasPrefix("- [x] ")
      if isTask {
        let checked = lower.hasPrefix("- [x] ")
        var attributes: [NSAttributedString.Key: Any] = [
          RenderTextAttribute.font: font,
          RenderTextAttribute.color: checked ? style.menuDesc : (tint ?? style.body),
        ]
        if checked { attributes[RenderTextAttribute.strikethrough] = true }
        let layout = TextLayout(NSAttributedString(string: String(line.dropFirst(6)), attributes: attributes),
                                width: max(wrap - box - gap, 20))
        let height = max(layout.size.height, box)
        let frame = CGRect(x: origin.x, y: y + (height - box) / 2, width: box, height: box)
        frames[index] = frame
        rows.append(.init(layout: layout,
                          origin: CGPoint(x: origin.x + box + gap, y: y + (height - layout.size.height) / 2),
                          checkbox: frame, checked: checked))
        y += height + 3 * scale
      } else {
        let layout = TextLayout(NSAttributedString(render: line.isEmpty ? " " : line, font: font, color: tint ?? style.body),
                                width: wrap)
        rows.append(.init(layout: layout, origin: CGPoint(x: origin.x, y: y)))
        y += layout.size.height + 3 * scale
      }
    }
    return TextBody(rows: rows, checkboxFrames: frames)
  }

  private func drawText(in context: CGContext, environment: RenderEnvironment) {
    let previewScale = max(variant.textPreviewScale, 0.01)
    let fontSize = style.bodyFontSize * card.textScale * previewScale
    context.translateBy(x: frame.minX, y: frame.minY)
    if previewScale != 1 { context.scaleBy(x: previewScale, y: previewScale) }
    let width = frame.width / previewScale

    if environment.greeks(fontSize: fontSize) {
      drawGreekedText(in: context, width: width, height: frame.height / previewScale)
      return
    }
    let body: TextBody = prepared {
      Self.textBody(text: self.text, ink: self.ink, card: self.card, width: width, style: self.style)
    }
    for row in body.rows {
      if let box = row.checkbox {
        let color = row.checked ? (tint ?? style.accent) : style.menuDesc
        (row.checked ? RenderGlyph.circleChecked : .circle).draw(in: context, rect: box, color: color)
      }
      row.layout.draw(in: context, at: row.origin)
    }
  }

  /// Text too small to read: bars estimated from the characters alone, with no layout at all.
  private func drawGreekedText(in context: CGContext, width: CGFloat, height: CGFloat) {
    let fontSize = style.bodyFontSize * card.textScale
    let wrap = max(width - Self.textInset.width * 2, 40)
    let lineHeight = fontSize * 1.2 + Theme.Typography.bodyLineSpacing * card.textScale
    context.setFillColor((trimmedText.isEmpty ? style.placeholder : (tint ?? style.body)).alpha(0.35))
    var y = Self.textInset.height
    let source = trimmedText.isEmpty ? "Brain dump..." : text
    for paragraph in source.split(separator: "\n", omittingEmptySubsequences: false) {
      var remaining = CGFloat(paragraph.count) * fontSize * 0.5
      repeat {
        guard y + lineHeight <= height + lineHeight else { return }
        let run = min(remaining, wrap)
        if run > 0 {
          context.fill(CGRect(x: Self.textInset.width, y: y + lineHeight * 0.3, width: run, height: fontSize * 0.45))
        }
        remaining -= wrap
        y += lineHeight
      } while remaining > 0
    }
  }

  /// Where a text or checklist element's task boxes sit, in card-local board units.
  @MainActor
  static func checkboxFrames(for card: CardState, text: String) -> [Int: CGRect] {
    let style = RenderStyle.current
    switch card.elementKind {
    case .text:
      guard text.contains("- [") else { return [:] }
      return textBody(text: text, ink: [], card: card, width: card.frame.width, style: style).checkboxFrames
    case .checklist:
      return checklistLayout(items: card.checklist ?? [], width: card.frame.width, style: style).checkboxFrames
    default:
      return [:]
    }
  }

  // MARK: Badges

  private func drawLockBadge(in context: CGContext, environment: RenderEnvironment) {
    // A fixed 20pt on screen across the working zoom range; it scales with the board beyond it.
    let scale = 1 / min(max(environment.zoom, 0.5), 2)
    let side = 20 * scale
    let circle = CGRect(x: frame.minX - 7 * scale, y: frame.minY - 7 * scale, width: side, height: side)
    context.setFillColor(style.labelChipFill)
    context.fillEllipse(in: circle)
    context.setStrokeColor(style.panelHairline)
    context.setLineWidth(scale)
    context.strokeEllipse(in: circle.insetBy(dx: scale / 2, dy: scale / 2))
    RenderGlyph.lock.draw(in: context, rect: circle.insetBy(dx: side * 0.24, dy: side * 0.24), color: style.menuDesc)
  }
}

extension CGContext {
  /// Draw `image` upright into `rect` in the renderer's y-down space.
  func drawUpright(_ image: CGImage, in rect: CGRect) {
    saveGState()
    translateBy(x: 0, y: rect.minY + rect.maxY)
    scaleBy(x: 1, y: -1)
    draw(image, in: rect)
    restoreGState()
  }
}

extension RenderStyle {
  private static var cached: (key: String, style: RenderStyle)?
  private static var observers: [NSObjectProtocol] = []

  /// The style for the active theme and typography, rebuilt only when one of them changes.
  @MainActor
  static var current: RenderStyle {
    if observers.isEmpty {
      // The Bonsai themes take the system accent, which can change under us.
      observers.append(NotificationCenter.default.addObserver(
        forName: NSColor.systemColorsDidChangeNotification, object: nil, queue: .main) { _ in
          MainActor.assumeIsolated { cached = nil }
        })
    }
    let key = "\(ComposerPreferences.effectiveTheme.rawValue)|\(ComposerPreferences.appFontFamily.rawValue)|\(ComposerPreferences.editorFontSize)"
    if let cached, cached.key == key { return cached.style }
    let style = RenderStyle()
    cached = (key, style)
    return style
  }
}
