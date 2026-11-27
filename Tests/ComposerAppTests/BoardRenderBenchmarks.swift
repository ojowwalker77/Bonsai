import AppKit
import SwiftUI
import XCTest
@testable import ComposerApp

/// Opt-in (BONSAI_PERF=1) frame-cost benchmark for the board renderer: main-thread milliseconds
/// per frame while panning, zooming and dragging boards of increasing size, at 100% and with the
/// whole board on screen. BONSAI_PERF_COUNTS picks the board sizes; BONSAI_PERF_OUT appends the
/// table to a file.
@MainActor
final class BoardRenderBenchmarks: XCTestCase {
  static let viewport = CGSize(width: 1180, height: 820)

  struct FrameSample {
    var median: Double
    var worst: Double
  }

  static func report(title: String, header: String, rows: [String]) {
    let out = "\n=== \(title) ===\n\(header)\n" + rows.joined(separator: "\n") + "\n"
    print(out)
    if let path = ProcessInfo.processInfo.environment["BONSAI_PERF_OUT"] {
      let existing = (try? String(contentsOfFile: path, encoding: .utf8)) ?? ""
      try? (existing + out).write(toFile: path, atomically: true, encoding: .utf8)
    }
  }

  override func setUp() async throws {
    try XCTSkipUnless(ProcessInfo.processInfo.environment["BONSAI_PERF"] == "1", "set BONSAI_PERF=1")
    _ = NSApplication.shared
  }

  func testTiledRendererFrameCost() throws {
    var rows: [String] = []
    let counts = (ProcessInfo.processInfo.environment["BONSAI_PERF_COUNTS"] ?? "50,300,1000,5000")
      .split(separator: ",").compactMap { Int($0) }
    for theme in [ComposerTheme.bonsaiLight, .bonsaiDark] {
      for count in counts {
        rows.append(try measure(count: count, theme: theme))
      }
    }
    Self.report(
      title: "Tiled renderer — main-thread ms per frame (median / worst); settle = ms until crisp after a zoom",
      header: "  theme  count        first           pan@100%        zoom@100%       drag@100%        pan@fit         zoom@fit      drag-all@fit    settle",
      rows: rows)
  }

  /// The board as the app hosts it — SwiftUI surface plus the selection chrome, driven through the
  /// same published state — so a frame here includes SwiftUI's own update and layout. This is the
  /// like-for-like successor of the per-element SwiftUI layer's numbers.
  func testHostedCanvasFrameCost() throws {
    var rows: [String] = []
    let counts = (ProcessInfo.processInfo.environment["BONSAI_PERF_COUNTS"] ?? "50,300,1000,5000")
      .split(separator: ",").compactMap { Int($0) }
    for count in counts { rows.append(try measureHosted(count: count)) }
    Self.report(
      title: "Hosted canvas (SwiftUI + renderer) — main-thread ms per frame (median / worst)",
      header: "  count      pan@100%        zoom@100%       drag@100%        pan@fit         zoom@fit      drag-all@fit   pan-all-selected  drag-some@fit",
      rows: rows)
  }

  private struct HostedCanvas: View {
    @ObservedObject var workspace: CanvasWorkspaceSession
    @ObservedObject var board: BoardViewModel

    var body: some View {
      let viewport = CanvasViewport(scale: workspace.scale, pan: workspace.pan)
      ZStack(alignment: .topLeading) {
        BoardSurface(board: board, workspace: workspace)
        SelectionOverlay(chrome: board.selectionChrome(viewport: viewport, interactive: true), onDelete: {})
      }
      .frame(width: BoardRenderBenchmarks.viewport.width, height: BoardRenderBenchmarks.viewport.height,
             alignment: .topLeading)
    }
  }

  private func measureHosted(count: Int) throws -> String {
    let session = CanvasWorkspaceSession(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let board = session.board
    let cards = BoardFixtures.mixedBoard(count: count)
    board.insertCopies(cards, offset: .zero)
    board.deselectAll()
    session.pan = CGSize(width: -40, height: -40)

    let size = Self.viewport
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: HostedCanvas(workspace: session, board: board))
    hosting.frame = CGRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    func frame() {
      hosting.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      RunLoop.main.run(mode: .default, before: Date())
    }
    func renderView(in view: NSView) -> BoardRenderView? {
      if let found = view as? BoardRenderView { return found }
      for child in view.subviews { if let found = renderView(in: child) { return found } }
      return nil
    }
    frame()
    let surface = try XCTUnwrap(renderView(in: hosting), "the hosted canvas has no render view")
    func settle() {
      frame()
      surface.waitUntilSettled()
      frame()
    }
    var starved: [String] = []
    /// What the canvas should be showing; a step that leaves it unchanged owes the renderer nothing.
    func shown() -> [CGFloat] {
      let preview = board.gesturePreview
      return [session.scale, session.pan.width, session.pan.height,
              preview.offset.width, preview.offset.height, CGFloat(preview.movedToken)]
    }
    func sample(_ name: String, frames: Int, _ step: (Int) -> Void) -> FrameSample {
      var times: [Double] = []
      var expected = 0, reached = 0
      for index in 0..<frames {
        let refreshes = surface.statistics.refreshes
        let before = shown()
        let start = CFAbsoluteTimeGetCurrent()
        step(index)
        frame()
        var elapsed = CFAbsoluteTimeGetCurrent() - start
        if shown() != before {
          expected += 1
          if surface.statistics.refreshes > refreshes { reached += 1 }
        }
        // Tiles drawn in the background land between frames; that main-thread time is the frame's too.
        let landed = surface.statistics.mainThreadSeconds
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        elapsed += surface.statistics.mainThreadSeconds - landed
        times.append(elapsed * 1_000)
      }
      // A frame SwiftUI did not carry through to the renderer was not measured at all.
      if reached < expected { starved.append("\(name) \(reached)/\(expected)") }
      times.sort()
      return .init(median: times[times.count / 2], worst: times[times.count - 1])
    }
    settle()

    let pan = sample("pan", frames: 60) { _ in session.pan.width -= 12 }
    settle()
    let zoom = sample("zoom", frames: 40) { _ in session.scale *= 1.012 }
    settle()
    session.scale = 1
    session.pan = CGSize(width: -40, height: -40)
    settle()

    let target = board.cards.first { $0.elementKind == .rectangle } ?? board.cards[0]
    board.select(target.id)
    settle()
    let drag = sample("drag", frames: 60) { index in
      board.updateMovePreview(by: CGSize(width: Double(index + 1) * 3, height: Double(index + 1) * 2), tolerance: 8)
    }
    board.finishMovePreview(commit: false)
    board.deselectAll()
    settle()

    let bounds = BoardFixtures.bounds(of: cards).insetBy(dx: -40, dy: -40)
    let fit = CanvasViewport.clampScale(min(size.width / bounds.width, size.height / bounds.height))
    session.scale = fit
    session.pan = CGSize(width: -bounds.minX * fit, height: -bounds.minY * fit)
    settle()
    let panFit = sample("pan@fit", frames: 40) { _ in session.pan.width -= 6 }
    settle()
    let zoomFit = sample("zoom@fit", frames: 40) { _ in session.scale *= 1.01 }
    settle()
    board.selectAll()
    settle()
    let dragAll = sample("drag-all", frames: 30) { index in
      board.updateMovePreview(by: CGSize(width: Double(index + 1) * 4, height: Double(index + 1) * 3), tolerance: 8)
    }
    board.finishMovePreview(commit: false)
    settle()
    let panSelected = sample("pan-selected", frames: 40) { _ in session.pan.width += 6 }
    settle()

    // A selection small enough that every member keeps its own outline.
    board.deselectAll()
    for card in board.cards.prefix(min(150, board.cards.count / 2)) { board.select(card.id, extending: true) }
    settle()
    let dragSome = sample("drag-some", frames: 30) { index in
      board.updateMovePreview(by: CGSize(width: Double(index + 1) * 4, height: Double(index + 1) * 3), tolerance: 8)
    }
    board.finishMovePreview(commit: false)
    settle()
    XCTAssertTrue(starved.isEmpty, "frames that never reached the renderer: \(starved)")

    func cell(_ value: FrameSample) -> String {
      String(format: "%6.1f / %6.1f", value.median, value.worst)
    }
    return String(format: "%7d   ", count)
      + [pan, zoom, drag, panFit, zoomFit, dragAll, panSelected, dragSome].map(cell).joined(separator: "  ")
  }

  /// Where a frame's time goes: per-kind raster cost, tile overhead, and the model/scene work
  /// behind one drag frame.
  func testCostBreakdown() throws {
    var lines: [String] = []
    func time(_ iterations: Int, _ body: () -> Void) -> Double {
      let start = CFAbsoluteTimeGetCurrent()
      for _ in 0..<iterations { body() }
      return (CFAbsoluteTimeGetCurrent() - start) * 1_000_000 / Double(iterations)
    }
    let images = PreloadedImageSource(cards: [])
    for theme in [ComposerTheme.bonsaiLight, .bonsaiDark] {
      let style = RenderStyle(flavor: theme.flavor, appearance: theme.nsAppearance)
      let cards = BoardFixtures.mixedBoard(count: 10) + BoardFixtures.showcase()
      var byKind: [String: [RenderElement]] = [:]
      for card in cards {
        let element = RenderElement(card: card, text: card.text, ink: card.ink ?? [], variant: .init(), style: style)
        byKind[card.elementKind.rawValue + (card.elementKind == .text && card.text.count > 60 ? "-long" : ""), default: []].append(element)
      }
      for zoom in [CGFloat(1), 0.3] {
        let environment = RenderEnvironment(pixelScale: zoom * 2, zoom: zoom, images: images)
        var row = "\(theme.rawValue) zoom \(zoom) µs/element:"
        for (kind, elements) in byKind.sorted(by: { $0.key < $1.key }) {
          guard let context = RenderBitmap.context(width: 1024, height: 1024) else { continue }
          context.scaleBy(x: zoom * 2, y: zoom * 2)
          for element in elements { element.draw(in: context, environment: environment) }   // warm layouts
          let cost = time(20) {
            for element in elements {
              context.saveGState()
              context.translateBy(x: -element.frame.minX + 40, y: -element.frame.minY + 40)
              element.draw(in: context, environment: environment)
              context.restoreGState()
            }
          } / Double(elements.count)
          row += String(format: " %@=%.0f", kind, cost)
        }
        lines.append(row)
      }
    }
    lines.append(String(format: "tile overhead (context + makeImage) µs: %.0f", time(50) {
      let context = RenderBitmap.context(width: 512, height: 512)
      context?.fill(CGRect(x: 0, y: 0, width: 4, height: 4))
      _ = context?.makeImage()
    }))

    for count in [1000, 5000] {
      let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
      board.insertCopies(BoardFixtures.mixedBoard(count: count), offset: .zero)
      let style = RenderStyle(flavor: ComposerTheme.bonsaiLight.flavor, appearance: ComposerTheme.bonsaiLight.nsAppearance)
      let scene = BoardScene()
      func input() -> BoardSceneInput { .live(board: board, selectable: true, style: style) }
      let initial = time(1) { _ = scene.sync(input()) }
      let idle = time(20) { _ = scene.sync(input()) }
      var step = 0.0
      /// One drag: its first frame (which indexes the board), then steady frames split into the
      /// model's share and the scene's.
      func drag(frames: Int) -> (first: Double, model: Double, scene: Double) {
        let first = time(1) { board.updateMovePreview(by: CGSize(width: 2, height: 2), tolerance: 8) }
        _ = scene.sync(input())
        var model = 0.0, sync = 0.0
        for _ in 0..<frames {
          step += 3
          var mark = CFAbsoluteTimeGetCurrent()
          board.updateMovePreview(by: CGSize(width: step, height: step), tolerance: 8)
          model += CFAbsoluteTimeGetCurrent() - mark
          mark = CFAbsoluteTimeGetCurrent()
          _ = scene.sync(input())
          sync += CFAbsoluteTimeGetCurrent() - mark
        }
        board.finishMovePreview(commit: false)
        _ = scene.sync(input())
        return (first, model * 1_000_000 / Double(frames), sync * 1_000_000 / Double(frames))
      }
      let one = board.cards.first { $0.elementKind == .rectangle }!
      board.select(one.id)
      let single = drag(frames: 40)
      let chrome = time(30) { _ = board.selectedRenderedCards }
      board.selectAll()
      let all = drag(frames: 10)
      let query = time(20) { _ = scene.elements(in: CGRect(x: 0, y: 0, width: 2560, height: 2560)) }
      lines.append(String(format: "%d elements µs: scene initial=%.0f idle=%.0f | drag one: first=%.0f model=%.0f scene=%.0f selection=%.0f | drag all: first=%.0f model=%.0f scene=%.0f | query 2560²=%.0f",
                          count, initial, idle, single.first, single.model, single.scene, chrome,
                          all.first, all.model, all.scene, query))
    }
    Self.report(title: "Cost breakdown", header: "", rows: lines)
  }

  private func measure(count: Int, theme: ComposerTheme) throws -> String {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let cards = BoardFixtures.mixedBoard(count: count)
    board.insertCopies(cards, offset: .zero)
    let style = RenderStyle(flavor: theme.flavor, appearance: theme.nsAppearance)
    let size = Self.viewport
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    let view = BoardRenderView(frame: CGRect(origin: .zero, size: size))
    // A programmatic NSWindow releases itself on close by default; under ARC that is a double free.
    window.isReleasedWhenClosed = false
    window.contentView = view
    window.orderFrontRegardless()
    defer {
      window.orderOut(nil)
      window.contentView = nil
    }

    var viewport = CanvasViewport(scale: 1, pan: CGSize(width: -40, height: -40))
    let source: () -> BoardSceneInput = { .live(board: board, selectable: true, style: style) }
    func frame() {
      view.update(viewport: viewport, source: source)
      CATransaction.flush()
    }
    func sample(frames: Int, _ step: (Int) -> Void) -> FrameSample {
      var times: [Double] = []
      for index in 0..<frames {
        let start = CFAbsoluteTimeGetCurrent()
        step(index)
        frame()
        var elapsed = CFAbsoluteTimeGetCurrent() - start
        // Background tiles land between frames, as with a real run loop; the main-thread time that
        // takes (their commit to the GPU included) is counted with the frame.
        let landed = view.statistics.mainThreadSeconds
        RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.001))
        elapsed += view.statistics.mainThreadSeconds - landed
        times.append(elapsed * 1_000)
      }
      times.sort()
      return .init(median: times[times.count / 2], worst: times[times.count - 1])
    }

    let firstStart = CFAbsoluteTimeGetCurrent()
    frame()
    let first = (CFAbsoluteTimeGetCurrent() - firstStart) * 1_000
    view.waitUntilSettled()

    let pan = sample(frames: 60) { _ in viewport.pan.width -= 12 }
    view.waitUntilSettled()
    let zoom = sample(frames: 40) { _ in viewport.scale *= 1.012 }
    let settleStart = CFAbsoluteTimeGetCurrent()
    view.waitUntilSettled()
    let settle = (CFAbsoluteTimeGetCurrent() - settleStart) * 1_000
    viewport = CanvasViewport(scale: 1, pan: CGSize(width: -40, height: -40))
    frame()
    view.waitUntilSettled()

    // `insertCopies` mints new ids: pick a real element near the viewport's top-left.
    let target = board.cards.first { $0.elementKind == .rectangle } ?? board.cards[0]
    board.select(target.id)
    let drag = sample(frames: 60) { index in
      board.updateMovePreview(by: CGSize(width: Double(index + 1) * 3, height: Double(index + 1) * 2), tolerance: 8)
    }
    board.finishMovePreview(commit: false)
    frame()
    view.waitUntilSettled()

    // Whole board on screen.
    let bounds = BoardFixtures.bounds(of: cards).insetBy(dx: -40, dy: -40)
    let fit = CanvasViewport.clampScale(min(size.width / bounds.width, size.height / bounds.height))
    viewport = CanvasViewport(scale: fit, pan: CGSize(width: -bounds.minX * fit, height: -bounds.minY * fit))
    frame()
    view.waitUntilSettled()
    let panFit = sample(frames: 40) { _ in viewport.pan.width -= 6 }
    view.waitUntilSettled()
    let zoomFit = sample(frames: 40) { _ in viewport.scale *= 1.01 }
    view.waitUntilSettled()
    board.selectAll()
    let dragAll = sample(frames: 30) { index in
      board.updateMovePreview(by: CGSize(width: Double(index + 1) * 4, height: Double(index + 1) * 3), tolerance: 8)
    }
    board.finishMovePreview(commit: false)
    view.waitUntilSettled()

    func cell(_ value: FrameSample) -> String {
      String(format: "%6.1f / %6.1f", value.median, value.worst)
    }
    return String(format: "%7@ %6d   %8.1f      ", theme == .bonsaiDark ? "dark" : "light", count, first)
      + [pan, zoom, drag, panFit, zoomFit, dragAll].map(cell).joined(separator: "  ")
      + String(format: "  %7.0f", settle)
  }
}
