import AppKit

/// Turns elements into pixels. Pure Core Graphics over immutable inputs: safe on any thread, and
/// the one code path behind both the on-screen tiles and the exported PNG.
enum BoardRasterizer {
  /// Rasterize `boardRect` into a `pixelSize` bitmap.
  ///
  /// The bitmap is drawn WITHOUT a vertical flip: board +y runs up the bitmap. On screen the board
  /// layer mirrors tiles back; `image(of:)` below mirrors the finished bitmap for export.
  static func render(_ elements: [RenderElement],
                     boardRect: CGRect,
                     pixelSize: CGSize,
                     zoom: CGFloat,
                     images: any RenderImageSource,
                     background: CGColor? = nil,
                     colorSpace: CGColorSpace = RenderBitmap.colorSpace) -> CGContext? {
    let width = Int(pixelSize.width.rounded()), height = Int(pixelSize.height.rounded())
    guard boardRect.width > 0, boardRect.height > 0,
          let context = RenderBitmap.context(width: width, height: height, space: colorSpace) else { return nil }
    if let background {
      context.setFillColor(background)
      context.fill(CGRect(x: 0, y: 0, width: width, height: height))
    }
    let scaleX = CGFloat(width) / boardRect.width, scaleY = CGFloat(height) / boardRect.height
    context.scaleBy(x: scaleX, y: scaleY)
    context.translateBy(x: -boardRect.minX, y: -boardRect.minY)
    let environment = RenderEnvironment(pixelScale: scaleX, zoom: zoom, images: images)
    for element in elements where element.paintBounds.intersects(boardRect) {
      element.draw(in: context, environment: environment)
    }
    return context
  }

  /// The bitmap of one tile — or of the part of it its elements reach — or nil when nothing paints
  /// into it.
  static func tile(_ elements: [RenderElement], boardRect: CGRect, pixels: (width: Int, height: Int),
                   zoom: CGFloat, images: any RenderImageSource, colorSpace: CGColorSpace) -> CGImage? {
    guard !elements.isEmpty else { return nil }
    return render(elements, boardRect: boardRect, pixelSize: CGSize(width: pixels.width, height: pixels.height),
                  zoom: zoom, images: images, colorSpace: colorSpace)?.makeImage()
  }

  /// The upright image of `boardRect` at `scale` pixels per board unit (export, tests).
  static func image(of elements: [RenderElement], boardRect: CGRect, scale: CGFloat, zoom: CGFloat = 1,
                    images: any RenderImageSource, background: CGColor?) -> CGImage? {
    let size = CGSize(width: max((boardRect.width * scale).rounded(), 1), height: max((boardRect.height * scale).rounded(), 1))
    guard let mirrored = render(elements, boardRect: boardRect, pixelSize: size, zoom: zoom,
                                images: images, background: background)?.makeImage(),
          let upright = RenderBitmap.context(width: mirrored.width, height: mirrored.height) else { return nil }
    upright.translateBy(x: 0, y: CGFloat(mirrored.height))
    upright.scaleBy(x: 1, y: -1)
    upright.interpolationQuality = .none
    upright.draw(mirrored, in: CGRect(x: 0, y: 0, width: mirrored.width, height: mirrored.height))
    return upright.makeImage()
  }

  /// Resolve `cards` into elements in paint order without a live scene (export, previews).
  @MainActor
  static func elements(for cards: [CardState], style: RenderStyle,
                       text: (CardState) -> String, ink: (CardState) -> [InkRun]) -> [RenderElement] {
    cards.enumerated()
      .sorted { a, b in a.element.z != b.element.z ? a.element.z < b.element.z : a.offset < b.offset }
      .map { RenderElement(card: $0.element, text: text($0.element), ink: ink($0.element),
                           variant: .init(), style: style) }
  }
}
