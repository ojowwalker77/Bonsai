import Foundation
import CoreGraphics

/// Pure board-space snapping for card drags on the infinite canvas.
///
/// The engine is deterministic and has no UI, actor, or persistence dependency. It compares the
/// moved card's min, mid, and max anchors against every non-empty peer rect, then returns the
/// adjusted drag delta and merged guide lines for the alignments produced by that snap.
///
/// A drag asks the same question of the same peers every frame, so the peers are indexed once
/// (`Peers`: their anchors sorted per axis) and each frame only visits the anchors within reach of
/// the moving rect — a drag's snapping cost does not grow with the board.
enum SnapEngine {
  enum Axis: Equatable { case horizontal, vertical }

  struct Guide: Equatable {
    /// `.vertical` is a line at `x == position`; `.horizontal` is a line at `y == position`.
    let axis: Axis
    /// Board-space coordinate of the guide line.
    let position: CGFloat
    /// Minimum span coordinate along the guide line.
    let start: CGFloat
    /// Maximum span coordinate along the guide line.
    let end: CGFloat
  }

  struct Result: Equatable {
    let delta: CGSize
    let guides: [Guide]
  }

  /// The peer rects of one drag, indexed for lookup by anchor position.
  struct Peers {
    fileprivate struct Anchor {
      var value: CGFloat
      /// Index into `rects`.
      var peer: Int
      /// 0 = min, 1 = mid, 2 = max.
      var index: Int
    }

    fileprivate let rects: [CGRect]
    /// x anchors (they snap `.vertical` guides) and y anchors, each sorted by value.
    private let xAnchors: [Anchor]
    private let yAnchors: [Anchor]

    var isEmpty: Bool { rects.isEmpty }

    /// Empty or non-finite rects are skipped, so callers can pass the board's raw frame list.
    init(_ others: [CGRect]) {
      let rects = others.compactMap(SnapEngine.validRect)
      var xs: [Anchor] = [], ys: [Anchor] = []
      xs.reserveCapacity(rects.count * 3)
      ys.reserveCapacity(rects.count * 3)
      for (peer, rect) in rects.enumerated() {
        let x = SnapEngine.anchors(for: .vertical, in: rect)
        let y = SnapEngine.anchors(for: .horizontal, in: rect)
        for index in 0..<3 {
          xs.append(Anchor(value: x.value(at: index), peer: peer, index: index))
          ys.append(Anchor(value: y.value(at: index), peer: peer, index: index))
        }
      }
      xs.sort { $0.value < $1.value }
      ys.sort { $0.value < $1.value }
      self.rects = rects
      xAnchors = xs
      yAnchors = ys
    }

    /// The anchors on `axis` within `reach` of `value`, plus a hair either side: callers apply
    /// their exact inclusion test, this only narrows what they look at.
    fileprivate func anchors(on axis: Axis, near value: CGFloat, reach: CGFloat) -> ArraySlice<Anchor> {
      let sorted = axis == .vertical ? xAnchors : yAnchors
      guard value.isFinite, reach.isFinite else { return sorted[...] }
      let slack = reach + max(abs(value), 1) * 1e-9
      let low = value - slack, high = value + slack
      var lower = 0, upper = sorted.count
      while lower < upper {
        let middle = (lower + upper) / 2
        if sorted[middle].value < low { lower = middle + 1 } else { upper = middle }
      }
      let start = lower
      upper = sorted.count
      while lower < upper {
        let middle = (lower + upper) / 2
        if sorted[middle].value <= high { lower = middle + 1 } else { upper = middle }
      }
      return sorted[start..<lower]
    }
  }

  /// Snaps `moving.offsetBy(proposedDelta)` to nearby peer edges or centers.
  ///
  /// X and Y are solved independently. Candidates must be within `tolerance`; exact-boundary
  /// candidates are included. Empty or non-finite peer rects are skipped so drag-time callers can
  /// pass the board's raw frame list without pre-filtering.
  static func snap(
    moving: CGRect,
    proposedDelta: CGSize,
    others: [CGRect],
    tolerance: CGFloat
  ) -> Result {
    snap(moving: moving, proposedDelta: proposedDelta, peers: Peers(others), tolerance: tolerance)
  }

  /// The same snap against peers indexed once for the whole drag.
  static func snap(
    moving: CGRect,
    proposedDelta: CGSize,
    peers: Peers,
    tolerance: CGFloat
  ) -> Result {
    guard tolerance >= 0 else {
      return Result(delta: proposedDelta, guides: [])
    }

    guard !peers.isEmpty else {
      return Result(delta: proposedDelta, guides: [])
    }

    let moved = moving.standardized.offsetBy(dx: proposedDelta.width, dy: proposedDelta.height)
    let xSnap = bestSnap(for: .vertical, moving: moved, others: peers, tolerance: tolerance)
    let ySnap = bestSnap(for: .horizontal, moving: moved, others: peers, tolerance: tolerance)
    let adjustedDelta = CGSize(
      width: proposedDelta.width + (xSnap?.adjustment ?? 0),
      height: proposedDelta.height + (ySnap?.adjustment ?? 0)
    )

    guard xSnap != nil || ySnap != nil else {
      return Result(delta: proposedDelta, guides: [])
    }

    let snapped = moving.standardized.offsetBy(dx: adjustedDelta.width, dy: adjustedDelta.height)
    var guides: [Guide] = []
    if xSnap != nil {
      guides.append(contentsOf: guideLines(for: .vertical, moving: snapped, others: peers))
    }
    if ySnap != nil {
      guides.append(contentsOf: guideLines(for: .horizontal, moving: snapped, others: peers))
    }

    return Result(delta: adjustedDelta, guides: guides)
  }

  private struct Candidate {
    let adjustment: CGFloat
    let absoluteAdjustment: CGFloat
    let centerDistanceSquared: CGFloat
    let otherIndex: Int
    let movingAnchorIndex: Int
    let otherAnchorIndex: Int
  }

  private struct AnchorSet {
    let min: CGFloat
    let mid: CGFloat
    let max: CGFloat

    func value(at index: Int) -> CGFloat {
      switch index {
      case 0:
        return min
      case 1:
        return mid
      default:
        return max
      }
    }
  }

  private static func bestSnap(
    for axis: Axis,
    moving: CGRect,
    others: Peers,
    tolerance: CGFloat
  ) -> Candidate? {
    let movingAnchors = anchors(for: axis, in: moving)
    var best: Candidate?

    // `isBetter` is a total order, so the winner does not depend on the order candidates are met.
    for movingAnchorIndex in 0..<3 {
      let movingValue = movingAnchors.value(at: movingAnchorIndex)
      for anchor in others.anchors(on: axis, near: movingValue, reach: tolerance) {
        let adjustment = anchor.value - movingValue
        let absoluteAdjustment = abs(adjustment)
        guard absoluteAdjustment <= tolerance else { continue }

        let candidate = Candidate(
          adjustment: adjustment,
          absoluteAdjustment: absoluteAdjustment,
          centerDistanceSquared: centerDistanceSquared(from: moving, to: others.rects[anchor.peer]),
          otherIndex: anchor.peer,
          movingAnchorIndex: movingAnchorIndex,
          otherAnchorIndex: anchor.index
        )

        if isBetter(candidate, than: best) {
          best = candidate
        }
      }
    }

    return best
  }

  private static func isBetter(_ candidate: Candidate, than best: Candidate?) -> Bool {
    guard let best else { return true }
    if candidate.absoluteAdjustment != best.absoluteAdjustment {
      return candidate.absoluteAdjustment < best.absoluteAdjustment
    }
    if candidate.centerDistanceSquared != best.centerDistanceSquared {
      return candidate.centerDistanceSquared < best.centerDistanceSquared
    }
    if candidate.otherIndex != best.otherIndex {
      return candidate.otherIndex < best.otherIndex
    }
    if candidate.movingAnchorIndex != best.movingAnchorIndex {
      return candidate.movingAnchorIndex < best.movingAnchorIndex
    }
    return candidate.otherAnchorIndex < best.otherAnchorIndex
  }

  private static func guideLines(for axis: Axis, moving: CGRect, others: Peers) -> [Guide] {
    var guides: [Guide] = []
    let movingAnchors = anchors(for: axis, in: moving)

    for anchorIndex in 0..<3 {
      let position = movingAnchors.value(at: anchorIndex)
      guard !containsGuide(in: guides, axis: axis, position: position) else { continue }

      var start = perpendicularMin(for: axis, in: moving)
      var end = perpendicularMax(for: axis, in: moving)
      var foundPeer = false

      // A peer aligns when any of its anchors sits on the line.
      for anchor in others.anchors(on: axis, near: position, reach: 0.5)
      where abs(anchor.value - position) <= 0.5 {
        let other = others.rects[anchor.peer]
        foundPeer = true
        start = min(start, perpendicularMin(for: axis, in: other))
        end = max(end, perpendicularMax(for: axis, in: other))
      }

      if foundPeer {
        guides.append(Guide(axis: axis, position: position, start: start, end: end))
      }
    }

    return guides
  }

  private static func anchors(for axis: Axis, in rect: CGRect) -> AnchorSet {
    switch axis {
    case .vertical:
      return AnchorSet(min: rect.minX, mid: rect.midX, max: rect.maxX)
    case .horizontal:
      return AnchorSet(min: rect.minY, mid: rect.midY, max: rect.maxY)
    }
  }

  private static func perpendicularMin(for axis: Axis, in rect: CGRect) -> CGFloat {
    switch axis {
    case .vertical:
      return rect.minY
    case .horizontal:
      return rect.minX
    }
  }

  private static func perpendicularMax(for axis: Axis, in rect: CGRect) -> CGFloat {
    switch axis {
    case .vertical:
      return rect.maxY
    case .horizontal:
      return rect.maxX
    }
  }

  private static func containsGuide(in guides: [Guide], axis: Axis, position: CGFloat) -> Bool {
    guides.contains { $0.axis == axis && abs($0.position - position) <= 0.5 }
  }

  private static func centerDistanceSquared(from lhs: CGRect, to rhs: CGRect) -> CGFloat {
    let dx = lhs.midX - rhs.midX
    let dy = lhs.midY - rhs.midY
    return dx * dx + dy * dy
  }

  private static func validRect(_ rect: CGRect) -> CGRect? {
    let rect = rect.standardized
    guard rect.width > 0, rect.height > 0,
          rect.minX.isFinite, rect.minY.isFinite,
          rect.maxX.isFinite, rect.maxY.isFinite else { return nil }
    return rect
  }
}
