import AppKit

/// Exports the current board to an image file: content-bounds math, the render (through the board
/// renderer, at 100%), the save panel, and PNG encoding.
enum BoardExporter {
  /// Uniform margin painted around the content on every side (board points).
  static let margin: CGFloat = 64

  /// The tight bounding box of every card on the board (board coordinates), or nil when empty.
  static func contentBounds(of cards: [CardState]) -> CGRect? {
    guard !cards.isEmpty else { return nil }
    let minX = cards.map(\.x).min() ?? 0
    let minY = cards.map(\.y).min() ?? 0
    let maxX = cards.map { $0.x + $0.w }.max() ?? 0
    let maxY = cards.map { $0.y + $0.h }.max() ?? 0
    return CGRect(x: minX, y: minY, width: max(maxX - minX, 1), height: max(maxY - minY, 1))
  }

  /// The content bounds expanded by the export margin on all sides.
  static func exportBounds(of cards: [CardState]) -> CGRect? {
    contentBounds(of: cards)?.insetBy(dx: -margin, dy: -margin)
  }

  /// Decode a card image at full resolution for the export render. Cards persist attachment names
  /// relative to `AssetStore`, while legacy cards may still carry absolute paths; resolving through
  /// the same store seam as the live canvas supports both. Synchronous on purpose: the offscreen
  /// render can't wait on the canvas's async thumbnail cache.
  static func loadImage(storedPath path: String) -> NSImage? {
    guard let url = AssetStore.resolve(path) else { return nil }
    return NSImage(contentsOf: url)
  }

  /// Pixel scale of the exported PNG (2× for retina-crisp text).
  static let renderScale: CGFloat = 2

  /// Render the whole board to an `NSImage` and return it, or nil on failure (already reported).
  ///
  /// The export is drawn by the SAME renderer as the screen (`BoardRasterizer`) at 100% zoom, so a
  /// PNG is exactly the board: no offscreen window, no view hierarchy, nothing that can render a
  /// placeholder instead of an element. Images decode at full resolution up front.
  @MainActor
  static func renderBoardImage(cards: [CardState], board: BoardViewModel) -> NSImage? {
    let renderCards = board.renderingSnapshot(for: cards)
    guard let bounds = exportBounds(of: renderCards) else { return nil }
    let style = RenderStyle.current
    let elements = BoardRasterizer.elements(for: renderCards, style: style,
                                            text: { board.renderText(for: $0) },
                                            ink: { board.ink(for: $0) })
    guard let rendered = BoardRasterizer.image(of: elements, boardRect: bounds, scale: renderScale,
                                               images: PreloadedImageSource(cards: renderCards),
                                               background: style.canvas) else {
      UserFacingError.report("BonsAI could not allocate a bitmap to render the board for export.".localizedUI)
      return nil
    }
    // Points stay the board's size; the pixels are `renderScale` times denser.
    let rep = NSBitmapImageRep(cgImage: rendered)
    rep.size = bounds.size
    let image = NSImage(size: bounds.size)
    image.addRepresentation(rep)
    return image
  }

  /// The active flavor's canvas base as an `NSColor` in a concrete RGB space (so `cgColor` and the
  /// window background are well-defined and tests can compare exact channel values).
  @MainActor
  static func resolvedCanvasColor() -> NSColor {
    let base = Theme.flavor.base
    return base.usingColorSpace(.sRGB) ?? base
  }

  /// Present a Save panel as a sheet on the key window and, on confirm, write `image` as a PNG.
  @MainActor
  static func presentSavePanel(image: NSImage, suggestedName: String) {
    let panel = NSSavePanel()
    panel.allowedContentTypes = [.png]
    panel.canCreateDirectories = true
    panel.nameFieldStringValue = sanitizedFileName(suggestedName) + ".png"
    panel.title = "Export Board".localizedUI
    panel.message = "Export this board as a PNG image.".localizedUI

    let apply: (NSApplication.ModalResponse) -> Void = { response in
      if response == .OK, let url = panel.url { write(image: image, to: url) }
    }
    if let window = NSApp.keyWindow {
      panel.beginSheetModal(for: window, completionHandler: apply)
    } else {
      apply(panel.runModal())
    }
  }

  /// Write `image` onto the general pasteboard so it can be pasted into Slack, a PR, etc. Writes both
  /// the NSImage (TIFF, via `writeObjects`) and an explicit PNG data rep, so every paste target — from
  /// browsers that want `public.png` to apps that read TIFF — accepts it.
  static func copyToPasteboard(image: NSImage) {
    let pasteboard = NSPasteboard.general
    pasteboard.clearContents()
    pasteboard.writeObjects([image])
    if let tiff = image.tiffRepresentation,
       let rep = NSBitmapImageRep(data: tiff),
       let png = rep.representation(using: .png, properties: [:]) {
      pasteboard.setData(png, forType: .png)
    }
  }

  /// Encode `image` to PNG and write it to `url` (same TIFF → bitmap → PNG path as pasted-image save).
  private static func write(image: NSImage, to url: URL) {
    guard let tiff = image.tiffRepresentation,
          let rep = NSBitmapImageRep(data: tiff),
          let png = rep.representation(using: .png, properties: [:]) else {
      UserFacingError.report("BonsAI could not convert the board into PNG data. The board was not exported.".localizedUI)
      return
    }
    do {
      try png.write(to: url)
    } catch {
      UserFacingError.report(error, while: "Exporting the board as PNG".localizedUI)
    }
  }

  /// Strip path-hostile characters so a board title is a safe file name; never empty.
  private static func sanitizedFileName(_ raw: String) -> String {
    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    let cleaned = trimmed
      .replacingOccurrences(of: "/", with: "-")
      .replacingOccurrences(of: ":", with: "-")
      .replacingOccurrences(of: "\n", with: " ")
    return cleaned.isEmpty ? "Board".localizedUI : String(cleaned.prefix(80))
  }
}
