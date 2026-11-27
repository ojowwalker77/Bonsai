import AppKit
import CoreText

/// Attributes the renderer's text layout understands beyond Core Text's own.
enum RenderTextAttribute {
  static let font = NSAttributedString.Key(kCTFontAttributeName as String)
  static let color = NSAttributedString.Key(kCTForegroundColorAttributeName as String)
  /// `true` strikes the run through at its x-height.
  static let strikethrough = NSAttributedString.Key("BonsaiRenderStrikethrough")
  /// A `CGColor` chip painted behind the run (inline code).
  static let background = NSAttributedString.Key("BonsaiRenderBackground")
  /// Marks the stand-in character for an inline image placeholder.
  static let inlineImage = NSAttributedString.Key("BonsaiRenderInlineImage")
}

/// A block of text laid out once with Core Text and drawn at any zoom by the context's transform.
///
/// Immutable and built only from Core Text / Core Graphics values, so it is safe to create and
/// draw off the main thread. Coordinates are the renderer's y-down space: `draw` takes the
/// block's top-left corner.
struct TextLayout: @unchecked Sendable {
  enum Alignment { case leading, center, trailing }

  struct Line {
    let line: CTLine
    /// Offset of the line's left edge inside the block.
    let x: CGFloat
    /// Baseline, measured down from the block's top.
    let baseline: CGFloat
    let ascent: CGFloat
    let descent: CGFloat
    let width: CGFloat
    let decorated: Bool
  }

  let lines: [Line]
  /// The widest line by the summed line heights.
  let size: CGSize

  static let empty = TextLayout(lines: [], size: .zero)

  init(lines: [Line], size: CGSize) {
    self.lines = lines
    self.size = size
  }

  /// - Parameters:
  ///   - width: the wrap width; lines also align within it.
  ///   - maxLines: 0 for unlimited; otherwise the last line truncates with an ellipsis.
  ///   - lineSpacing: extra leading between lines (not after the last).
  init(_ string: NSAttributedString,
       width: CGFloat,
       maxLines: Int = 0,
       alignment: Alignment = .leading,
       lineSpacing: CGFloat = 0) {
    let length = string.length
    guard length > 0 else {
      self.init(lines: [], size: .zero)
      return
    }
    let wrap = max(width, 1)
    let typesetter = CTTypesetterCreateWithAttributedString(string)
    let decorated = Self.hasDecorations(string)
    var built: [(line: CTLine, ascent: CGFloat, descent: CGFloat, leading: CGFloat, width: CGFloat)] = []
    var start = 0
    while start < length {
      var count = CTTypesetterSuggestLineBreak(typesetter, start, Double(wrap))
      if count <= 0 { count = length - start }
      var line = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: count))
      let isLastAllowed = maxLines > 0 && built.count == maxLines - 1
      if isLastAllowed, start + count < length {
        // Truncate what remains of this paragraph into the final visible line.
        let rest = (string.string as NSString).substring(from: start) as NSString
        let paragraphEnd = rest.rangeOfCharacter(from: .newlines).location
        let restLength = paragraphEnd == NSNotFound ? rest.length : paragraphEnd
        let full = CTTypesetterCreateLine(typesetter, CFRange(location: start, length: max(restLength, 1)))
        let tokenAttributes = string.attributes(at: min(start + count - 1, length - 1), effectiveRange: nil)
        let token = CTLineCreateWithAttributedString(NSAttributedString(string: "…", attributes: tokenAttributes))
        line = CTLineCreateTruncatedLine(full, Double(wrap), .end, token) ?? line
        count = length - start
      }
      var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
      let typographic = CGFloat(CTLineGetTypographicBounds(line, &ascent, &descent, &leading))
      let visible = typographic - CGFloat(CTLineGetTrailingWhitespaceWidth(line))
      built.append((line, ascent, descent, leading, max(visible, 0)))
      start += count
      if isLastAllowed { break }
    }
    // A trailing newline opens one more (empty) line, as TextKit measures it.
    if maxLines == 0 || built.count < maxLines,
       let last = string.string.unicodeScalars.last, CharacterSet.newlines.contains(last),
       let font = string.attribute(RenderTextAttribute.font, at: length - 1, effectiveRange: nil) {
      let ctFont = font as! CTFont
      let blank = CTLineCreateWithAttributedString(NSAttributedString(string: ""))
      built.append((blank, CTFontGetAscent(ctFont), CTFontGetDescent(ctFont), CTFontGetLeading(ctFont), 0))
    }

    var lines: [Line] = []
    lines.reserveCapacity(built.count)
    var y: CGFloat = 0
    var widest: CGFloat = 0
    for (index, item) in built.enumerated() {
      let x: CGFloat
      switch alignment {
      case .leading: x = 0
      case .center: x = (wrap - item.width) / 2
      case .trailing: x = wrap - item.width
      }
      lines.append(Line(line: item.line, x: wrap >= .greatestFiniteMagnitude / 4 ? 0 : x,
                        baseline: y + item.ascent, ascent: item.ascent, descent: item.descent,
                        width: item.width, decorated: decorated))
      widest = max(widest, item.width)
      y += item.ascent + item.descent + item.leading
      if index < built.count - 1 { y += lineSpacing }
    }
    self.init(lines: lines, size: CGSize(width: ceil(widest), height: y))
  }

  /// The block width lines were aligned within collapses to the widest line for unbounded layouts.
  func draw(in context: CGContext, at origin: CGPoint) {
    guard !lines.isEmpty else { return }
    context.saveGState()
    // The renderer's space is y-down; Core Text draws y-up, so glyphs flip around each baseline.
    context.textMatrix = CGAffineTransform(scaleX: 1, y: -1)
    for line in lines {
      let pen = CGPoint(x: origin.x + line.x, y: origin.y + line.baseline)
      if line.decorated { drawBackgrounds(line, pen: pen, in: context) }
      context.textPosition = pen
      CTLineDraw(line.line, context)
      if line.decorated { drawOverlays(line, pen: pen, in: context) }
    }
    context.restoreGState()
  }

  /// Each line as a soft bar — what text reads as once it is too small to resolve.
  func drawGreeked(in context: CGContext, at origin: CGPoint, color: CGColor) {
    context.setFillColor(color.alpha(0.35))
    for line in lines where line.width > 0 {
      context.fill(CGRect(x: origin.x + line.x, y: origin.y + line.baseline - line.ascent * 0.62,
                          width: line.width, height: line.ascent * 0.5))
    }
  }

  private static func hasDecorations(_ string: NSAttributedString) -> Bool {
    var found = false
    string.enumerateAttributes(in: NSRange(location: 0, length: string.length)) { attributes, _, stop in
      if attributes[RenderTextAttribute.strikethrough] != nil
          || attributes[RenderTextAttribute.background] != nil
          || attributes[RenderTextAttribute.inlineImage] != nil {
        found = true
        stop.pointee = true
      }
    }
    return found
  }

  private func forEachRun(_ line: Line, pen: CGPoint,
                          _ body: (_ attributes: NSDictionary, _ x: CGFloat, _ width: CGFloat,
                                   _ ascent: CGFloat, _ descent: CGFloat) -> Void) {
    let runs = CTLineGetGlyphRuns(line.line) as! [CTRun]
    for run in runs {
      guard CTRunGetGlyphCount(run) > 0 else { continue }
      var position = CGPoint.zero
      CTRunGetPositions(run, CFRange(location: 0, length: 1), &position)
      var ascent: CGFloat = 0, descent: CGFloat = 0
      let width = CGFloat(CTRunGetTypographicBounds(run, CFRange(location: 0, length: 0), &ascent, &descent, nil))
      body(CTRunGetAttributes(run) as NSDictionary, pen.x + position.x, width, ascent, descent)
    }
  }

  private func drawBackgrounds(_ line: Line, pen: CGPoint, in context: CGContext) {
    forEachRun(line, pen: pen) { attributes, x, width, ascent, descent in
      guard let value = attributes[RenderTextAttribute.background] else { return }
      context.setFillColor(value as! CGColor)
      let chip = CGRect(x: x - 1, y: pen.y - ascent, width: width + 2, height: ascent + descent)
      context.addPath(CGPath(roundedRect: chip, cornerWidth: 3, cornerHeight: 3, transform: nil))
      context.fillPath()
    }
  }

  private func drawOverlays(_ line: Line, pen: CGPoint, in context: CGContext) {
    forEachRun(line, pen: pen) { attributes, x, width, ascent, descent in
      if attributes[RenderTextAttribute.strikethrough] != nil,
         let font = attributes[RenderTextAttribute.font] {
        let ctFont = font as! CTFont
        let color = attributes[RenderTextAttribute.color].map { $0 as! CGColor }
        if let color { context.setStrokeColor(color) }
        context.setLineWidth(max(CTFontGetSize(ctFont) / 15, 0.75))
        context.setLineCap(.butt)
        let y = pen.y - CTFontGetXHeight(ctFont) / 2
        context.move(to: CGPoint(x: x, y: y))
        context.addLine(to: CGPoint(x: x + width, y: y))
        context.strokePath()
      }
      if attributes[RenderTextAttribute.inlineImage] != nil {
        let color = attributes[RenderTextAttribute.color].map { $0 as! CGColor }
        let box = CGRect(x: x + width * 0.08, y: pen.y - ascent * 0.92, width: width * 0.84, height: ascent * 0.92)
        RenderGlyph.photo.draw(in: context, rect: box, color: color ?? CGColor(gray: 0.5, alpha: 1))
      }
    }
  }
}

extension NSAttributedString {
  /// A single-style run in the renderer's attribute vocabulary.
  convenience init(render string: String, font: CTFont, color: CGColor) {
    self.init(string: string, attributes: [RenderTextAttribute.font: font, RenderTextAttribute.color: color])
  }
}

/// Reserves a box in a line for an inline image placeholder (the glyph itself is drawn by
/// `TextLayout`). Core Text keeps the delegate alive through the attributed string.
enum InlineImageRun {
  private final class Metrics {
    let size: CGFloat
    init(size: CGFloat) { self.size = size }
  }

  static func attributes(fontSize: CGFloat, font: CTFont, color: CGColor) -> [NSAttributedString.Key: Any] {
    var callbacks = CTRunDelegateCallbacks(
      version: kCTRunDelegateCurrentVersion,
      dealloc: { Unmanaged<Metrics>.fromOpaque($0).release() },
      getAscent: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().size * 0.9 },
      getDescent: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().size * 0.12 },
      getWidth: { Unmanaged<Metrics>.fromOpaque($0).takeUnretainedValue().size * 1.35 })
    let reference = Unmanaged.passRetained(Metrics(size: fontSize)).toOpaque()
    var attributes: [NSAttributedString.Key: Any] = [
      RenderTextAttribute.font: font,
      RenderTextAttribute.color: color,
      RenderTextAttribute.inlineImage: true,
    ]
    if let delegate = CTRunDelegateCreate(&callbacks, reference) {
      attributes[NSAttributedString.Key(kCTRunDelegateAttributeName as String)] = delegate
    }
    return attributes
  }
}

extension MarkdownStyle {
  private static let imagePlaceholder = try? NSRegularExpression(pattern: "\\[image:[^\\]]*\\]")

  /// The static render of a text element for the board renderer: styled, with the syntax hidden —
  /// `**bold**` shows as bold, headings lose their hashes, `- ` becomes a bullet — and per-range
  /// ink applied. The Core Text twin of the editor styling above; same span scanner, same roles.
  static func renderedAttributedString(_ text: String,
                                       ink: [InkRun],
                                       fontSize: CGFloat,
                                       baseColor: CGColor,
                                       style: RenderStyle) -> NSAttributedString {
    let base = style.font(fontSize)
    let result = NSMutableAttributedString(
      string: text, attributes: [RenderTextAttribute.font: base, RenderTextAttribute.color: baseColor])
    let length = result.length
    let spans = spans(in: text)

    for span in spans where span.range.location + span.range.length <= length && span.range.length > 0 {
      var attributes: [NSAttributedString.Key: Any] = [:]
      switch span.kind {
      case .heading(let level):
        let scale: CGFloat = level == 1 ? 1.5 : (level == 2 ? 1.28 : 1.14)
        attributes[RenderTextAttribute.font] = style.font((fontSize * scale).rounded(), weight: level == 1 ? .bold : .semibold)
      case .marker:
        attributes[RenderTextAttribute.color] = style.markerDim
      case .bold:
        attributes[RenderTextAttribute.font] = style.font(fontSize, weight: .bold)
      case .italic:
        attributes[RenderTextAttribute.font] = style.font(fontSize, italic: true)
      case .code:
        attributes[RenderTextAttribute.font] = style.monospacedFont(max(fontSize - 1, 9))
        attributes[RenderTextAttribute.background] = style.codeChip
      case .quote:
        attributes[RenderTextAttribute.color] = style.menuDesc
        attributes[RenderTextAttribute.font] = style.font(fontSize, italic: true)
      case .listMarker, .checkboxTodo:
        attributes[RenderTextAttribute.color] = style.menuDesc
      case .checkboxDone:
        attributes[RenderTextAttribute.color] = style.accent
      case .doneText:
        attributes[RenderTextAttribute.color] = style.placeholder
        attributes[RenderTextAttribute.strikethrough] = true
      }
      result.addAttributes(attributes, range: span.range)
    }

    // Ink is stored in serialized offsets — the same space as the spans — and wins over markdown
    // colors. Applied before the syntax is removed so the color rides the surviving characters.
    for run in ink {
      guard let color = style.tint(run.slot) else { continue }
      let start = max(run.loc, 0), end = min(run.loc + run.len, length)
      guard end > start else { continue }
      result.addAttribute(RenderTextAttribute.color, value: color, range: NSRange(location: start, length: end - start))
    }

    // Hide or replace syntax, last edit first so earlier offsets stay valid.
    var edits: [(range: NSRange, replacement: NSAttributedString?)] = []
    let ns = text as NSString
    for span in spans where span.range.location + span.range.length <= length && span.range.length > 0 {
      switch span.kind {
      case .marker:
        edits.append((span.range, nil))
      case .listMarker:
        guard let first = ns.substring(with: span.range).first, "-*+".contains(first) else { continue }
        let isCheckboxRow = spans.contains {
          ($0.kind == .checkboxTodo || $0.kind == .checkboxDone)
            && $0.range.location >= span.range.location
            && $0.range.location <= span.range.location + span.range.length + 4
        }
        edits.append((span.range, isCheckboxRow ? nil : Self.replacement("•  ", in: result, at: span.range)))
      case .checkboxTodo:
        edits.append((span.range, Self.replacement("☐", in: result, at: span.range)))
      case .checkboxDone:
        edits.append((span.range, Self.replacement("☑", in: result, at: span.range)))
      default:
        break
      }
    }
    if let regex = imagePlaceholder {
      for match in regex.matches(in: text, range: NSRange(location: 0, length: length)) {
        let attributes = InlineImageRun.attributes(fontSize: fontSize, font: base, color: style.placeholder)
        edits.append((match.range, NSAttributedString(string: "\u{FFFC}", attributes: attributes)))
      }
    }
    for edit in edits.sorted(by: { $0.range.location > $1.range.location }) {
      guard edit.range.location + edit.range.length <= result.length else { continue }
      if let replacement = edit.replacement {
        result.replaceCharacters(in: edit.range, with: replacement)
      } else {
        result.deleteCharacters(in: edit.range)
      }
    }
    return result
  }

  private static func replacement(_ string: String, in source: NSAttributedString, at range: NSRange) -> NSAttributedString {
    NSAttributedString(string: string, attributes: source.attributes(at: range.location, effectiveRange: nil))
  }
}
