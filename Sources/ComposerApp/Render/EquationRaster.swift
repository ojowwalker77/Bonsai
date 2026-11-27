import AppKit
import SwiftMath

/// Bitmap targets shared by everything the renderer rasterizes.
enum RenderBitmap {
  static let colorSpace = CGColorSpace(name: CGColorSpace.sRGB) ?? CGColorSpaceCreateDeviceRGB()

  /// A transparent, premultiplied BGRA context. `space` is sRGB for anything that leaves the app
  /// (export) and the window's own color space for what goes on screen: see
  /// `BoardRenderView.tileColorSpace`.
  static func context(width: Int, height: Int, space: CGColorSpace = colorSpace) -> CGContext? {
    guard width > 0, height > 0 else { return nil }
    let layout = CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue
    return CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                     space: space, bitmapInfo: layout)
      // A space no bitmap can be made in (not RGB, input-only): draw in sRGB and let it be matched.
      ?? (space === colorSpace ? nil : CGContext(data: nil, width: width, height: height, bitsPerComponent: 8,
                                                 bytesPerRow: 0, space: colorSpace, bitmapInfo: layout))
  }
}

/// LaTeX typeset by SwiftMath and rasterized for the board renderer at the resolution the current
/// zoom needs. Results are shared by every element showing the same equation.
enum EquationRaster {
  /// SwiftMath's font manager and list builder keep unsynchronized shared state. Everything that
  /// typesets — here and the editing stage's preview — holds this lock.
  static let lock = NSLock()
  static let baseFontSize: CGFloat = 24

  private final class Typeset {
    let image: NSImage?
    let size: CGSize
    init(image: NSImage?, size: CGSize) {
      self.image = image
      self.size = size
    }
  }

  private final class Raster {
    let image: CGImage
    init(_ image: CGImage) { self.image = image }
  }

  private static let typesets: NSCache<NSString, Typeset> = {
    let cache = NSCache<NSString, Typeset>()
    cache.countLimit = 512
    return cache
  }()

  private static let rasters: NSCache<NSString, Raster> = {
    let cache = NSCache<NSString, Raster>()
    cache.totalCostLimit = 96 * 1_024 * 1_024
    return cache
  }()

  private static func key(_ latex: String, _ color: CGColor) -> String {
    let components = (color.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",")
    return "\(components)|\(latex)"
  }

  private static func typeset(latex: String, color: CGColor) -> Typeset {
    let cacheKey = key(latex, color) as NSString
    if let cached = typesets.object(forKey: cacheKey) { return cached }
    lock.lock()
    defer { lock.unlock() }
    if let cached = typesets.object(forKey: cacheKey) { return cached }
    let ink = NSColor(cgColor: color) ?? NSColor(srgbRed: 0.5, green: 0.5, blue: 0.5, alpha: 1)
    let math = MTMathImage(latex: latex, fontSize: baseFontSize, textColor: ink,
                           labelMode: .display, textAlignment: .center)
    let (error, image) = math.asImage()
    let result: Typeset
    if error == nil, let image, image.size.width > 0, image.size.height > 0 {
      image.cacheMode = .never
      result = Typeset(image: image, size: image.size)
    } else {
      result = Typeset(image: nil, size: .zero)
    }
    typesets.setObject(result, forKey: cacheKey)
    return result
  }

  /// The equation's size typeset at `baseFontSize`, or nil when the LaTeX does not parse.
  static func naturalSize(latex: String, color: CGColor) -> CGSize? {
    let result = typeset(latex: latex, color: color)
    return result.image == nil ? nil : result.size
  }

  /// The equation rasterized at no less than `pixelsPerPoint` device pixels per typeset point.
  /// Resolution moves in √2 steps, so a zoom re-rasterizes only when it crosses one.
  static func image(latex: String, color: CGColor, pixelsPerPoint: CGFloat) -> CGImage? {
    let source = typeset(latex: latex, color: color)
    guard let vector = source.image else { return nil }
    var scale = pow(2, (log2(max(pixelsPerPoint, 0.05)) * 2).rounded(.up) / 2)
    scale = min(scale, 4_096 / max(source.size.width, source.size.height, 1))
    let cacheKey = "\(String(format: "%.3f", scale))|\(key(latex, color))" as NSString
    if let cached = rasters.object(forKey: cacheKey) { return cached.image }
    lock.lock()
    defer { lock.unlock() }
    if let cached = rasters.object(forKey: cacheKey) { return cached.image }
    let width = max(Int((source.size.width * scale).rounded(.up)), 1)
    let height = max(Int((source.size.height * scale).rounded(.up)), 1)
    guard let context = RenderBitmap.context(width: width, height: height) else { return nil }
    context.scaleBy(x: CGFloat(width) / source.size.width, y: CGFloat(height) / source.size.height)
    // SwiftMath draws through AppKit (NSColor.set, NSBezierPath), which targets the calling
    // thread's current graphics context.
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: context, flipped: false)
    vector.draw(in: CGRect(origin: .zero, size: source.size))
    NSGraphicsContext.restoreGraphicsState()
    guard let image = context.makeImage() else { return nil }
    rasters.setObject(Raster(image), forKey: cacheKey, cost: width * height * 4)
    return image
  }
}
