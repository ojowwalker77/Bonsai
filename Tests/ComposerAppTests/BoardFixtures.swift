import CoreGraphics
import Foundation
@testable import ComposerApp

/// Deterministic boards for render benchmarks and renderer tests: clusters of labelled shapes
/// joined by bound arrows, markdown text, freehand strokes and the occasional structured card —
/// the mix an agent-drawn diagram plus some hand sketching actually produces.
enum BoardFixtures {
  /// One cluster occupies a `cell`-sized square of board space; clusters tile a near-square grid.
  static let cell = CGSize(width: 620, height: 460)
  static let elementsPerCluster = 10

  static func mixedBoard(count: Int) -> [CardState] {
    var cards: [CardState] = []
    cards.reserveCapacity(count)
    let clusters = Int((Double(count) / Double(elementsPerCluster)).rounded(.up))
    let columns = max(Int(Double(clusters).squareRoot().rounded(.up)), 1)
    var z = 1
    func next() -> Int { defer { z += 1 }; return z }

    for cluster in 0..<clusters {
      let ox = Double(cluster % columns) * cell.width
      let oy = Double(cluster / columns) * cell.height
      let a = CardState(kind: .rectangle, text: "Service \(cluster)", x: ox + 20, y: oy + 20,
                        w: 180, h: 90, z: next())
      let b = CardState(kind: .ellipse, text: "Queue", x: ox + 340, y: oy + 30, w: 170, h: 90,
                        z: next(), tint: cluster % 6)
      let c = CardState(kind: .diamond, text: "Retry?", x: ox + 180, y: oy + 200, w: 200, h: 130,
                        z: next())
      var arrowAB = CardState(kind: .arrow, text: cluster % 3 == 0 ? "publishes" : "",
                              x: ox + 200, y: oy + 40, w: 140, h: 50, z: next(),
                              points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)])
      arrowAB.startBindingID = a.id
      arrowAB.endBindingID = b.id
      var arrowBC = CardState(kind: .arrow, x: ox + 300, y: oy + 120, w: 120, h: 90, z: next(),
                              points: [CanvasPoint(x: 1, y: 0), CanvasPoint(x: 0, y: 1)])
      arrowBC.startBindingID = b.id
      arrowBC.endBindingID = c.id
      let line = CardState(kind: .line, x: ox + 30, y: oy + 130, w: 120, h: 70, z: next(),
                           points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1)])
      let note = CardState(
        kind: .text,
        text: "## Cluster \(cluster)\nHandles **retries** with *backoff* and `jitter`.\n- owner: infra\n- [x] alerting wired",
        x: ox + 400, y: oy + 180, w: 200, h: 150, z: next())
      let strokeA = CardState(kind: .freehand, x: ox + 20, y: oy + 240, w: 150, h: 110, z: next(),
                              points: stroke(seed: cluster, count: 90))
      let strokeB = CardState(kind: .freehand, x: ox + 40, y: oy + 350, w: 220, h: 80, z: next(),
                              points: stroke(seed: cluster &+ 7919, count: 140), tint: (cluster + 2) % 6)
      let extra: CardState
      switch cluster % 5 {
      case 0:
        extra = CardState(kind: .sticky, text: "Check the dead-letter queue before the demo.",
                          x: ox + 400, y: oy + 345, w: 200, h: 100, z: next(), stickyTitle: "Todo")
      case 1:
        extra = CardState(kind: .checklist, x: ox + 400, y: oy + 345, w: 200, h: 100, z: next(),
                          checklist: [.init(text: "Ship", isChecked: true), .init(text: "Measure")])
      default:
        extra = CardState(kind: .text, text: "p95 latency \(120 + cluster % 40)ms",
                          x: ox + 400, y: oy + 350, w: 200, h: 50, z: next())
      }
      cards.append(contentsOf: [a, b, c, arrowAB, arrowBC, line, note, strokeA, strokeB, extra])
    }
    return Array(cards.prefix(count))
  }

  /// One of every element kind and state, laid out on a grid — the renderer's visual checklist.
  static func showcase() -> [CardState] {
    var z = 1
    func next() -> Int { defer { z += 1 }; return z }
    var cards: [CardState] = []
    cards.append(CardState(
      kind: .text,
      text: "# Heading one\n## Heading two\nPlain body with **bold**, *italic* and `code`.\n> a quoted line\n- bullet one\n- bullet two\n1. numbered\nA long paragraph that has to wrap across several lines so the wrapping and line spacing can be compared against the editor.",
      x: 20, y: 20, w: 360, h: 300, z: next()))
    cards.append(CardState(kind: .text, text: "Inked words here and tinted body", x: 400, y: 20, w: 300, h: 56, z: next(),
                           tint: 2, ink: [InkRun(loc: 0, len: 5, slot: 0), InkRun(loc: 12, len: 4, slot: 4)]))
    cards.append(CardState(kind: .text, text: "Tasks\n- [ ] write the renderer\n- [x] measure the old one\n- [ ] a task whose text is long enough that it wraps onto a second line",
                           x: 400, y: 90, w: 300, h: 150, z: next()))
    cards.append(CardState(kind: .text, text: "", x: 400, y: 250, w: 300, h: 56, z: next()))
    cards.append(CardState(kind: .text, text: "Scaled text", x: 400, y: 310, w: 300, h: 80, z: next(), fontScale: 2))

    cards.append(CardState(kind: .rectangle, text: "Rectangle", x: 740, y: 20, w: 200, h: 110, z: next()))
    cards.append(CardState(kind: .ellipse, text: "Ellipse with a longer label that wraps", x: 960, y: 20, w: 220, h: 130, z: next(), tint: 1))
    cards.append(CardState(kind: .diamond, text: "Diamond", x: 1200, y: 20, w: 200, h: 140, z: next(), tint: 3))
    cards.append(CardState(kind: .rectangle, x: 740, y: 150, w: 120, h: 80, z: next(), isLocked: true))
    cards.append(CardState(kind: .rectangle, text: "Archived", x: 880, y: 170, w: 140, h: 70, z: next(), archived: true, tint: 5))
    cards.append(CardState(kind: .arrow, text: "labelled arrow", x: 740, y: 260, w: 300, h: 60, z: next(),
                           points: [CanvasPoint(x: 0, y: 1), CanvasPoint(x: 1, y: 0)]))
    cards.append(CardState(kind: .arrow, x: 1060, y: 190, w: 160, h: 120, z: next(),
                           points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1)], tint: 0))
    cards.append(CardState(kind: .line, text: "a line", x: 1240, y: 200, w: 180, h: 90, z: next(),
                           points: [CanvasPoint(x: 0, y: 0.5), CanvasPoint(x: 1, y: 0.5)]))
    cards.append(CardState(kind: .freehand, x: 740, y: 340, w: 260, h: 90, z: next(), points: stroke(seed: 3, count: 160)))
    cards.append(CardState(kind: .freehand, x: 1020, y: 340, w: 160, h: 90, z: next(), points: stroke(seed: 9, count: 60), tint: 4))
    cards.append(CardState(
      kind: .vectorPath, x: 1200, y: 320, w: 200, h: 120, z: next(),
      vectorPath: VectorPathSpec(nodes: [
        VectorPathNode(anchor: CanvasPoint(x: 0, y: 1)),
        VectorPathNode(anchor: CanvasPoint(x: 0.5, y: 0), incoming: CanvasPoint(x: 0.2, y: 0), outgoing: CanvasPoint(x: 0.8, y: 0)),
        VectorPathNode(anchor: CanvasPoint(x: 1, y: 1)),
      ], isClosed: true),
      tint: 2))
    cards.append(CardState(
      kind: .vectorPath, x: 1200, y: 460, w: 200, h: 80, z: next(),
      vectorPath: VectorPathSpec(nodes: [
        VectorPathNode(anchor: CanvasPoint(x: 0, y: 0.5), outgoing: CanvasPoint(x: 0.25, y: -0.4)),
        VectorPathNode(anchor: CanvasPoint(x: 0.5, y: 0.5), incoming: CanvasPoint(x: 0.25, y: 1.4), outgoing: CanvasPoint(x: 0.75, y: -0.4)),
        VectorPathNode(anchor: CanvasPoint(x: 1, y: 0.5), incoming: CanvasPoint(x: 0.75, y: 1.4)),
      ])))

    cards.append(CardState(kind: .sticky, text: "Body of the sticky note, long enough to wrap and then run out of room at the bottom of the note so it has to end with an ellipsis somewhere around here.",
                           x: 20, y: 340, w: 240, h: 200, z: next(), stickyTitle: "Sticky title"))
    cards.append(CardState(kind: .sticky, x: 280, y: 420, w: 200, h: 130, z: next(), tint: 3))
    cards.append(CardState(kind: .checklist, x: 20, y: 560, w: 300, h: 180, z: next(),
                           checklist: [.init(text: "First item", isChecked: true), .init(text: "Second item"),
                                       .init(text: "A third item with enough words to wrap to a second line"),
                                       .init(text: "Done too", isChecked: true)],
                           tint: 1))
    cards.append(CardState(kind: .table, x: 340, y: 580, w: 380, h: 160, z: next(),
                           table: .init(columns: ["Name", "", "Notes"],
                                        rows: [["alpha", "1", "first row"], ["beta", "22"], ["gamma", "333", "a cell with a lot of text that wraps and truncates after two lines"]])))
    cards.append(CardState(kind: .image, x: 740, y: 460, w: 200, h: 130, z: next(), imagePath: "missing-screenshot.png",
                           imageUnderstanding: "Terminal error"))
    cards.append(CardState(kind: .equation, x: 960, y: 460, w: 220, h: 96, z: next(), latex: "x = \\frac{-b \\pm \\sqrt{b^2 - 4ac}}{2a}"))
    cards.append(CardState(kind: .equation, x: 960, y: 570, w: 220, h: 60, z: next(), latex: "\\int_0^\\infty e^{-x^2}\\,dx", tint: 4))
    cards.append(CardState(kind: .equation, x: 960, y: 640, w: 220, h: 60, z: next(), latex: "\\frac{1}{"))
    cards.append(CardState(kind: .equation, x: 1200, y: 560, w: 160, h: 60, z: next(), latex: ""))
    cards.append(CardState(
      kind: .graph, x: 740, y: 620, w: 200, h: 160, z: next(),
      graph: .init()))
    cards.append(CardState(
      kind: .graph, x: 1200, y: 640, w: 360, h: 260, z: next(),
      graph: .init(xLabel: "time", xUnit: "s", yLabel: "load", yMin: -2, yMax: 2,
                   series: [.init(expression: "\\sin(x)", label: "sin"),
                            .init(expression: "\\frac{x}{5} - 1", label: "a rather long series label", tint: 3),
                            .init(points: [.init(x: 2, y: 1), .init(x: 5, y: -1, label: "B"), .init(x: 8, y: 0.5, label: "peak", tint: 0)],
                                  label: "events", tint: 1)])))
    return cards
  }

  /// A wobbly normalized stroke (0…1 in both axes), deterministic per seed.
  static func stroke(seed: Int, count: Int) -> [CanvasPoint] {
    var state = UInt64(truncatingIfNeeded: seed &* 2654435761 &+ 12345)
    func random() -> Double {
      state = state &* 6364136223846793005 &+ 1442695040888963407
      return Double(state >> 33) / Double(1 << 31)
    }
    let phase = random() * 6.28
    return (0..<count).map { index in
      let t = Double(index) / Double(count - 1)
      let y = 0.5 + 0.38 * sin(t * 9 + phase) + (random() - 0.5) * 0.06
      return CanvasPoint(x: t, y: min(max(y, 0), 1))
    }
  }

  /// The bounding box of the whole fixture.
  static func bounds(of cards: [CardState]) -> CGRect {
    cards.reduce(CGRect.null) { $0.union($1.frame) }
  }
}
