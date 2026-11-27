import AppKit
import SwiftUI
import XCTest
@testable import ComposerApp

/// The board renderer's contract: the scene reports only what changed, a move is carried by a
/// plane instead of redrawn, and the tiled view shows the same pixels as drawing the board in one
/// pass.
@MainActor
final class BoardRendererTests: XCTestCase {
  private func makeStyle(_ theme: ComposerTheme = .bonsaiLight) -> RenderStyle {
    RenderStyle(flavor: theme.flavor, appearance: theme.nsAppearance)
  }

  private func makeBoard(_ cards: [CardState]) -> BoardViewModel {
    let board = BoardViewModel(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    board.insertCopies(cards, offset: .zero)
    board.deselectAll()
    return board
  }

  // MARK: Scene

  func testSceneReportsOnlyWhatChanged() throws {
    let board = makeBoard(BoardFixtures.mixedBoard(count: 60))
    let style = makeStyle()
    let scene = BoardScene()
    func sync() -> [BoardDirt]? { scene.sync(.live(board: board, selectable: true, style: style)) }

    XCTAssertNil(sync(), "the first sync is a whole-board change")
    XCTAssertEqual(scene.count, board.cards.count)
    XCTAssertEqual(sync()?.count, 0, "nothing changed, nothing is dirty")

    let target = try XCTUnwrap(board.cards.first { $0.elementKind == .text })
    let before = try XCTUnwrap(scene.elements[target.id])
    let untouched = try XCTUnwrap(board.cards.first { $0.elementKind == .ellipse })
    let untouchedBefore = try XCTUnwrap(scene.elements[untouched.id])
    board.select(target.id)
    board.moveSelected(by: CGSize(width: 12, height: 0))
    let dirt = try XCTUnwrap(sync())
    XCTAssertFalse(dirt.isEmpty)
    XCTAssertTrue(dirt.allSatisfy { $0.plane == .rest })
    XCTAssertTrue(dirt.contains { $0.rect.intersects(before.paintBounds) })
    XCTAssertFalse(scene.elements[target.id] === before, "a changed card is a new element")
    XCTAssertTrue(scene.elements[untouched.id] === untouchedBefore, "an unchanged card keeps its element")
  }

  func testMoveLiftsItsElementsInsteadOfRedrawingThem() throws {
    let board = makeBoard(BoardFixtures.mixedBoard(count: 60))
    let style = makeStyle()
    let scene = BoardScene()
    func sync() -> [BoardDirt]? { scene.sync(.live(board: board, selectable: true, style: style)) }
    _ = sync()

    let shape = try XCTUnwrap(board.cards.first { $0.elementKind == .rectangle })
    let element = try XCTUnwrap(scene.elements[shape.id])
    let followers = board.cards.filter { $0.startBindingID == shape.id || $0.endBindingID == shape.id }
    XCTAssertFalse(followers.isEmpty, "the fixture binds an arrow to every rectangle")
    board.select(shape.id)
    let arrangement = scene.arrangement

    board.updateMovePreview(by: CGSize(width: 40, height: 30), tolerance: 0)
    let first = try XCTUnwrap(sync())
    XCTAssertGreaterThan(scene.arrangement, arrangement, "lifting is a new arrangement")
    XCTAssertEqual(scene.plane(of: shape.id), .lifted)
    XCTAssertEqual(scene.liftOffset, CGSize(width: 40, height: 30))
    XCTAssertTrue(scene.elements[shape.id] === element, "the moved element is carried, not rebuilt")
    XCTAssertTrue(first.allSatisfy { $0.plane == .live }, "only the arrows left behind are redrawn")
    for follower in followers { XCTAssertEqual(scene.plane(of: follower.id), .live) }
    XCTAssertFalse(scene.elements(in: shape.frame, plane: .rest).contains { $0 === element })
    XCTAssertTrue(scene.elements(in: shape.frame, plane: .lifted).contains { $0 === element })
    XCTAssertEqual(scene.elements(in: element.paintBounds.insetBy(dx: -400, dy: -400), plane: .live).count,
                   followers.count)

    // Every later frame of the drag is the same arrangement with a new offset.
    let lifted = scene.arrangement
    board.updateMovePreview(by: CGSize(width: 90, height: 60), tolerance: 0)
    let second = try XCTUnwrap(sync())
    XCTAssertEqual(scene.arrangement, lifted)
    XCTAssertEqual(scene.liftOffset, CGSize(width: 90, height: 60))
    XCTAssertTrue(second.allSatisfy { $0.plane == .live })
    XCTAssertTrue(scene.elements[shape.id] === element)

    board.finishMovePreview(commit: true)
    _ = sync()
    XCTAssertGreaterThan(scene.arrangement, lifted, "dropping puts everything back at rest")
    XCTAssertEqual(scene.plane(of: shape.id), .rest)
    for follower in followers { XCTAssertEqual(scene.plane(of: follower.id), .rest) }
    XCTAssertEqual(try XCTUnwrap(scene.elements[shape.id]).frame.minX, shape.frame.minX + 90, accuracy: 0.001)
  }

  func testMovePreviewIsOneOffsetHoweverManyCardsMove() throws {
    let board = makeBoard(BoardFixtures.mixedBoard(count: 300))
    board.selectAll()
    board.updateMovePreview(by: CGSize(width: 25, height: -10), tolerance: 0)
    let preview = board.gesturePreview
    XCTAssertEqual(preview.moved.count, board.cards.count)
    XCTAssertTrue(preview.cards.isEmpty, "every arrow moves with its ends: nothing is left to reroute")
    XCTAssertEqual(preview.offset, CGSize(width: 25, height: -10))
    let card = try XCTUnwrap(board.cards.first)
    XCTAssertEqual(try XCTUnwrap(board.renderedCard(card.id)).frame, card.frame.offsetBy(dx: 25, dy: -10))
    XCTAssertEqual(board.renderedCards.map(\.frame), board.cards.map { $0.frame.offsetBy(dx: 25, dy: -10) })
    board.finishMovePreview(commit: false)
    XCTAssertTrue(board.gesturePreview.isEmpty)
    XCTAssertEqual(board.renderedCard(card.id)?.frame, card.frame)
  }

  func testConnectorPaintsOnlyWhereItsLineRuns() {
    let style = makeStyle()
    let line = CardState(kind: .line, x: 0, y: 0, w: 2_000, h: 2_000, z: 1,
                         points: [CanvasPoint(x: 0, y: 0), CanvasPoint(x: 1, y: 1)])
    let element = RenderElement(card: line, text: "", ink: [], variant: .init(), style: style)
    XCTAssertTrue(element.paints(in: CGRect(x: 900, y: 900, width: 200, height: 200)))
    XCTAssertTrue(element.paints(in: CGRect(x: 1_000, y: 1_030, width: 100, height: 100)), "within the stroke's reach")
    XCTAssertFalse(element.paints(in: CGRect(x: 1_700, y: 100, width: 200, height: 200)),
                   "inside the bounding box, nowhere near the line")
    XCTAssertFalse(element.paints(in: CGRect(x: 2_400, y: 2_400, width: 50, height: 50)))

    let labelled = RenderElement(card: line, text: "label", ink: [], variant: .init(), style: style)
    XCTAssertTrue(labelled.paints(in: CGRect(x: 1_100, y: 990, width: 20, height: 20)), "the label sits at the middle")
  }

  func testSpatialGridFindsWhatTouchesARect() {
    let style = makeStyle()
    var grid = SpatialGrid()
    func element(_ x: Double, _ y: Double) -> RenderElement {
      RenderElement(card: CardState(kind: .rectangle, x: x, y: y, w: 100, h: 60, z: 1), text: "", ink: [],
                    variant: .init(), style: style)
    }
    let near = element(40, 40), far = element(5_000, 5_000), straddling = element(480, 480)
    for item in [near, far, straddling] { grid.insert(item) }
    let found = grid.query(CGRect(x: 0, y: 0, width: 520, height: 520))
    XCTAssertTrue(found.contains { $0 === near })
    XCTAssertTrue(found.contains { $0 === straddling })
    XCTAssertFalse(found.contains { $0 === far })
    XCTAssertEqual(found.count, Set(found.map(ObjectIdentifier.init)).count, "one entry per element")
    grid.remove(near)
    XCTAssertFalse(grid.query(CGRect(x: 0, y: 0, width: 520, height: 520)).contains { $0 === near })
    XCTAssertEqual(grid.bounds, far.paintBounds.union(straddling.paintBounds))
  }

  // MARK: Tiled view

  private struct Stage {
    let board: BoardViewModel
    let view: BoardRenderView
    let window: NSWindow
    let style: RenderStyle
    var viewport: CanvasViewport

    @MainActor func frame() {
      let board = board, style = style
      view.update(viewport: viewport) { .live(board: board, selectable: true, style: style) }
      CATransaction.flush()
    }

    @MainActor func settle() {
      frame()
      view.waitUntilSettled()
      CATransaction.flush()
    }

    @MainActor var drawn: Int { view.statistics.tilesDrawnInline + view.statistics.tilesDrawnInBackground }
  }

  private func makeStage(count: Int, size: CGSize = CGSize(width: 900, height: 640)) -> Stage {
    _ = NSApplication.shared
    let board = makeBoard(BoardFixtures.mixedBoard(count: count))
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let view = BoardRenderView(frame: CGRect(origin: .zero, size: size))
    window.contentView = view
    window.orderFrontRegardless()
    addTeardownBlock { @MainActor in
      window.orderOut(nil)
      window.contentView = nil
    }
    let stage = Stage(board: board, view: view, window: window, style: makeStyle(),
                      viewport: CanvasViewport(scale: 1, pan: CGSize(width: 10, height: 10)))
    stage.settle()
    return stage
  }

  func testDraggingDrawsNothingAfterTheLift() throws {
    let stage = makeStage(count: 60)
    XCTAssertEqual(stage.view.displayedPlanes, [.rest])
    XCTAssertGreaterThan(stage.view.paintedTileCount(), 0)

    // A shape near the middle of the view: nothing it is carried over comes into or out of sight.
    let shape = try XCTUnwrap(stage.board.cards.first { $0.elementKind == .diamond })
    stage.board.select(shape.id)
    stage.board.updateMovePreview(by: CGSize(width: 6, height: 4), tolerance: 0)
    stage.settle()
    XCTAssertEqual(stage.view.displayedPlanes, [.rest, .live, .lifted])
    XCTAssertGreaterThan(stage.view.paintedTileCount(in: .lifted), 0)
    XCTAssertGreaterThan(stage.view.statistics.tilesReused, 0, "tiles the shape never touched are not redrawn")

    let restBefore = stage.view.paintedTileCount(in: .rest)
    let inlineBefore = stage.view.statistics.tilesDrawnInline
    let backgroundBefore = stage.view.statistics.tilesDrawnInBackground
    for step in 1...30 {
      stage.board.updateMovePreview(by: CGSize(width: 6 + Double(step) * 3, height: 4 + Double(step) * 2), tolerance: 0)
      stage.frame()
    }
    XCTAssertEqual(stage.view.displayedLiftOffset, CGSize(width: 96, height: 64))
    XCTAssertEqual(stage.view.statistics.tilesDrawnInBackground, backgroundBefore, "a drag frame never waits on a tile")
    XCTAssertEqual(stage.view.paintedTileCount(in: .rest), restBefore, "the board at rest is not touched")
    // What is drawn each frame is the arrow that follows, alone in its plane.
    let perFrame = Double(stage.view.statistics.tilesDrawnInline - inlineBefore) / 30
    XCTAssertLessThanOrEqual(perFrame, 4)

    stage.board.finishMovePreview(commit: true)
    stage.settle()
    XCTAssertEqual(stage.view.displayedPlanes, [.rest])
    XCTAssertEqual(stage.view.displayedLiftOffset, .zero)
  }

  func testLiftingTheWholeBoardRedrawsNothing() {
    let stage = makeStage(count: 120)
    stage.board.selectAll()
    let before = stage.drawn
    stage.board.updateMovePreview(by: CGSize(width: 30, height: 20), tolerance: 0)
    stage.frame()
    // Every tile's picture simply changes plane, so the set is whole — and on screen — at once.
    XCTAssertEqual(stage.view.displayedPlanes, [.rest, .lifted])
    XCTAssertEqual(stage.view.displayedLiftOffset, CGSize(width: 30, height: 20))
    XCTAssertEqual(stage.drawn, before)
    for step in 1...10 {
      stage.board.updateMovePreview(by: CGSize(width: 30 + Double(step) * 2, height: 20), tolerance: 0)
      stage.frame()
    }
    XCTAssertEqual(stage.drawn, before, "sliding a plane draws nothing")
    stage.board.finishMovePreview(commit: false)
    stage.frame()
    XCTAssertEqual(stage.view.displayedPlanes, [.rest], "cancelling takes the pictures back the same way")
    XCTAssertEqual(stage.drawn, before)
  }

  /// The tiled, planed, GPU-transformed view against the same board drawn in one pass.
  func testViewShowsTheSamePixelsAsADirectRender() throws {
    var stage = makeStage(count: 60)
    try assertMatchesDirectRender(stage, "at rest")

    stage.viewport = CanvasViewport(scale: 1, pan: CGSize(width: -310, height: -140))
    stage.settle()
    try assertMatchesDirectRender(stage, "panned")

    stage.viewport = CanvasViewport(scale: 0.5, pan: CGSize(width: 20, height: 30))
    stage.settle()
    try assertMatchesDirectRender(stage, "zoomed out")

    // The topmost element, so carrying it above the board is also its true stacking order.
    let top = try XCTUnwrap(stage.board.cards.max { $0.z < $1.z })
    stage.board.select(top.id)
    stage.board.updateMovePreview(by: CGSize(width: -120, height: -80), tolerance: 0)
    stage.settle()
    try assertMatchesDirectRender(stage, "carrying one element")
    // The comparison is not blind: against the board as committed, the carried element is elsewhere.
    XCTAssertGreaterThan(try differenceFromDirectRender(stage, of: stage.board.cards), 0.01)

    stage.board.finishMovePreview(commit: true)
    stage.settle()
    try assertMatchesDirectRender(stage, "dropped")

    stage.board.selectAll()
    stage.board.updateMovePreview(by: CGSize(width: 64, height: 40), tolerance: 0)
    stage.settle()
    try assertMatchesDirectRender(stage, "carrying everything")

    stage.board.finishMovePreview(commit: false)
    stage.settle()
    try assertMatchesDirectRender(stage, "put back")
  }

  private func assertMatchesDirectRender(_ stage: Stage, _ state: String,
                                         file: StaticString = #filePath, line: UInt = #line) throws {
    let difference = try differenceFromDirectRender(stage, of: stage.board.renderedCards, file: file, line: line)
    XCTAssertLessThan(difference, 0.01, "\(state): \(difference * 100)% of the painted pixels differ",
                      file: file, line: line)
  }

  /// The share of painted pixels at which the view and a one-pass drawing of `cards` disagree.
  private func differenceFromDirectRender(_ stage: Stage, of cards: [CardState],
                                          file: StaticString = #filePath, line: UInt = #line) throws -> Double {
    let rasterScale = try XCTUnwrap(stage.view.displayedRasterScale, file: file, line: line)
    let backing = rasterScale / stage.viewport.safeScale
    let size = stage.view.bounds.size
    let width = Int((size.width * backing).rounded()), height = Int((size.height * backing).rounded())

    let shown = try XCTUnwrap(RenderBitmap.context(width: width, height: height), file: file, line: line)
    shown.scaleBy(x: backing, y: backing)
    try XCTUnwrap(stage.view.layer, file: file, line: line).render(in: shown)

    let board = stage.board
    let elements = BoardRasterizer.elements(for: cards, style: stage.style,
                                            text: { board.renderText(for: $0) }, ink: { board.ink(for: $0) })
    let direct = try XCTUnwrap(
      BoardRasterizer.image(of: elements, boardRect: stage.viewport.visibleBoardRect(in: size),
                            scale: rasterScale, zoom: stage.viewport.safeScale,
                            images: stage.view.images, background: nil), file: file, line: line)
    let expected = try XCTUnwrap(RenderBitmap.context(width: width, height: height), file: file, line: line)
    expected.draw(direct, in: CGRect(x: 0, y: 0, width: width, height: height))

    let a = try XCTUnwrap(shown.data, file: file, line: line).assumingMemoryBound(to: UInt32.self)
    let b = try XCTUnwrap(expected.data, file: file, line: line).assumingMemoryBound(to: UInt32.self)
    XCTAssertEqual(shown.bytesPerRow, expected.bytesPerRow, file: file, line: line)
    let stride = shown.bytesPerRow / 4
    var different = 0, painted = 0
    for y in 0..<height {
      for x in 0..<width {
        let p = a[y * stride + x], q = b[y * stride + x]
        if q != 0 || p != 0 { painted += 1 }
        guard p != q else { continue }
        var delta: UInt32 = 0
        for shift in [UInt32(0), 8, 16, 24] {
          let c = (p >> shift) & 0xFF, d = (q >> shift) & 0xFF
          delta = max(delta, c > d ? c - d : d - c)
        }
        if delta > 40 { different += 1 }
      }
    }
    XCTAssertGreaterThan(painted, width * height / 200, "the reference should not be blank", file: file, line: line)
    return Double(different) / Double(max(painted, 1))
  }

  /// Core Animation color-matches any bitmap that is not in the window's color space when it is
  /// committed, on the main thread: 25 ms for a screenful of tiles, a dropped frame or two every
  /// time a zoom lands. Tiles are drawn in the window's space so that never happens.
  func testTilesAreDrawnInTheWindowsColorSpace() throws {
    let stage = makeStage(count: 40)
    let window = try XCTUnwrap(stage.view.window)
    let space = try XCTUnwrap(window.colorSpace?.cgColorSpace)
    try XCTSkipUnless(space.model == .rgb && space.supportsOutput, "this display's space cannot be drawn into")
    let shown = stage.view.displayedTileColorSpaces
    XCTAssertEqual(shown.count, 1)
    XCTAssertTrue(shown.allSatisfy { CFEqual($0, space) }, "tiles are in \(shown), the window in \(space)")

    XCTAssertLessThan(try differenceFromDirectRender(stage, of: stage.board.renderedCards), 0.01)

    // Whatever the space, the picture is the same one: a new zoom level redraws every tile.
    stage.view.colorSpaceOverride = RenderBitmap.colorSpace
    var zoomed = stage
    zoomed.viewport.scale = 1.5
    zoomed.settle()
    let redrawn = zoomed.view.displayedTileColorSpaces
    XCTAssertEqual(redrawn.count, 1)
    XCTAssertTrue(redrawn.allSatisfy { CFEqual($0, RenderBitmap.colorSpace) })
    XCTAssertLessThan(try differenceFromDirectRender(zoomed, of: zoomed.board.renderedCards), 0.01)
  }

  /// An agent filling the board edits it hundreds of times a second while tiles from the edits
  /// before are still being drawn, and the user zooms and pans in the middle of it. However the
  /// work interleaves, the picture left at the end is the board.
  func testRapidEditsNeverLeaveAStalePicture() throws {
    var stage = makeStage(count: 10)
    let board = stage.board
    stage.viewport = CanvasViewport(scale: 0.1, pan: CGSize(width: 20, height: 20))
    stage.frame()
    for n in 0..<150 {
      let x = Double(n % 12) * 700, y = 900 + Double(n / 12) * 520
      let service = board.addDrawnElement(.rectangle, from: CGPoint(x: x, y: y), to: CGPoint(x: x + 200, y: y + 110))
      stage.frame()
      let queue = board.addDrawnElement(.ellipse, from: CGPoint(x: x + 380, y: y + 10), to: CGPoint(x: x + 590, y: y + 120))
      if let service, let queue {
        board.setText(service, "Service \(n)")
        _ = board.connectCards(from: service, to: queue, kind: .arrow, reason: n % 3 == 0 ? "publishes" : "")
      }
      stage.frame()
      _ = board.insertText("## Cluster \(n)\nHandles **retries**", at: CGPoint(x: x + 300, y: y + 230))
      stage.frame()
      // Some background tiles land mid-stream, some are overtaken by the next edit.
      if n % 5 == 0 { RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.004)) }
      if n == 40 { stage.viewport.scale = 0.2 }
      if n == 70 { stage.viewport.pan.width -= 400 }
      if n == 100 { stage.viewport = CanvasViewport(scale: 0.1, pan: CGSize(width: -300, height: -200)) }
      if n == 120, let service { board.select(service); board.updateMovePreview(by: CGSize(width: 40, height: 30), tolerance: 0) }
      if n == 130 { board.finishMovePreview(commit: true); board.deselectAll() }
    }
    board.deselectAll()
    stage.settle()
    XCTAssertGreaterThan(board.cards.count, 450)
    XCTAssertLessThan(try differenceFromDirectRender(stage, of: board.renderedCards), 0.01, "zoomed out, after the stream")

    stage.viewport = CanvasViewport(scale: 1, pan: CGSize(width: -2_050, height: -1_850))
    stage.settle()
    XCTAssertLessThan(try differenceFromDirectRender(stage, of: board.renderedCards), 0.01, "at 100%, in the middle of it")

    stage.viewport = CanvasViewport(scale: 0.38, pan: CGSize(width: -900, height: -700))
    stage.settle()
    XCTAssertLessThan(try differenceFromDirectRender(stage, of: board.renderedCards), 0.01, "and in between")
  }

  // MARK: Hosted in SwiftUI

  /// SwiftUI must bring the renderer up to date for a change to the board itself, not only for a
  /// change of viewport: a representable that merely HOLDS the board is never updated by a drag,
  /// an edit or a new element, because none of its stored values changed.
  func testHostedSurfaceFollowsTheBoardNotJustTheViewport() throws {
    _ = NSApplication.shared
    let session = CanvasWorkspaceSession(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let board = session.board
    board.insertCopies(BoardFixtures.mixedBoard(count: 30), offset: .zero)
    board.deselectAll()
    session.pan = CGSize(width: 10, height: 10)

    let size = CGSize(width: 900, height: 640)
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: BoardSurface(board: board, workspace: session)
      .frame(width: size.width, height: size.height))
    hosting.frame = CGRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    addTeardownBlock { @MainActor in
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
    let surface = try XCTUnwrap(renderView(in: hosting))
    func settle() {
      frame()
      surface.waitUntilSettled()
      frame()
    }
    settle()
    XCTAssertGreaterThan(surface.paintedTileCount(), 0)

    // A drag in flight.
    let shape = try XCTUnwrap(board.cards.first { $0.elementKind == .diamond })
    board.select(shape.id)
    settle()
    var refreshes = surface.statistics.refreshes
    board.updateMovePreview(by: CGSize(width: 30, height: 20), tolerance: 0)
    frame()
    XCTAssertGreaterThan(surface.statistics.refreshes, refreshes, "a drag frame reaches the renderer")
    settle()
    XCTAssertTrue(surface.displayedPlanes.contains(.lifted))
    XCTAssertEqual(surface.displayedLiftOffset, CGSize(width: 30, height: 20))
    board.finishMovePreview(commit: false)
    settle()
    XCTAssertEqual(surface.displayedPlanes, [.rest])

    // A new element, somewhere nothing was drawn before.
    let far = CGSize(width: 40_000, height: 0)
    session.pan = CGSize(width: -(shape.frame.minX + far.width) + 200, height: -shape.frame.minY + 200)
    settle()
    let painted = surface.paintedTileCount()
    refreshes = surface.statistics.refreshes
    board.insertCopies([shape], offset: far)
    frame()
    XCTAssertGreaterThan(surface.statistics.refreshes, refreshes, "a new element reaches the renderer")
    settle()
    XCTAssertGreaterThan(surface.paintedTileCount(), painted, "and is drawn")
  }

  /// The canvas's two layers as `ComposerCanvas` stacks them: the picture, and above it the
  /// SwiftUI view of whichever element is under an inline edit.
  private struct TwoLayers: View {
    @ObservedObject var board: BoardViewModel
    @ObservedObject var workspace: CanvasWorkspaceSession

    var body: some View {
      ZStack(alignment: .topLeading) {
        BoardSurface(board: board, workspace: workspace)
        LiveCardLayer(cards: [board.editingCardID].compactMap { $0 }.compactMap { board.renderedCard($0) },
                      board: board, selectedCardIDs: board.selectedCardIDs,
                      editingCardID: board.editingCardID, scale: workspace.scale, selectable: true)
          .equatable()
          .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
          .offset(x: workspace.pan.width, y: workspace.pan.height)
      }
    }
  }

  /// An element under an inline edit leaves the picture for its editor, and comes back when the
  /// edit ends — with what was typed.
  func testEditingHandsAnElementToItsEditorAndBack() throws {
    _ = NSApplication.shared
    let session = CanvasWorkspaceSession(store: DumpStore(inMemoryOnly: true, loadInitialContent: false))
    let board = session.board
    board.insertCopies(BoardFixtures.mixedBoard(count: 20), offset: .zero)
    board.deselectAll()
    session.pan = CGSize(width: 10, height: 10)

    let size = CGSize(width: 1100, height: 760)
    let window = NSWindow(contentRect: CGRect(origin: CGPoint(x: -20_000, y: -20_000), size: size),
                          styleMask: [.borderless], backing: .buffered, defer: false)
    window.isReleasedWhenClosed = false
    let hosting = NSHostingView(rootView: TwoLayers(board: board, workspace: session)
      .frame(width: size.width, height: size.height))
    hosting.frame = CGRect(origin: .zero, size: size)
    window.contentView = hosting
    window.orderFrontRegardless()
    addTeardownBlock { @MainActor in
      window.orderOut(nil)
      window.contentView = nil
    }
    func find<T: NSView>(_ type: T.Type, in view: NSView) -> T? {
      if let found = view as? T { return found }
      for child in view.subviews { if let found = find(type, in: child) { return found } }
      return nil
    }
    func frame() {
      hosting.layoutSubtreeIfNeeded()
      window.displayIfNeeded()
      CATransaction.flush()
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.01))
    }
    frame()
    let surface = try XCTUnwrap(find(BoardRenderView.self, in: hosting))
    func settle() {
      for _ in 0..<3 { frame() }
      surface.waitUntilSettled()
      frame()
    }
    func hidden() -> Set<UUID> { BoardSceneInput.live(board: board, selectable: true).hidden }
    settle()

    let note = try XCTUnwrap(board.cards.first { $0.elementKind == .text && $0.text.contains("Cluster") })
    XCTAssertNil(find(NSTextView.self, in: hosting))
    XCTAssertFalse(hidden().contains(note.id))

    board.beginEditing(note.id)
    settle()
    let editor = try XCTUnwrap(find(NSTextView.self, in: hosting), "the element under edit mounts its editor")
    XCTAssertTrue(editor.string.contains("Cluster"), "showing its text, not \"\(editor.string)\"")
    XCTAssertTrue(hidden().contains(note.id), "and it leaves the picture while the editor shows it")

    let refreshes = surface.statistics.refreshes
    board.endEditing(note.id)
    settle()
    XCTAssertNil(find(NSTextView.self, in: hosting), "the editor is gone")
    XCTAssertFalse(hidden().contains(note.id), "and the element is drawn again")
    XCTAssertGreaterThan(surface.statistics.refreshes, refreshes)
  }

  // MARK: Selection chrome

  /// Past `memberOutlineLimit` the selection is one box laid out from kept bounds; it must be the
  /// same box the member-by-member layout gives, at rest and while a move carries it.
  func testLargeSelectionIsOneBoxThatFollowsAMove() throws {
    let pinned = CardState(kind: .rectangle, x: -900, y: -700, w: 120, h: 80, isLocked: true)
    let viewport = CanvasViewport(scale: 0.5, pan: CGSize(width: 30, height: -20))
    func assertSameBox(_ board: BoardViewModel, _ message: String, line: UInt = #line) throws {
      let chrome = board.selectionChrome(viewport: viewport, interactive: true)
      let memberwise = SelectionChrome.resolve(selected: board.selectedRenderedCards, editingID: nil,
                                               viewport: viewport, interactive: true)
      let box = try XCTUnwrap(chrome.box, line: line), expected = try XCTUnwrap(memberwise.box, line: line)
      for (got, want) in [(box.minX, expected.minX), (box.minY, expected.minY),
                          (box.maxX, expected.maxX), (box.maxY, expected.maxY)] {
        XCTAssertEqual(got, want, accuracy: 0.001, message, line: line)
      }
      XCTAssertTrue(chrome.isMultiple, line: line)
      XCTAssertTrue(chrome.elementOutlines.isEmpty, "no outline per member at this size", line: line)
      XCTAssertEqual(chrome.handles, memberwise.handles, message, line: line)
      XCTAssertEqual(chrome.deleteCenter == nil, memberwise.deleteCenter == nil, message, line: line)
    }

    for cards in [BoardFixtures.mixedBoard(count: 400), BoardFixtures.mixedBoard(count: 400) + [pinned]] {
      let board = makeBoard(cards)
      board.selectAll()
      XCTAssertGreaterThan(board.selectedCardIDs.count, SelectionChrome.memberOutlineLimit)
      try assertSameBox(board, "at rest")
      board.updateMovePreview(by: CGSize(width: 44, height: -26), tolerance: 0)
      try assertSameBox(board, "carried by a move")
      board.finishMovePreview(commit: true)
      try assertSameBox(board, "after the move lands")
    }

    // Up to the limit, every member still gets its outline.
    let small = makeBoard(BoardFixtures.mixedBoard(count: 40))
    small.selectAll()
    XCTAssertEqual(small.selectionChrome(viewport: viewport, interactive: true).elementOutlines.count,
                   small.selectedCardIDs.count)
  }

}
