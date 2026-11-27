import CoreGraphics
import Foundation

/// What the renderer needs to know about the board at one instant.
struct BoardSceneInput {
  var cards: [CardState]
  /// Bumped by the model whenever `cards` changes; an unchanged revision skips the full diff.
  var cardsRevision: Int
  /// In-flight gesture replacements (resized, rerouted), by id.
  var preview: [UUID: CardState] = [:]
  /// The cards a move is carrying, all translated by `moveOffset`. `movedToken` names the set.
  var moved: Set<UUID> = []
  var movedToken = 0
  var moveOffset: CGSize = .zero
  var textPreviewScales: [UUID: CGFloat] = [:]
  /// Elements a live editor is drawing instead (inline text, the pen-path node editor).
  var hidden: Set<UUID> = []
  var dropTarget: UUID?
  /// Graphs whose legend the interactive overlay draws.
  var legendHidden: Set<UUID> = []
  /// Anything else that changes what cards resolve to (the editing session, a text revision).
  var contentToken: Int = 0
  var style: RenderStyle
  var text: (CardState) -> String
  var ink: (CardState) -> [InkRun]
}

/// Where an element is composited.
///
/// A gesture changes a few elements on every frame. Giving those elements planes of their own
/// means a frame of the gesture redraws only them — never the board they are passing over, which
/// is what made a drag across a dense board cost as much as the board.
enum BoardPlane: Int, CaseIterable, Sendable {
  /// Everything at rest.
  case rest
  /// Elements a gesture is reshaping — a resize, an arrow following a moved shape. Redrawn each
  /// frame, alone.
  case live
  /// Elements a move is carrying. Drawn once where they started, then slid as one layer.
  case lifted
}

/// A rectangle of one plane whose pixels may have changed.
struct BoardDirt {
  var rect: CGRect
  var plane: BoardPlane
}

/// The board resolved into drawable elements, kept in step with the model by diffing.
///
/// Each sync returns what may have changed on screen, so the tile cache repaints only that. A
/// gesture touches a handful of elements, so its per-frame cost is independent of how many
/// elements the board holds; a move touches none at all (see `BoardPlane.lifted`).
@MainActor
final class BoardScene {
  private(set) var elements: [UUID: RenderElement] = [:]
  private var index = SpatialGrid()
  private var cardSlots: [UUID: Int] = [:]
  private var cards: [CardState] = []
  private var cardsRevision = -1
  private var contentToken = 0
  private var style: RenderStyle?
  private var hidden: Set<UUID> = []
  private var lastPreview: [UUID: CardState] = [:]
  private var lastTextScales: [UUID: CGFloat] = [:]
  private var lastDropTarget: UUID?
  private var lastLegendHidden: Set<UUID> = []
  private var live: Set<UUID> = []
  private var lifted: Set<UUID> = []
  private var liftedToken = 0
  /// How far the lifted plane has been carried, in board units.
  private(set) var liftOffset: CGSize = .zero
  /// Names the current split of elements between planes: bumped whenever an element changes
  /// plane. The renderer draws a new split beside the old one and swaps them whole.
  private(set) var arrangement = 0
  /// Bumped on every sync that changed pixels.
  private(set) var revision = 0

  var count: Int { elements.count }
  /// The union of everything paintable, or nil for an empty board.
  var contentBounds: CGRect? { index.bounds }

  func plane(of id: UUID) -> BoardPlane {
    if !live.isEmpty, live.contains(id) { return .live }
    if !lifted.isEmpty, lifted.contains(id) { return .lifted }
    return .rest
  }

  /// Whether anything is composited in `plane` under the current arrangement.
  func uses(_ plane: BoardPlane) -> Bool {
    switch plane {
    case .rest: true
    case .live: !live.isEmpty
    case .lifted: !lifted.isEmpty
    }
  }

  /// Bring the scene up to date. Returns what may have changed, or nil when everything did (first
  /// sync, theme or typography change).
  func sync(_ input: BoardSceneInput) -> [BoardDirt]? {
    let styleChanged = style !== input.style
    let full = styleChanged || cardsRevision != input.cardsRevision || contentToken != input.contentToken
    var dirty: [BoardDirt] = []

    // Which plane each element is in. A change here is a new arrangement, not dirt.
    let previewChanged = input.preview != lastPreview
    let scalesChanged = input.textPreviewScales != lastTextScales
    let previousLive = live
    var rearranged = false
    if input.movedToken != liftedToken {
      lifted = input.moved
      liftedToken = input.movedToken
      rearranged = true
    }
    if previewChanged || scalesChanged {
      var reshaped = Set(input.preview.keys)
      reshaped.formUnion(input.textPreviewScales.keys)
      if reshaped != live {
        live = reshaped
        rearranged = true
      }
    }
    if rearranged { arrangement += 1 }
    liftOffset = input.moveOffset

    func variant(for id: UUID) -> RenderElement.Variant {
      RenderElement.Variant(textPreviewScale: input.textPreviewScales[id] ?? 1,
                            isDropTarget: input.dropTarget == id,
                            hidesLegend: input.legendHidden.contains(id))
    }

    func resolve(_ committed: CardState, slot: Int) {
      // A lifted element stays drawn where it started; its plane carries it.
      let card = input.preview[committed.id] ?? committed
      let text = Self.usesText(card.elementKind) ? input.text(card) : ""
      let ink = card.elementKind == .text ? input.ink(card) : []
      let variant = variant(for: card.id)
      let previous = elements[card.id]
      if let previous, previous.matches(card: card, text: text, ink: ink, variant: variant, style: input.style) {
        previous.order = slot
        return
      }
      let element = RenderElement(card: card, text: text, ink: ink, variant: variant, style: input.style,
                                  reusing: previous)
      element.order = slot
      let plane = plane(of: card.id)
      if let previous {
        index.remove(previous)
        dirty.append(BoardDirt(rect: previous.paintBounds, plane: plane))
      }
      elements[card.id] = element
      index.insert(element)
      dirty.append(BoardDirt(rect: element.paintBounds, plane: plane))
    }

    if full {
      var seen = Set<UUID>(minimumCapacity: input.cards.count)
      var slots: [UUID: Int] = [:]
      slots.reserveCapacity(input.cards.count)
      for (slot, card) in input.cards.enumerated() {
        seen.insert(card.id)
        slots[card.id] = slot
        resolve(card, slot: slot)
      }
      if seen.count != elements.count {
        for (id, element) in elements where !seen.contains(id) {
          index.remove(element)
          dirty.append(BoardDirt(rect: element.paintBounds, plane: plane(of: id)))
          elements[id] = nil
        }
      }
      cards = input.cards
      cardSlots = slots
      cardsRevision = input.cardsRevision
      contentToken = input.contentToken
      style = input.style
    } else {
      // Only presentation state moved: revisit the elements it touches, old and new.
      var touched = Set<UUID>()
      if previewChanged || scalesChanged {
        touched.formUnion(previousLive)
        touched.formUnion(live)
      }
      if input.dropTarget != lastDropTarget {
        if let old = lastDropTarget { touched.insert(old) }
        if let new = input.dropTarget { touched.insert(new) }
      }
      if input.legendHidden != lastLegendHidden {
        touched.formUnion(lastLegendHidden.symmetricDifference(input.legendHidden))
      }
      for id in touched {
        guard let slot = cardSlots[id], cards.indices.contains(slot) else { continue }
        resolve(cards[slot], slot: slot)
      }
    }

    if input.hidden != hidden {
      for id in hidden.symmetricDifference(input.hidden) {
        if let element = elements[id] { dirty.append(BoardDirt(rect: element.paintBounds, plane: plane(of: id))) }
      }
      hidden = input.hidden
    }
    lastPreview = input.preview
    lastTextScales = input.textPreviewScales
    lastDropTarget = input.dropTarget
    lastLegendHidden = input.legendHidden

    if styleChanged {
      revision += 1
      return nil
    }
    if !dirty.isEmpty || rearranged { revision += 1 }
    return dirty
  }

  /// The elements of `plane` that paint into `rect`, back to front.
  func elements(in rect: CGRect, plane: BoardPlane = .rest) -> [RenderElement] {
    var found: [RenderElement]
    switch plane {
    case .rest:
      found = index.query(rect)
      let split = !(live.isEmpty && lifted.isEmpty)
      found.removeAll { !$0.paints(in: rect) || (split && self.plane(of: $0.card.id) != .rest) }
    case .live, .lifted:
      let members = plane == .live ? live : lifted
      if members.count <= 64 {
        // A gesture's own few elements: look at them, not at the board.
        found = members.compactMap { elements[$0] }.filter { $0.paints(in: rect) }
      } else {
        found = index.query(rect).filter { self.plane(of: $0.card.id) == plane && $0.paints(in: rect) }
      }
    }
    if !hidden.isEmpty { found.removeAll { hidden.contains($0.card.id) } }
    found.sort { a, b in
      a.card.z != b.card.z ? a.card.z < b.card.z : a.order < b.order
    }
    return found
  }

  private static func usesText(_ kind: CanvasElementKind) -> Bool {
    switch kind {
    case .text, .rectangle, .ellipse, .diamond, .line, .arrow, .sticky: true
    default: false
    }
  }
}

/// A uniform grid over board space. Elements land in every cell their paint bounds touch; the few
/// that would span a great many cells (a board-wide stroke) are kept in a short list instead.
struct SpatialGrid {
  static let cellSize: CGFloat = 512
  private static let largeThreshold = 256

  private struct Cell: Hashable {
    var x: Int32
    var y: Int32
  }

  private var cells: [Cell: [RenderElement]] = [:]
  private var large: [RenderElement] = []
  private var stamp = 0
  private var stamps: [ObjectIdentifier: Int] = [:]
  private var extent: CGRect?
  private var extentIsStale = false
  private var population = 0

  /// The union of all paint bounds (recomputed lazily after removals).
  var bounds: CGRect? {
    mutating get {
      if extentIsStale {
        var union: CGRect?
        var seen = Set<ObjectIdentifier>()
        for element in large where seen.insert(ObjectIdentifier(element)).inserted {
          union = union?.union(element.paintBounds) ?? element.paintBounds
        }
        for list in cells.values {
          for element in list where seen.insert(ObjectIdentifier(element)).inserted {
            union = union?.union(element.paintBounds) ?? element.paintBounds
          }
        }
        extent = union
        extentIsStale = false
      }
      return extent
    }
  }

  private static func range(_ rect: CGRect) -> (x: ClosedRange<Int32>, y: ClosedRange<Int32>)? {
    guard rect.width.isFinite, rect.height.isFinite, rect.minX.isFinite, rect.minY.isFinite,
          !rect.isNull else { return nil }
    func cell(_ value: CGFloat) -> Int32 {
      Int32(max(min((value / cellSize).rounded(.down), 1_000_000), -1_000_000))
    }
    return (cell(rect.minX)...cell(rect.maxX), cell(rect.minY)...cell(rect.maxY))
  }

  mutating func insert(_ element: RenderElement) {
    guard let range = Self.range(element.paintBounds) else { return }
    population += 1
    if !extentIsStale { extent = extent?.union(element.paintBounds) ?? element.paintBounds }
    if range.x.count * range.y.count > Self.largeThreshold {
      large.append(element)
      return
    }
    for y in range.y {
      for x in range.x {
        cells[Cell(x: x, y: y), default: []].append(element)
      }
    }
  }

  mutating func remove(_ element: RenderElement) {
    guard let range = Self.range(element.paintBounds) else { return }
    population -= 1
    extentIsStale = true
    if population == 0 {
      extent = nil
      extentIsStale = false
    }
    if range.x.count * range.y.count > Self.largeThreshold {
      large.removeAll { $0 === element }
      return
    }
    for y in range.y {
      for x in range.x {
        let cell = Cell(x: x, y: y)
        guard var list = cells[cell] else { continue }
        list.removeAll { $0 === element }
        cells[cell] = list.isEmpty ? nil : list
      }
    }
  }

  /// Every element whose paint bounds intersect `rect`, in no particular order.
  mutating func query(_ rect: CGRect) -> [RenderElement] {
    var found: [RenderElement] = []
    for element in large where element.paintBounds.intersects(rect) { found.append(element) }
    guard let range = Self.range(rect) else { return found }
    // A query wider than the populated grid walks the cells that exist instead of every cell.
    if range.x.count * range.y.count > cells.count {
      var seen = Set<ObjectIdentifier>()
      for list in cells.values {
        for element in list where element.paintBounds.intersects(rect) && seen.insert(ObjectIdentifier(element)).inserted {
          found.append(element)
        }
      }
      return found
    }
    if range.x.count == 1, range.y.count == 1 {
      for element in cells[Cell(x: range.x.lowerBound, y: range.y.lowerBound)] ?? [] where element.paintBounds.intersects(rect) {
        found.append(element)
      }
      return found
    }
    stamp += 1
    for y in range.y {
      for x in range.x {
        for element in cells[Cell(x: x, y: y)] ?? [] {
          let id = ObjectIdentifier(element)
          guard stamps[id] != stamp else { continue }
          stamps[id] = stamp
          if element.paintBounds.intersects(rect) { found.append(element) }
        }
      }
    }
    if stamps.count > 4_096 { stamps.removeAll(keepingCapacity: true) }
    return found
  }
}
