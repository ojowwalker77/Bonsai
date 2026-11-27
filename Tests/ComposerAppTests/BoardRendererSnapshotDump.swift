import AppKit
import XCTest
@testable import ComposerApp

/// Opt-in visual dump of the board renderer (BONSAI_RENDER_DUMP=<dir>): writes PNGs to inspect by eye.
@MainActor
final class BoardRendererSnapshotDump: XCTestCase {
  func testDumpFixtureBoard() throws {
    guard let directory = ProcessInfo.processInfo.environment["BONSAI_RENDER_DUMP"] else {
      throw XCTSkip("set BONSAI_RENDER_DUMP to a directory")
    }
    _ = NSApplication.shared
    let cards = BoardFixtures.showcase() + BoardFixtures.mixedBoard(count: 20).map { card in
      var moved = card
      moved.y += 900
      return moved
    }
    for theme in [ComposerTheme.bonsaiLight, .bonsaiDark, .catppuccinMocha] {
      let style = RenderStyle(flavor: theme.flavor, appearance: theme.nsAppearance)
      let elements = BoardRasterizer.elements(for: cards, style: style, text: { $0.text }, ink: { $0.ink ?? [] })
      let bounds = elements.reduce(CGRect.null) { $0.union($1.paintBounds) }.insetBy(dx: -24, dy: -24)
      for (label, scale, zoom) in [("2x", CGFloat(2), CGFloat(1)), ("far", CGFloat(0.5), CGFloat(0.25))] {
        guard let image = BoardRasterizer.image(of: elements, boardRect: bounds, scale: scale, zoom: zoom,
                                                images: PreloadedImageSource(cards: []), background: style.canvas),
              let data = NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]) else {
          return XCTFail("render failed")
        }
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme.rawValue)-\(label).png"))
      }
    }
  }

  /// The same board as the tiled view composites it — tiles in the window's color space, a shape
  /// lifted mid-drag — to compare by eye with the one-pass render above.
  func testDumpTiledView() throws {
    guard let directory = ProcessInfo.processInfo.environment["BONSAI_RENDER_DUMP"] else {
      throw XCTSkip("set BONSAI_RENDER_DUMP to a directory")
    }
    _ = NSApplication.shared
    let size = CGSize(width: 1180, height: 820)
    for theme in [ComposerTheme.bonsaiLight, .bonsaiDark] {
      let style = RenderStyle(flavor: theme.flavor, appearance: theme.nsAppearance)
      let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
      board.insertCopies(BoardFixtures.mixedBoard(count: 30), offset: .zero)
      board.deselectAll()
      let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                            styleMask: [.borderless], backing: .buffered, defer: false)
      window.isReleasedWhenClosed = false
      let view = BoardRenderView(frame: CGRect(origin: .zero, size: size))
      window.contentView = view
      window.orderFrontRegardless()
      defer {
        window.orderOut(nil)
        window.contentView = nil
      }
      let viewport = CanvasViewport(scale: 1, pan: CGSize(width: 20, height: 20))
      func settle() {
        view.update(viewport: viewport) { .live(board: board, selectable: true, style: style) }
        view.waitUntilSettled()
        CATransaction.flush()
      }
      func write(_ name: String) throws {
        let context = try XCTUnwrap(RenderBitmap.context(width: Int(size.width) * 2, height: Int(size.height) * 2))
        context.setFillColor(style.canvas)
        context.fill(CGRect(x: 0, y: 0, width: size.width * 2, height: size.height * 2))
        context.scaleBy(x: 2, y: 2)
        try XCTUnwrap(view.layer).render(in: context)
        let image = try XCTUnwrap(context.makeImage())
        let data = try XCTUnwrap(NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:]))
        try data.write(to: URL(fileURLWithPath: directory).appendingPathComponent("\(theme.rawValue)-\(name).png"))
      }
      settle()
      try write("view")
      let shape = try XCTUnwrap(board.cards.first { $0.elementKind == .rectangle })
      board.select(shape.id)
      board.updateMovePreview(by: CGSize(width: 90, height: 60), tolerance: 0)
      settle()
      try write("view-dragging")
      board.finishMovePreview(commit: false)
    }
  }

}
