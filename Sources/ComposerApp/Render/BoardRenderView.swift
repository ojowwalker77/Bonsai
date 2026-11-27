import AppKit

/// The board, drawn.
///
/// Elements are rasterized into fixed-size tiles of board space and kept as layer contents. The
/// viewport is one affine transform on the tiles' container, so:
///
/// - **Pan** moves layers on the GPU. Only tiles scrolling into view are drawn.
/// - **Zoom** scales the existing tiles at once, then a fresh set is rasterized at the new scale
///   off the main thread and swapped in whole — never a frame spent waiting on text layout.
/// - **A move** lifts what it carries into a plane of its own, drawn once and then slid on the
///   GPU; whatever the move reshapes along the way (an arrow following a shape) is redrawn alone
///   in a third plane. The board underneath is not redrawn at all.
/// - **Edits** repaint just the tiles under the elements that changed.
///
/// Per-frame main-thread work therefore depends on what is on screen and what changed, not on how
/// many elements the board holds — and for a pan, a zoom or a drag, on neither.
@MainActor
final class BoardRenderView: NSView {
  nonisolated static let tilePixels = 512

  struct Statistics {
    var tilesDrawnInline = 0
    var tilesDrawnInBackground = 0
    /// Tiles that took their picture from another set instead of being drawn again.
    var tilesReused = 0
    /// Tiles marked dirty that turned out to hold the same elements and were left alone.
    var tilesConfirmed = 0
    var generations = 0
    /// Frames brought up to date (whether or not anything needed drawing).
    var refreshes = 0
    var lastInlineSeconds = 0.0
    /// All the main-thread time this view has spent: bringing frames up to date and putting tiles
    /// drawn in the background on screen (which is where their commit to the GPU is paid).
    var mainThreadSeconds = 0.0
  }

  private(set) var statistics = Statistics()
  var images: any RenderImageSource = RenderImageCache.shared
  /// Tests: draw tiles in this space instead of the window's.
  var colorSpaceOverride: CGColorSpace?

  private let scene = BoardScene()
  private let container = CALayer()
  private var current: Generation?
  private var pending: Generation?
  private var viewport = CanvasViewport()
  private var source: (() -> BoardSceneInput)?
  private let renderQueue: OperationQueue
  private let lanes: Int
  /// Running estimate of what one element costs to draw into one tile, used to decide whether a
  /// repaint fits in the frame or belongs on the background queue.
  private var secondsPerElement = 0.000_2
  private var lastGenerationStart: CFAbsoluteTime = 0
  private var refreshScheduled = false
  private var isRefreshing = false
  private var imageObserver: NSObjectProtocol?

  private struct TileKey: Hashable {
    var x: Int
    var y: Int
    var plane: BoardPlane
  }

  @MainActor
  private final class Tile {
    let layer = CALayer()
    let plane: BoardPlane
    init(plane: BoardPlane) { self.plane = plane }
    /// Bumped whenever something under the tile may have changed.
    var version = 0
    var renderedVersion = -1
    var inFlightVersion: Int?
    var operation: Operation?
    /// What the picture shows — the elements drawn into it, in order (`BoardRenderView.signature`).
    /// nil when the picture can no longer be trusted whatever the elements are.
    var signature: Int?
    var image: CGImage?
    /// Where `image` sits, in board units.
    var imageRect: CGRect = .zero
  }

  /// One complete set of tiles: one raster scale, one arrangement of elements into planes.
  @MainActor
  private final class Generation {
    let rasterScale: CGFloat
    let zoom: CGFloat
    /// Board units per tile.
    let tileSize: CGFloat
    /// The split of elements between planes this set was drawn for (`BoardScene.arrangement`).
    let arrangement: Int
    /// The planes that split puts anything in.
    let planes: [BoardPlane]
    let layer = CALayer()
    private let planeLayers: [CALayer]
    var tiles: [TileKey: Tile] = [:]
    var hasPainted = false
    /// How far this set's lifted plane has been carried, in board units.
    private(set) var liftOffset: CGSize = .zero

    init(rasterScale: CGFloat, zoom: CGFloat, arrangement: Int, planes: [BoardPlane]) {
      self.rasterScale = rasterScale
      self.zoom = zoom
      self.arrangement = arrangement
      self.planes = planes
      tileSize = CGFloat(BoardRenderView.tilePixels) / rasterScale
      layer.anchorPoint = .zero
      layer.actions = BoardRenderView.noActions
      // Back to front: the board at rest, what a gesture is reshaping, what it is carrying.
      planeLayers = BoardPlane.allCases.map { _ in
        let plane = CALayer()
        plane.anchorPoint = .zero
        plane.actions = BoardRenderView.noActions
        return plane
      }
      for plane in planeLayers { layer.addSublayer(plane) }
    }

    func layer(for plane: BoardPlane) -> CALayer { planeLayers[plane.rawValue] }

    func rect(for key: TileKey) -> CGRect {
      CGRect(x: CGFloat(key.x) * tileSize, y: CGFloat(key.y) * tileSize, width: tileSize, height: tileSize)
    }

    func keys(in rect: CGRect, plane: BoardPlane) -> [TileKey] {
      guard rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite else { return [] }
      let minX = Int((rect.minX / tileSize).rounded(.down)), maxX = Int((rect.maxX / tileSize).rounded(.up)) - 1
      let minY = Int((rect.minY / tileSize).rounded(.down)), maxY = Int((rect.maxY / tileSize).rounded(.up)) - 1
      guard maxX >= minX, maxY >= minY, (maxX - minX + 1) * (maxY - minY + 1) <= 4_096 else { return [] }
      var keys: [TileKey] = []
      keys.reserveCapacity((maxX - minX + 1) * (maxY - minY + 1))
      for y in minY...maxY {
        for x in minX...maxX { keys.append(TileKey(x: x, y: y, plane: plane)) }
      }
      return keys
    }

    /// How many tiles `keys(in:plane:)` would return, without building them.
    func keyCount(in rect: CGRect) -> Int {
      guard rect.width > 0, rect.height > 0, rect.minX.isFinite, rect.minY.isFinite,
            rect.width.isFinite, rect.height.isFinite else { return 0 }
      let columns = Int((rect.maxX / tileSize).rounded(.up)) - Int((rect.minX / tileSize).rounded(.down))
      let rows = Int((rect.maxY / tileSize).rounded(.up)) - Int((rect.minY / tileSize).rounded(.down))
      return max(columns, 0) * max(rows, 0)
    }

    /// The smallest rectangle on `key`'s pixel grid holding everything `elements` paint in it.
    func cover(of elements: [RenderElement], in key: TileKey) -> (rect: CGRect, pixels: (width: Int, height: Int))? {
      let tileRect = rect(for: key)
      var union = CGRect.null
      for element in elements { union = union.union(element.coverage(in: tileRect)) }
      guard !union.isNull, union.width > 0, union.height > 0 else { return nil }
      let limit = BoardRenderView.tilePixels
      let left = min(max(Int(((union.minX - tileRect.minX) * rasterScale).rounded(.down)), 0), limit - 1)
      let top = min(max(Int(((union.minY - tileRect.minY) * rasterScale).rounded(.down)), 0), limit - 1)
      let right = min(max(Int(((union.maxX - tileRect.minX) * rasterScale).rounded(.up)), left + 1), limit)
      let bottom = min(max(Int(((union.maxY - tileRect.minY) * rasterScale).rounded(.up)), top + 1), limit)
      let rect = CGRect(x: tileRect.minX + CGFloat(left) / rasterScale, y: tileRect.minY + CGFloat(top) / rasterScale,
                        width: CGFloat(right - left) / rasterScale, height: CGFloat(bottom - top) / rasterScale)
      return (rect, (right - left, bottom - top))
    }

    func tile(for key: TileKey) -> Tile {
      if let tile = tiles[key] { return tile }
      let tile = Tile(plane: key.plane)
      tile.layer.anchorPoint = .zero
      tile.layer.contentsGravity = .resize
      tile.layer.magnificationFilter = .linear
      tile.layer.minificationFilter = .linear
      tile.layer.actions = BoardRenderView.noActions
      tiles[key] = tile
      return tile
    }

    /// Slide the lifted plane to `offset`, on whole device pixels so its tiles stay as sharp in
    /// flight as they were at rest.
    func carry(_ offset: CGSize, pixelsPerUnit: CGFloat) {
      guard offset != liftOffset else { return }
      liftOffset = offset
      let unit = max(pixelsPerUnit, 0.000_1)
      layer(for: .lifted).setAffineTransform(CGAffineTransform(
        translationX: (offset.width * unit).rounded() / unit,
        y: (offset.height * unit).rounded() / unit))
    }

    /// The part of `plane` that has to be drawn for `visible` to be covered.
    func extent(of plane: BoardPlane, covering visible: CGRect) -> CGRect {
      plane == .lifted ? visible.offsetBy(dx: -liftOffset.width, dy: -liftOffset.height) : visible
    }
  }

  private struct Job {
    let generation: Generation
    let key: TileKey
    let tile: Tile
    /// The part of the tile its elements can reach, on the tile's pixel grid — all that is drawn,
    /// stored and sent to the GPU. One thin arrow in a tile is a small picture, not a 512px one.
    let rect: CGRect
    let pixels: (width: Int, height: Int)
    let colorSpace: CGColorSpace
    let version: Int
    let zoom: CGFloat
    let elements: [RenderElement]
    let signature: Int
  }

  /// Layers here are positioned every frame; an implicit animation would smear every pan.
  fileprivate static let noActions: [String: any CAAction] = [
    "contents": NSNull(), "position": NSNull(), "bounds": NSNull(), "transform": NSNull(),
    "sublayers": NSNull(), "hidden": NSNull(), "opacity": NSNull(), "onOrderIn": NSNull(), "onOrderOut": NSNull(),
  ]

  /// Names a tile's picture by what was drawn into it. Elements never change (a changed element
  /// is a new one), so equal signatures at one scale are equal pictures.
  private static func signature(of elements: [RenderElement]) -> Int {
    var hasher = Hasher()
    hasher.combine(elements.count)
    for element in elements { hasher.combine(element.serial) }
    return hasher.finalize()
  }

  override init(frame frameRect: NSRect) {
    let cores = ProcessInfo.processInfo.activeProcessorCount
    lanes = max(cores - 1, 1)
    renderQueue = OperationQueue()
    renderQueue.name = "dev.jow.Composer.board-render"
    renderQueue.qualityOfService = .userInitiated
    renderQueue.maxConcurrentOperationCount = max(cores - 2, 2)
    super.init(frame: frameRect)
    let root = CALayer()
    root.actions = Self.noActions
    layer = root
    wantsLayer = true
    layerContentsRedrawPolicy = .never
    container.anchorPoint = .zero
    container.actions = Self.noActions
    root.addSublayer(container)
    imageObserver = NotificationCenter.default.addObserver(
      forName: RenderImageCache.didLoad, object: nil, queue: .main) { [weak self] note in
        let path = note.object as? String
        MainActor.assumeIsolated { self?.imageDidLoad(path) }
      }
  }

  @available(*, unavailable)
  required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

  deinit {
    if let imageObserver { NotificationCenter.default.removeObserver(imageObserver) }
    renderQueue.cancelAllOperations()
  }

  // The board is display only: every pointer event belongs to the canvas input view beneath.
  override func hitTest(_ point: NSPoint) -> NSView? { nil }
  override var isOpaque: Bool { false }

  override func layout() {
    super.layout()
    refresh()
  }

  override func viewDidChangeBackingProperties() {
    super.viewDidChangeBackingProperties()
    refresh()
  }

  override func viewDidMoveToWindow() {
    super.viewDidMoveToWindow()
    if window == nil {
      renderQueue.cancelAllOperations()
    } else {
      refresh()
    }
  }

  // MARK: Input

  /// Show `viewport`. `source` is asked for the board's current state on every refresh, including
  /// the ones this view starts itself (a background tile landing, an image finishing its decode).
  func update(viewport: CanvasViewport, source: @escaping () -> BoardSceneInput) {
    self.viewport = viewport
    self.source = source
    refresh()
  }

  private var backingScale: CGFloat { window?.backingScaleFactor ?? NSScreen.main?.backingScaleFactor ?? 2 }

  /// The color space tiles are drawn in: the window's own.
  ///
  /// Core Animation color-matches a bitmap in any other space when it is committed — on the main
  /// thread, about a millisecond per tile, 25 ms for a screenful landing at once — and takes one
  /// already in the window's space as it is. Core Graphics matches the colors as it draws instead,
  /// off the main thread, so what reaches the display is the same. A tile outlives a move to
  /// another display unharmed: its bitmap says which space it is in.
  private var tileColorSpace: CGColorSpace {
    if let override = colorSpaceOverride { return override }
    guard let space = (window?.colorSpace ?? NSScreen.main?.colorSpace)?.cgColorSpace,
          space.model == .rgb, space.supportsOutput else { return RenderBitmap.colorSpace }
    return space
  }

  private var frameBudget: Double {
    let fps = Double(window?.screen?.maximumFramesPerSecond ?? 60)
    return min(0.007, 0.4 / max(fps, 30))
  }

  private var visibleBoardRect: CGRect { viewport.visibleBoardRect(in: bounds.size) }

  private func scheduleRefresh(after delay: TimeInterval = 0) {
    guard !refreshScheduled else { return }
    refreshScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
      guard let self else { return }
      self.refreshScheduled = false
      self.refresh()
    }
  }

  private func imageDidLoad(_ path: String?) {
    guard let path else { return }
    var changed: [CGRect] = []
    for element in scene.elements.values where element.card.elementKind == .image && element.card.imagePath == path {
      changed.append(element.paintBounds)
    }
    guard !changed.isEmpty else { return }
    // Same elements, new pixels: every picture of them, in every set and plane, is out of date.
    for generation in [current, pending] {
      guard let generation else { continue }
      for rect in changed {
        for plane in BoardPlane.allCases {
          for key in generation.keys(in: rect, plane: plane) {
            guard let tile = generation.tiles[key] else { continue }
            tile.version += 1
            tile.signature = nil
          }
        }
      }
    }
    scheduleRefresh()
  }

  // MARK: Refresh

  private func makeGeneration(scale: CGFloat) -> Generation {
    statistics.generations += 1
    return Generation(rasterScale: scale, zoom: viewport.safeScale, arrangement: scene.arrangement,
                      planes: BoardPlane.allCases.filter(scene.uses))
  }

  private func refresh() {
    guard let source, !isRefreshing, bounds.width > 0, bounds.height > 0 else { return }
    let began = CFAbsoluteTimeGetCurrent()
    defer { statistics.mainThreadSeconds += CFAbsoluteTimeGetCurrent() - began }
    isRefreshing = true
    defer { isRefreshing = false }
    statistics.refreshes += 1

    let dirty = scene.sync(source())
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    defer { CATransaction.commit() }
    applyTransform()

    let target = viewport.safeScale * backingScale
    let isFirst = current == nil
    if current == nil {
      let generation = makeGeneration(scale: target)
      container.addSublayer(generation.layer)
      current = generation
    }
    guard let current else { return }
    // A set drawn for another arrangement is frozen: it keeps showing exactly what it shows until
    // its replacement is whole, so a gesture never starts or ends on a half-redrawn board.
    let currentIsLive = current.arrangement == scene.arrangement
    if let stale = pending, stale.arrangement != scene.arrangement {
      discard(stale)
      pending = nil
    }
    if currentIsLive { invalidate(current, dirty) }
    invalidate(pending, dirty)

    let visible = visibleBoardRect
    let scaleMatches = abs(current.rasterScale - target) <= target * 0.000_5
    if scaleMatches, currentIsLive {
      // Back at what is already on screen (a pinch that returned): the replacement is moot.
      if let pending { discard(pending) }
      pending = nil
    } else if pending == nil {
      // A new scale: existing tiles keep showing, scaled, while a fresh set is drawn off the main
      // thread — one set at a time, and not more often than the eye can use. A new arrangement (a
      // gesture starting or ending) is wanted at once.
      let now = CFAbsoluteTimeGetCurrent()
      let wait = currentIsLive ? 0.05 - (now - lastGenerationStart) : 0
      if wait <= 0 {
        pending = makeGeneration(scale: target)
        lastGenerationStart = now
      } else {
        scheduleRefresh(after: wait)
      }
    }

    if currentIsLive { current.carry(scene.liftOffset, pixelsPerUnit: target) }
    pending?.carry(scene.liftOffset, pixelsPerUnit: target)

    if let pending {
      // The outgoing set only keeps what it already shows fresh; new ground goes to the new set.
      if currentIsLive {
        paint(current, over: visible, createsTiles: false, inline: true, budget: frameBudget)
      }
      // A set for a new arrangement at the same scale mostly takes its pictures from the one on
      // screen; when what is left fits in the frame, the gesture starts on the frame it was made.
      paint(pending, over: visible, createsTiles: true,
            inline: !currentIsLive && pending.rasterScale == current.rasterScale, budget: frameBudget)
      promoteIfReady()
    } else {
      // The very first frame of a board is worth a longer wait than a blank canvas.
      paint(current, over: visible, createsTiles: true, inline: true, budget: isFirst ? 0.08 : frameBudget)
      // A margin drawn ahead of the scroll, so ordinary panning never shows an undrawn edge.
      paint(current, over: visible, margin: current.tileSize * 0.75, createsTiles: true, inline: false,
            budget: frameBudget)
      evict(current, keeping: visible)
    }
  }

  private func applyTransform() {
    let backing = backingScale
    let scale = viewport.safeScale
    // Whole device pixels, so tiles at their native scale land exactly on the pixel grid.
    let tx = (viewport.pan.width * backing).rounded() / backing
    let ty = (viewport.pan.height * backing).rounded() / backing
    // Board space is y-down and tiles are stored mirrored (see BoardRasterizer); this view is
    // y-up. The one negative scale puts both right.
    container.setAffineTransform(CGAffineTransform(a: scale, b: 0, c: 0, d: -scale, tx: tx, ty: bounds.height - ty))
  }

  private func invalidate(_ generation: Generation?, _ dirty: [BoardDirt]?) {
    guard let generation, !generation.tiles.isEmpty else { return }
    guard let dirty else {
      // Everything changed, down to how it is drawn (a new theme): no picture can be trusted.
      for tile in generation.tiles.values {
        tile.version += 1
        tile.signature = nil
      }
      return
    }
    guard dirty.count <= 512 else {
      for tile in generation.tiles.values { tile.version += 1 }
      return
    }
    for dirt in dirty {
      for key in generation.keys(in: dirt.rect, plane: dirt.plane) { generation.tiles[key]?.version += 1 }
    }
  }

  /// Bring `generation`'s tiles under `visible` (grown by `margin`) up to date, in every plane.
  private func paint(_ generation: Generation, over visible: CGRect, margin: CGFloat = 0,
                     createsTiles: Bool, inline: Bool, budget: Double) {
    var jobs: [Job] = []
    var work = 0.0
    let colorSpace = tileColorSpace
    for plane in generation.planes {
      let extent = generation.extent(of: plane, covering: visible).insetBy(dx: -margin, dy: -margin)
      for key in generation.keys(in: extent, plane: plane) {
        guard let tile = createsTiles ? generation.tile(for: key) : generation.tiles[key],
              tile.renderedVersion != tile.version, tile.inFlightVersion == nil else { continue }
        let elements = scene.elements(in: generation.rect(for: key), plane: plane)
        let signature = Self.signature(of: elements)
        if tile.renderedVersion >= 0, tile.signature == signature {
          // Marked dirty by something that turned out not to reach it (an arrow's bounding box
          // crosses many tiles its line never touches).
          tile.renderedVersion = tile.version
          statistics.tilesConfirmed += 1
          continue
        }
        guard !elements.isEmpty, let cover = generation.cover(of: elements, in: key) else {
          // Nothing here: no bitmap, no layer.
          show(nil, at: .zero, on: tile, in: generation, version: tile.version, signature: signature)
          continue
        }
        if let picture = picture(for: key, signature: signature, outside: generation) {
          show(picture.image, at: picture.rect, on: tile, in: generation, version: tile.version, signature: signature)
          statistics.tilesReused += 1
          continue
        }
        work += 0.000_15 + Double(elements.count) * secondsPerElement
        jobs.append(Job(generation: generation, key: key, tile: tile, rect: cover.rect, pixels: cover.pixels,
                        colorSpace: colorSpace, version: tile.version, zoom: generation.zoom,
                        elements: elements, signature: signature))
      }
    }
    guard !jobs.isEmpty else { return }
    let parallel = Double(min(jobs.count, lanes))
    if inline, work / parallel <= budget {
      paintInline(jobs, parallel: parallel)
    } else {
      paintInBackground(jobs)
    }
  }

  /// A picture of exactly these elements at this spot and scale that another set already holds.
  /// When a gesture starts or ends most of the board has not changed, only which plane shows it.
  private func picture(for key: TileKey, signature: Int,
                       outside generation: Generation) -> (image: CGImage, rect: CGRect)? {
    for other in [current, pending] {
      guard let other, other !== generation, other.rasterScale == generation.rasterScale else { continue }
      for plane in other.planes {
        guard let tile = other.tiles[TileKey(x: key.x, y: key.y, plane: plane)],
              tile.renderedVersion == tile.version, tile.signature == signature,
              let image = tile.image else { continue }
        return (image, tile.imageRect)
      }
    }
    return nil
  }

  private func paintInline(_ jobs: [Job], parallel: Double) {
    let images = self.images
    let start = CFAbsoluteTimeGetCurrent()
    let results = UnsafeMutablePointer<CGImage?>.allocate(capacity: jobs.count)
    results.initialize(repeating: nil, count: jobs.count)
    defer {
      results.deinitialize(count: jobs.count)
      results.deallocate()
    }
    let slots = UncheckedSendableBox(results)
    let work = UncheckedSendableBox(jobs)
    DispatchQueue.concurrentPerform(iterations: jobs.count) { index in
      let item = work.value[index]
      slots.value[index] = BoardRasterizer.tile(item.elements, boardRect: item.rect, pixels: item.pixels,
                                                zoom: item.zoom, images: images, colorSpace: item.colorSpace)
    }
    let elapsed = CFAbsoluteTimeGetCurrent() - start
    var drawn = 0
    for (index, job) in jobs.enumerated() {
      drawn += job.elements.count
      show(results[index], at: job.rect, on: job.tile, in: job.generation, version: job.version,
           signature: job.signature)
    }
    if drawn > 0 {
      let measured = max(elapsed * parallel - 0.000_15 * Double(jobs.count), 0) / Double(drawn)
      secondsPerElement = secondsPerElement * 0.8 + measured * 0.2
    }
    statistics.tilesDrawnInline += jobs.count
    statistics.lastInlineSeconds = elapsed
  }

  private func paintInBackground(_ jobs: [Job]) {
    let images = self.images
    for job in jobs {
      job.tile.inFlightVersion = job.version
      let payload = UncheckedSendableBox(job)
      let operation = BlockOperation()
      operation.addExecutionBlock { [weak self, weak operation] in
        guard operation?.isCancelled == false else { return }
        let job = payload.value
        let start = CFAbsoluteTimeGetCurrent()
        let image = BoardRasterizer.tile(job.elements, boardRect: job.rect, pixels: job.pixels,
                                         zoom: job.zoom, images: images, colorSpace: job.colorSpace)
        let elapsed = CFAbsoluteTimeGetCurrent() - start
        let result = UncheckedSendableBox(image)
        DispatchQueue.main.async {
          self?.finish(payload.value, image: result.value, seconds: elapsed)
        }
      }
      job.tile.operation = operation
      renderQueue.addOperation(operation)
    }
  }

  private func finish(_ job: Job, image: CGImage?, seconds: Double) {
    let began = CFAbsoluteTimeGetCurrent()
    defer { statistics.mainThreadSeconds += CFAbsoluteTimeGetCurrent() - began }
    let tile = job.tile
    tile.inFlightVersion = nil
    tile.operation = nil
    guard job.generation === current || job.generation === pending,
          job.generation.tiles[job.key] === tile else { return }
    statistics.tilesDrawnInBackground += 1
    if !job.elements.isEmpty {
      let measured = max(seconds - 0.000_15, 0) / Double(job.elements.count)
      secondsPerElement = secondsPerElement * 0.9 + measured * 0.1
    }
    CATransaction.begin()
    CATransaction.setDisableActions(true)
    // A result the board has already moved past is still newer than what is showing: put it up
    // and go again, so heavy work trails by a frame instead of freezing.
    if job.version > tile.renderedVersion {
      show(image, at: job.rect, on: tile, in: job.generation, version: job.version, signature: job.signature)
    }
    if job.generation === pending { promoteIfReady() }
    CATransaction.commit()
    if tile.version != job.version { scheduleRefresh() }
  }

  private func show(_ image: CGImage?, at rect: CGRect, on tile: Tile, in generation: Generation,
                    version: Int, signature: Int) {
    tile.renderedVersion = version
    tile.signature = signature
    tile.image = image
    tile.imageRect = rect
    generation.hasPainted = true
    if let image {
      tile.layer.frame = rect
      tile.layer.contents = image
      if tile.layer.superlayer == nil { generation.layer(for: tile.plane).addSublayer(tile.layer) }
    } else if tile.layer.superlayer != nil {
      tile.layer.removeFromSuperlayer()
      tile.layer.contents = nil
    }
  }

  /// Swap in the replacement set once it covers everything on screen — all at once, so no frame
  /// ever shows two scales side by side, an element in two planes, or in none.
  private func promoteIfReady() {
    guard let pending, let outgoing = current else { return }
    let visible = visibleBoardRect
    for plane in pending.planes {
      let keys = pending.keys(in: pending.extent(of: plane, covering: visible), plane: plane)
      if plane == .rest, keys.isEmpty { return }
      guard keys.allSatisfy({ (pending.tiles[$0]?.renderedVersion ?? -1) >= 0 }) else { return }
    }
    container.addSublayer(pending.layer)
    discard(outgoing)
    current = pending
    self.pending = nil
    scheduleRefresh()
  }

  private func discard(_ generation: Generation) {
    for tile in generation.tiles.values { tile.operation?.cancel() }
    generation.layer.removeFromSuperlayer()
  }

  private func evict(_ generation: Generation, keeping visible: CGRect) {
    func keep(_ plane: BoardPlane) -> CGRect {
      generation.extent(of: plane, covering: visible)
        .insetBy(dx: -generation.tileSize * 2, dy: -generation.tileSize * 2)
    }
    let limit = generation.planes.reduce(0) { $0 + generation.keyCount(in: keep($1)) }
    guard limit > 0, generation.tiles.count > limit + limit / 2 else { return }
    var kept = Set<TileKey>()
    for plane in generation.planes { kept.formUnion(generation.keys(in: keep(plane), plane: plane)) }
    for (key, tile) in generation.tiles where !kept.contains(key) {
      tile.operation?.cancel()
      tile.layer.removeFromSuperlayer()
      generation.tiles[key] = nil
    }
  }

  // MARK: Tests and benchmarks

  /// Block until every queued tile has been drawn and shown.
  func waitUntilSettled(timeout: TimeInterval = 10) {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
      renderQueue.waitUntilAllOperationsAreFinished()
      RunLoop.main.run(mode: .default, before: Date().addingTimeInterval(0.002))
      let busy = [current, pending].contains { generation in
        generation?.tiles.values.contains { $0.inFlightVersion != nil } ?? false
      }
      if !busy, pending == nil, !refreshScheduled { return }
    }
  }

  /// Tiles currently holding a bitmap, in `plane` of the set on screen.
  func paintedTileCount(in plane: BoardPlane = .rest) -> Int {
    current?.tiles.reduce(0) { $0 + ($1.key.plane == plane && $1.value.image != nil ? 1 : 0) } ?? 0
  }

  var displayedRasterScale: CGFloat? { current?.rasterScale }
  /// The color spaces of the bitmaps on screen.
  var displayedTileColorSpaces: [CGColorSpace] {
    var spaces: [CGColorSpace] = []
    for tile in current?.tiles.values.map({ $0 }) ?? [] {
      guard let space = tile.image?.colorSpace, !spaces.contains(where: { CFEqual($0, space) }) else { continue }
      spaces.append(space)
    }
    return spaces
  }
  /// The planes the set on screen composites.
  var displayedPlanes: [BoardPlane] { current?.planes ?? [] }
  /// Where the lifted plane of the set on screen sits, in board units.
  var displayedLiftOffset: CGSize { current?.liftOffset ?? .zero }
}

/// Carries a value the compiler cannot prove sendable across a hand-off whose safety is argued at
/// the call site (immutable snapshots, or a buffer each worker writes a distinct slot of).
struct UncheckedSendableBox<Value>: @unchecked Sendable {
  let value: Value
  init(_ value: Value) { self.value = value }
}
