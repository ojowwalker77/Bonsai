import AppKit
import CoreText

// The structured element kinds: sticky notes, checklists, tables, images, equations and graphs.
// Every cached layout here is in CARD-LOCAL coordinates (origin at the frame's top-left), so an
// element that only moves keeps its layout.

extension RenderElement {
  /// A path held in a typed box (Core Foundation types cannot be told apart by a cast).
  struct PathBox: @unchecked Sendable {
    let path: CGPath
  }

  // MARK: Sticky note

  private struct StickyLayout: @unchecked Sendable {
    var title: TextLayout
    var body: TextLayout
    var dividerY: CGFloat
    var bodyY: CGFloat
  }

  func drawSticky(in context: CGContext, environment: RenderEnvironment) {
    let radius = min(14, frame.width / 2, frame.height / 2)
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    withShadow(context, environment, radius: 8, y: 3, opacity: 0.45) { context in
      context.addPath(shape)
      context.setFillColor((tint ?? style.stickyBase).alpha(style.isDark ? 0.22 : 0.20))
      context.fillPath()
    }
    strokeBorder(frame, radius: radius, color: style.body.alpha(style.isDark ? 0.12 : 0.08), width: 1, in: context)

    let inset: CGFloat = 18
    let wrap = max(frame.width - inset * 2, 20)
    let title = (card.stickyTitle ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    let body = trimmedText
    context.saveGState()
    defer { context.restoreGState() }
    context.addPath(shape)
    context.clip()
    context.translateBy(x: frame.minX, y: frame.minY)

    if environment.greeks(fontSize: 15) {
      context.setFillColor(style.body.alpha(0.3))
      context.fill(CGRect(x: inset, y: inset + 4, width: min(wrap, 110), height: 9))
      var y = inset + 46
      while y + 7 < frame.height - inset, y < inset + 46 + 22 * 5 {
        context.fill(CGRect(x: inset, y: y, width: wrap * (y.truncatingRemainder(dividingBy: 44) < 22 ? 1 : 0.72), height: 7))
        y += 22
      }
      return
    }

    let layout: StickyLayout = prepared {
      let titleLayout = TextLayout(
        NSAttributedString(render: title.isEmpty ? "Untitled note".localizedUI : (self.card.stickyTitle ?? ""),
                           font: self.style.font(18, weight: .semibold),
                           color: title.isEmpty ? self.style.placeholder : self.style.body),
        width: wrap, maxLines: 2)
      let dividerY = inset + titleLayout.size.height + 12
      let bodyY = dividerY + 0.75 + 12
      let string = NSAttributedString(render: body.isEmpty ? "Write something…".localizedUI : self.text,
                                      font: self.style.font(15),
                                      color: body.isEmpty ? self.style.placeholder : self.style.body.alpha(0.88))
      var bodyLayout = TextLayout(string, width: wrap, lineSpacing: 3)
      let available = self.frame.height - inset - bodyY
      if bodyLayout.size.height > available + 1 {
        // The note is the boundary: keep the lines that fit and end the last one with an ellipsis.
        let fitting = bodyLayout.lines.prefix { $0.baseline + $0.descent <= available + 1 }.count
        bodyLayout = TextLayout(string, width: wrap, maxLines: max(fitting, 1), lineSpacing: 3)
      }
      return StickyLayout(title: titleLayout, body: bodyLayout, dividerY: dividerY, bodyY: bodyY)
    }
    layout.title.draw(in: context, at: CGPoint(x: inset, y: inset))
    context.setFillColor(style.body.alpha(0.13))
    context.fill(CGRect(x: inset, y: layout.dividerY, width: wrap, height: 0.75))
    layout.body.draw(in: context, at: CGPoint(x: inset, y: layout.bodyY))
  }

  /// A 1-unit border drawn fully inside `rect` (SwiftUI's `strokeBorder`).
  func strokeBorder(_ rect: CGRect, radius: CGFloat, color: CGColor, width: CGFloat,
                    dash: [CGFloat] = [], in context: CGContext) {
    let inner = rect.insetBy(dx: width / 2, dy: width / 2)
    guard inner.width > 0, inner.height > 0 else { return }
    let r = max(min(radius - width / 2, inner.width / 2, inner.height / 2), 0)
    context.saveGState()
    context.addPath(CGPath(roundedRect: inner, cornerWidth: r, cornerHeight: r, transform: nil))
    context.setStrokeColor(color)
    context.setLineWidth(width)
    if !dash.isEmpty { context.setLineDash(phase: 0, lengths: dash) }
    context.strokePath()
    context.restoreGState()
  }

  // MARK: Checklist

  struct ChecklistLayout: @unchecked Sendable {
    struct Row {
      var layout: TextLayout
      var origin: CGPoint
      var box: CGRect
      var checked: Bool
    }
    var rows: [Row]
    /// Checkbox rects by item index, card-local.
    var checkboxFrames: [Int: CGRect]
  }

  static func checklistLayout(items: [CardState.ChecklistItem], width: CGFloat, style: RenderStyle) -> ChecklistLayout {
    let inset: CGFloat = 16, box: CGFloat = 16, gap: CGFloat = 9
    let wrap = max(width - inset * 2 - box - gap, 20)
    let font = style.font(15)
    var rows: [ChecklistLayout.Row] = []
    var frames: [Int: CGRect] = [:]
    var y = inset
    for (index, item) in items.enumerated() {
      var attributes: [NSAttributedString.Key: Any] = [
        RenderTextAttribute.font: font,
        RenderTextAttribute.color: item.isChecked ? style.menuDesc : style.body,
      ]
      if item.isChecked { attributes[RenderTextAttribute.strikethrough] = true }
      let layout = TextLayout(NSAttributedString(string: item.text, attributes: attributes), width: wrap)
      let textHeight = max(layout.size.height, CTFontGetAscent(font) + CTFontGetDescent(font))
      let rowHeight = max(22, textHeight)
      let textY = y + (rowHeight - textHeight) / 2
      let firstLine = layout.lines.first.map { $0.ascent + $0.descent } ?? textHeight
      let frame = CGRect(x: inset, y: textY + (firstLine - box) / 2, width: box, height: box)
      frames[index] = frame
      rows.append(.init(layout: layout, origin: CGPoint(x: inset + box + gap, y: textY), box: frame, checked: item.isChecked))
      y += rowHeight + 8
    }
    return ChecklistLayout(rows: rows, checkboxFrames: frames)
  }

  func drawChecklist(in context: CGContext, environment: RenderEnvironment) {
    let radius = min(10, frame.width / 2, frame.height / 2)
    context.addPath(CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil))
    context.setFillColor(style.raisedTint)
    context.fillPath()

    let layout: ChecklistLayout = prepared {
      Self.checklistLayout(items: self.card.checklist ?? [], width: self.frame.width, style: self.style)
    }
    context.saveGState()
    defer { context.restoreGState() }
    context.clip(to: frame.insetBy(dx: 0, dy: -1))
    context.translateBy(x: frame.minX, y: frame.minY)
    let greeked = environment.greeks(fontSize: 15)
    for row in layout.rows where row.box.minY < frame.height {
      let color = row.checked ? (tint ?? style.accent) : style.menuDesc
      (row.checked ? RenderGlyph.squareChecked : .square).draw(in: context, rect: row.box, color: color)
      if greeked {
        row.layout.drawGreeked(in: context, at: row.origin, color: row.checked ? style.menuDesc : style.body)
      } else {
        row.layout.draw(in: context, at: row.origin)
      }
    }
  }

  // MARK: Table

  static let tableHeaderHeight: CGFloat = 40
  static let tableRowHeight: CGFloat = 38

  /// A table draws at its natural height (header + rows), top-aligned in its frame.
  static func tableHeight(_ spec: CardState.TableSpec) -> CGFloat {
    tableHeaderHeight + tableRowHeight * CGFloat(spec.rows.count)
  }

  private struct TableLayout: @unchecked Sendable {
    var cells: [(layout: TextLayout, origin: CGPoint)]
  }

  func drawTable(in context: CGContext, environment: RenderEnvironment) {
    let spec = card.table ?? CardState.TableSpec()
    let columns = spec.columns.count
    guard columns > 0 else { return }
    let height = Self.tableHeight(spec)
    let rect = CGRect(x: frame.minX, y: frame.minY, width: frame.width, height: height)
    let radius = min(10, rect.width / 2, rect.height / 2)
    let shape = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let columnWidth = rect.width / CGFloat(columns)

    withShadow(context, environment, radius: 6, y: 2, opacity: 0.28) { context in
      context.addPath(shape)
      context.setFillColor(style.raisedTint.alpha(0.72))
      context.fillPath()
    }

    context.saveGState()
    context.addPath(shape)
    context.clip()
    context.translateBy(x: rect.minX, y: rect.minY)
    context.setFillColor((tint ?? style.accent).alpha(style.isDark ? 0.16 : 0.10))
    context.fill(CGRect(x: 0, y: 0, width: rect.width, height: Self.tableHeaderHeight))
    context.setFillColor(style.body.alpha(style.isDark ? 0.025 : 0.018))
    for row in spec.rows.indices where row.isMultiple(of: 2) {
      context.fill(CGRect(x: 0, y: Self.tableHeaderHeight + Self.tableRowHeight * CGFloat(row),
                          width: rect.width, height: Self.tableRowHeight))
    }
    let hair = max(0.5, environment.minimumStroke * 0.5)
    context.setFillColor(style.separator.alpha(0.55))
    for row in 0...spec.rows.count {
      let bottom = Self.tableHeaderHeight + Self.tableRowHeight * CGFloat(row)
      context.fill(CGRect(x: 0, y: bottom - hair, width: rect.width, height: hair))
    }
    context.setFillColor(style.separator.alpha(0.5))
    for column in 1..<max(columns, 1) {
      context.fill(CGRect(x: columnWidth * CGFloat(column) - hair, y: 0, width: hair, height: height))
    }

    if !environment.greeks(fontSize: 13) {
      let layout: TableLayout = prepared {
        var cells: [(layout: TextLayout, origin: CGPoint)] = []
        let wrap = max(columnWidth - 24, 8)
        func add(_ value: String, column: Int, top: CGFloat, rowHeight: CGFloat, header: Bool) {
          guard !value.isEmpty else { return }
          let font = self.style.font(header ? 12.5 : 13, weight: header ? .semibold : .regular)
          let color = header ? (self.tint ?? self.style.body) : self.style.body.alpha(0.88)
          let text = TextLayout(NSAttributedString(render: value, font: font, color: color), width: wrap, maxLines: 2)
          cells.append((text, CGPoint(x: columnWidth * CGFloat(column) + 12, y: top + (rowHeight - text.size.height) / 2)))
        }
        for (column, name) in spec.columns.enumerated() {
          add(name.isEmpty ? "Column \(column + 1)" : name, column: column, top: 0,
              rowHeight: Self.tableHeaderHeight, header: true)
        }
        for (rowIndex, row) in spec.rows.enumerated() {
          for (column, value) in row.prefix(columns).enumerated() {
            add(value, column: column, top: Self.tableHeaderHeight + Self.tableRowHeight * CGFloat(rowIndex),
                rowHeight: Self.tableRowHeight, header: false)
          }
        }
        return TableLayout(cells: cells)
      }
      for cell in layout.cells { cell.layout.draw(in: context, at: cell.origin) }
    }
    context.restoreGState()
    strokeBorder(rect, radius: radius, color: style.panelHairline, width: 1, in: context)
  }

  // MARK: Image

  func drawImage(in context: CGContext, environment: RenderEnvironment) {
    let radius = min(8, frame.width / 2, frame.height / 2)
    let shape = CGPath(roundedRect: frame, cornerWidth: radius, cornerHeight: radius, transform: nil)
    let needed = max(frame.width, frame.height) * environment.pixelScale

    if let path = card.imagePath, let image = environment.images.image(for: path, minPixelSize: needed) {
      shadowOnly(of: shape, in: context, environment, radius: 10, y: 4, opacity: 0.18)
      context.saveGState()
      context.addPath(shape)
      context.clip()
      let scale = max(frame.width / CGFloat(image.width), frame.height / CGFloat(image.height))
      let size = CGSize(width: CGFloat(image.width) * scale, height: CGFloat(image.height) * scale)
      context.interpolationQuality = .medium
      context.drawUpright(image, in: CGRect(x: frame.midX - size.width / 2, y: frame.midY - size.height / 2,
                                            width: size.width, height: size.height))
      context.restoreGState()
      strokeBorder(frame, radius: radius, color: style.panelHairline, width: 1, in: context)
    } else {
      if let fill = style.elementFill {
        withShadow(context, environment, radius: 10, y: 4, opacity: 0.18) { context in
          context.addPath(shape)
          context.setFillColor(fill)
          context.fillPath()
        }
      }
      strokeBorder(frame, radius: radius, color: style.chromeDivider, width: 1.5, dash: [6, 5], in: context)
      if frame.width > 44, frame.height > 44 {
        let name = card.imagePath.map { ($0 as NSString).lastPathComponent } ?? "Image".localizedUI
        let caption: TextLayout = prepared {
          TextLayout(NSAttributedString(render: name, font: self.style.systemFont(10, weight: .medium), color: self.style.chromeText),
                     width: max(self.frame.width - 20, 10), maxLines: 1, alignment: .center)
        }
        let showsCaption = frame.height > 76 && !environment.greeks(fontSize: 10)
        let stack = 24 + (showsCaption ? 8 + caption.size.height : 0)
        let top = frame.midY - stack / 2
        RenderGlyph.photo.draw(in: context, rect: CGRect(x: frame.midX - 15, y: top, width: 30, height: 24), color: style.chromeText)
        if showsCaption {
          caption.draw(in: context, at: CGPoint(x: frame.minX + 10, y: top + 32))
        }
      }
    }

    if let understanding = card.imageUnderstanding, !understanding.isEmpty, frame.width > 48, frame.height > 48 {
      // Read on-device: this screenshot's text reaches agents over the canvas API.
      let badge = CGRect(x: frame.maxX - 6 - 23, y: frame.maxY - 6 - 23, width: 23, height: 23)
      context.setFillColor(style.labelChipFill)
      context.fillEllipse(in: badge)
      RenderGlyph.viewfinder.draw(in: context, rect: badge.insetBy(dx: 5.5, dy: 5.5), color: style.menuDesc)
    }
  }

  /// Cast `shape`'s shadow without painting the shape itself — for content (an image) that is
  /// drawn separately on top and may be translucent.
  func shadowOnly(of shape: CGPath, in context: CGContext, _ environment: RenderEnvironment,
                  radius: CGFloat, y: CGFloat, opacity: CGFloat) {
    guard style.elementShadow != nil, environment.drawsShadows else { return }
    context.saveGState()
    context.addRect(paintBounds)
    context.addPath(shape)
    context.clip(using: .evenOdd)
    withShadow(context, environment, radius: radius, y: y, opacity: opacity) { context in
      context.addPath(shape)
      context.setFillColor(style.canvas)
      context.fillPath()
    }
    context.restoreGState()
  }

  // MARK: Equation

  func drawEquation(in context: CGContext, environment: RenderEnvironment) {
    let latex = (card.latex ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
    if latex.isEmpty {
      // An empty equation awaiting input — same weight as the text element's hint.
      guard !environment.greeks(fontSize: style.bodyFontSize) else { return }
      let hint: TextLayout = prepared {
        TextLayout(NSAttributedString(render: "E = mc\u{00B2}", font: self.style.systemFont(self.style.bodyFontSize),
                                      color: self.style.placeholder),
                   width: .greatestFiniteMagnitude, maxLines: 1)
      }
      hint.draw(in: context, at: CGPoint(x: frame.midX - hint.size.width / 2, y: frame.midY - hint.size.height / 2))
      return
    }

    let ink = tint ?? style.body
    let available = frame.width > 28 && frame.height > 28 ? frame.insetBy(dx: 10, dy: 10) : frame
    if let natural = EquationRaster.naturalSize(latex: latex, color: ink), natural.width > 0, natural.height > 0 {
      let fit = min(available.width / natural.width, available.height / natural.height)
      let size = CGSize(width: natural.width * fit, height: natural.height * fit)
      let target = CGRect(x: available.midX - size.width / 2, y: available.midY - size.height / 2,
                          width: size.width, height: size.height)
      if let image = EquationRaster.image(latex: latex, color: ink, pixelsPerPoint: fit * environment.pixelScale) {
        context.interpolationQuality = .high
        context.drawUpright(image, in: target)
      }
      return
    }

    // Unparseable source: show it raw (never blank) beside a warning glyph.
    guard !environment.greeks(fontSize: 12) else { return }
    let source: TextLayout = prepared {
      TextLayout(NSAttributedString(render: latex, font: self.style.monospacedFont(12), color: self.style.placeholder),
                 width: max(self.frame.width - 20 - 16, 20), maxLines: 3)
    }
    let width = 12 + 4 + source.size.width
    let left = frame.midX - width / 2
    let top = frame.midY - source.size.height / 2
    RenderGlyph.warning.draw(in: context, rect: CGRect(x: left, y: top + 1.5, width: 12, height: 12), color: style.placeholder)
    source.draw(in: context, at: CGPoint(x: left + 16, y: top))
  }

  // MARK: Graph

  private struct GraphLayout: @unchecked Sendable {
    var geometry: GraphGeometry
    var grid: CGPath
    var axes: CGPath
    var ticks: CGPath
    var labels: [(layout: TextLayout, origin: CGPoint, minimumFont: CGFloat)]
    var curves: [(path: CGPath, color: CGColor)]
    var markers: [(center: CGPoint, color: CGColor, diameter: CGFloat, label: TextLayout?)]
    var legend: [(swatch: CGRect, color: CGColor, layout: TextLayout, origin: CGPoint)]
  }

  private func graphLayout(_ spec: CardState.GraphSpec, size: CGSize) -> GraphLayout {
    let geometry = GraphGeometry(spec: spec, size: size)
    let plot = geometry.plot
    let origin = CGPoint(x: plot.minX, y: plot.maxY)
    let head: CGFloat = 15, tick: CGFloat = 4
    let xTicks = GraphCardView.niceTicks(min: geometry.xMin, max: geometry.xMax)
    let yTicks = GraphCardView.niceTicks(min: geometry.yMin, max: geometry.yMax)

    let grid = CGMutablePath()
    let ticks = CGMutablePath()
    var labels: [(layout: TextLayout, origin: CGPoint, minimumFont: CGFloat)] = []
    let tickFont = style.monospacedFont(9)
    for value in xTicks {
      let x = geometry.viewX(value)
      grid.move(to: CGPoint(x: x, y: plot.minY))
      grid.addLine(to: CGPoint(x: x, y: plot.maxY))
      // Ticks yield to the arrowheads: one that would land under a head is skipped.
      guard x <= plot.maxX - head - 6 else { continue }
      ticks.move(to: CGPoint(x: x, y: origin.y))
      ticks.addLine(to: CGPoint(x: x, y: origin.y + tick))
      let text = TextLayout(NSAttributedString(render: GraphCardView.tickText(value), font: tickFont, color: style.placeholder),
                            width: .greatestFiniteMagnitude, maxLines: 1)
      labels.append((text, CGPoint(x: x - text.size.width / 2, y: origin.y + tick + 7 - text.size.height / 2), 9))
    }
    for value in yTicks {
      let y = geometry.viewY(value)
      grid.move(to: CGPoint(x: plot.minX, y: y))
      grid.addLine(to: CGPoint(x: plot.maxX, y: y))
      guard y >= plot.minY + head + 6 else { continue }
      ticks.move(to: CGPoint(x: origin.x, y: y))
      ticks.addLine(to: CGPoint(x: origin.x - tick, y: y))
      let text = TextLayout(NSAttributedString(render: GraphCardView.tickText(value), font: tickFont, color: style.placeholder),
                            width: .greatestFiniteMagnitude, maxLines: 1)
      labels.append((text, CGPoint(x: GraphGeometry.leftGutter - tick - 3 - text.size.width, y: y - text.size.height / 2), 9))
    }

    let axes = CGMutablePath()
    func arrowHead(at tip: CGPoint, angle: CGFloat) {
      for side in [CGFloat.pi * 0.82, -CGFloat.pi * 0.82] {
        axes.move(to: tip)
        axes.addLine(to: CGPoint(x: tip.x + cos(angle + side) * head, y: tip.y + sin(angle + side) * head))
      }
    }
    axes.move(to: origin)
    axes.addLine(to: CGPoint(x: plot.maxX, y: origin.y))
    arrowHead(at: CGPoint(x: plot.maxX, y: origin.y), angle: 0)
    axes.move(to: origin)
    axes.addLine(to: CGPoint(x: origin.x, y: plot.minY))
    arrowHead(at: CGPoint(x: origin.x, y: plot.minY), angle: -.pi / 2)

    // Axis titles sit in the corners the arrowheads freed up.
    let titleFont = style.systemFont(11, weight: .medium)
    let xTitle = GraphCardView.axisTitle(label: spec.xLabel, unit: spec.xUnit)
    if !xTitle.isEmpty {
      let text = TextLayout(NSAttributedString(render: xTitle, font: titleFont, color: style.body),
                            width: .greatestFiniteMagnitude, maxLines: 1)
      labels.append((text, CGPoint(x: size.width - 4 - text.size.width, y: size.height - 2 - text.size.height), 11))
    }
    let yTitle = GraphCardView.axisTitle(label: spec.yLabel, unit: spec.yUnit)
    if !yTitle.isEmpty {
      let text = TextLayout(NSAttributedString(render: yTitle, font: titleFont, color: style.body),
                            width: .greatestFiniteMagnitude, maxLines: 1)
      labels.append((text, CGPoint(x: origin.x + 14, y: plot.minY - 8), 11))
    }

    var curves: [(path: CGPath, color: CGColor)] = []
    var markers: [(center: CGPoint, color: CGColor, diameter: CGFloat, label: TextLayout?)] = []
    var legend: [(swatch: CGRect, color: CGColor, layout: TextLayout, origin: CGPoint)] = []
    let legendFont = style.monospacedFont(10)
    var legendY = plot.minY + 2
    for series in spec.series {
      // An untinted series takes the accent — "a plotted line", distinct from the axes.
      let color = style.tint(series.tint) ?? style.accent
      if let latex = series.expression?.trimmingCharacters(in: .whitespacesAndNewlines), !latex.isEmpty,
         let expression = GraphExpressionCache.expression(for: latex) {
        // Sample across the plot; break the stroke at a non-finite value or one far beyond either
        // edge, so an asymptote does not draw a vertical spike across the card.
        let path = CGMutablePath()
        var started = false
        var x = plot.minX
        while x <= plot.maxX {
          let value = expression.evaluate(geometry.dataX(x))
          let y = geometry.viewY(value)
          if !value.isFinite || y < plot.minY - plot.height || y > plot.maxY + plot.height {
            started = false
          } else if started {
            path.addLine(to: CGPoint(x: x, y: y))
          } else {
            path.move(to: CGPoint(x: x, y: y))
            started = true
          }
          x += 1
        }
        curves.append((path, color))
      }
      for point in series.points ?? [] {
        let pointColor = style.tint(point.tint) ?? color
        if point.label.isEmpty {
          markers.append((geometry.viewPoint(point), pointColor, 11, nil))
        } else {
          let diameter = max(28, CGFloat(point.label.count) * 8 + 14)
          let text = TextLayout(NSAttributedString(render: point.label, font: style.systemFont(12, weight: .medium), color: style.body),
                                width: diameter - 8, maxLines: 1, alignment: .center)
          markers.append((geometry.viewPoint(point), pointColor, diameter, text))
        }
      }
      let text = TextLayout(NSAttributedString(render: GraphFormat.legendText(series.label), font: legendFont, color: style.placeholder),
                            width: .greatestFiniteMagnitude, maxLines: 1)
      let rowHeight = max(text.size.height, 12)
      let right = size.width - GraphGeometry.rightGutter - 4
      let textX = right - text.size.width
      legend.append((CGRect(x: textX - 5 - 14, y: legendY + rowHeight / 2 - 1, width: 14, height: 2), color,
                     text, CGPoint(x: textX, y: legendY + (rowHeight - text.size.height) / 2)))
      legendY += rowHeight + 3
    }
    return GraphLayout(geometry: geometry, grid: grid, axes: axes, ticks: ticks, labels: labels,
                       curves: curves, markers: markers, legend: legend)
  }

  func drawGraph(in context: CGContext, environment: RenderEnvironment) {
    let spec = card.graph ?? CardState.GraphSpec()
    let size = CGSize(width: frame.width - 4, height: frame.height - 4)
    guard size.width > 1, size.height > 1 else { return }
    let layout: GraphLayout = prepared { self.graphLayout(spec, size: size) }
    let plot = layout.geometry.plot
    let stroke = tint ?? style.elementStroke

    context.saveGState()
    context.translateBy(x: frame.minX + 2, y: frame.minY + 2)

    // While a parseable equation hovers this graph the plot lightens: "release here".
    if variant.isDropTarget, let fill = style.elementFill {
      context.setFillColor(fill.alpha(0.5))
      context.fill(plot)
    }
    if spec.showGrid {
      context.saveGState()
      context.clip(to: CGRect(origin: .zero, size: size))
      context.addPath(layout.grid)
      context.setStrokeColor(style.panelHairline)
      context.setLineWidth(strokeWidth(1, environment))
      context.strokePath()
      context.restoreGState()
    }
    context.setLineCap(.round)
    context.setLineJoin(.round)
    withShadow(context, environment, radius: 6, y: 3) { context in
      context.setLineCap(.round)
      context.setLineJoin(.round)
      context.addPath(layout.axes)
      context.setStrokeColor(stroke)
      context.setLineWidth(strokeWidth(3, environment))
      context.strokePath()
    }
    context.addPath(layout.ticks)
    context.setStrokeColor(stroke)
    context.setLineWidth(1.5)
    context.strokePath()

    for label in layout.labels where !environment.greeks(fontSize: label.minimumFont) {
      label.layout.draw(in: context, at: label.origin)
    }

    if !layout.curves.isEmpty {
      context.saveGState()
      context.clip(to: plot)
      context.setLineWidth(strokeWidth(2, environment))
      for curve in layout.curves {
        context.addPath(curve.path)
        context.setStrokeColor(curve.color)
        context.strokePath()
      }
      context.restoreGState()
    }
    for marker in layout.markers {
      let circle = CGRect(x: marker.center.x - marker.diameter / 2, y: marker.center.y - marker.diameter / 2,
                          width: marker.diameter, height: marker.diameter)
      if let label = marker.label {
        if let fill = style.elementFill {
          context.setFillColor(fill)
          context.fillEllipse(in: circle)
        }
        context.setStrokeColor(marker.color)
        context.setLineWidth(2)
        context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        if !environment.greeks(fontSize: 12) {
          label.draw(in: context, at: CGPoint(x: circle.minX + 4, y: circle.midY - label.size.height / 2))
        }
      } else {
        context.setFillColor(marker.color)
        context.fillEllipse(in: circle)
        if let ring = style.elementFill {
          context.setStrokeColor(ring)
          context.setLineWidth(2)
          context.strokeEllipse(in: circle.insetBy(dx: 1, dy: 1))
        }
      }
    }
    // A selected graph's interactive overlay draws the ✕-bearing legend instead.
    if !variant.hidesLegend, !environment.greeks(fontSize: 10) {
      for row in layout.legend {
        context.setFillColor(row.color)
        context.addPath(CGPath(roundedRect: row.swatch, cornerWidth: 1, cornerHeight: 1, transform: nil))
        context.fillPath()
        row.layout.draw(in: context, at: row.origin)
      }
    }
    context.restoreGState()

    if variant.isDropTarget {
      strokeBorder(frame.insetBy(dx: 1, dy: 1), radius: SelectionChrome.cornerRadius(for: .graph),
                   color: style.accent, width: 2, in: context)
    }
  }
}
