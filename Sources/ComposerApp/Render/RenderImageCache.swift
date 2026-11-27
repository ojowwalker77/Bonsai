import AppKit
import ImageIO

/// Where the renderer gets an image element's pixels.
protocol RenderImageSource: Sendable {
  /// A decoded image for `path` at least `minPixelSize` on its longer side when available, or nil
  /// while it is still loading (the element draws its placeholder meanwhile).
  func image(for path: String, minPixelSize: CGFloat) -> CGImage?
}

/// Bounded, asynchronous thumbnails for the live board. Images decode off the main thread at the
/// size the current zoom needs (rounded up to a power of two), so a board of large screenshots
/// neither hitches a pan nor holds every source at full resolution. A coarser decode already in
/// memory stands in while a sharper one loads.
final class RenderImageCache: RenderImageSource, @unchecked Sendable {
  static let shared = RenderImageCache()
  /// Posted on the main queue when an image becomes drawable; `object` is the stored path.
  static let didLoad = Notification.Name("BonsaiRenderImageDidLoad")

  static let buckets: [Int] = [256, 512, 1024, 2048]
  private static let costLimit = 256 * 1_024 * 1_024

  private struct Key: Hashable {
    var path: String
    var bucket: Int
  }

  private struct Entry {
    var image: CGImage
    var cost: Int
    var lastUse: UInt64
  }

  private let lock = NSLock()
  private var entries: [Key: Entry] = [:]
  private var pending: Set<Key> = []
  private var missing: Set<String> = []
  private var totalCost = 0
  private var clock: UInt64 = 0
  private let decodeQueue = DispatchQueue(label: "dev.jow.Composer.render-image-decode",
                                          qos: .userInitiated, attributes: .concurrent)

  func image(for path: String, minPixelSize: CGFloat) -> CGImage? {
    let bucket = Self.buckets.first { CGFloat($0) >= minPixelSize } ?? Self.buckets[Self.buckets.count - 1]
    let key = Key(path: path, bucket: bucket)
    lock.lock()
    clock += 1
    if var entry = entries[key] {
      entry.lastUse = clock
      entries[key] = entry
      lock.unlock()
      return entry.image
    }
    // A sharper decode already in memory serves as-is; a coarser one stands in while this size
    // loads (buckets ascend, so the last match below is the sharpest of those).
    var coarser: CGImage?
    for candidate in Self.buckets where candidate != bucket {
      guard let entry = entries[Key(path: path, bucket: candidate)] else { continue }
      if candidate > bucket {
        lock.unlock()
        return entry.image
      }
      coarser = entry.image
    }
    let standIn = coarser.map { (image: $0, bucket: 0) }
    let shouldDecode = !missing.contains(path) && pending.insert(key).inserted
    lock.unlock()

    if shouldDecode {
      decodeQueue.async { [weak self] in
        let decoded = Self.decode(path: path, maxPixelSize: bucket)
        self?.finish(key, decoded)
      }
    }
    return standIn?.image
  }

  /// Forget a path that failed to resolve, e.g. after the file was restored.
  func retry(_ path: String) {
    lock.lock()
    missing.remove(path)
    lock.unlock()
  }

  private func finish(_ key: Key, _ image: CGImage?) {
    lock.lock()
    pending.remove(key)
    if let image {
      let cost = image.bytesPerRow * image.height
      clock += 1
      entries[key] = Entry(image: image, cost: cost, lastUse: clock)
      totalCost += cost
      if totalCost > Self.costLimit {
        for victim in entries.sorted(by: { $0.value.lastUse < $1.value.lastUse }) {
          guard totalCost > Self.costLimit * 3 / 4, victim.key != key else { continue }
          totalCost -= victim.value.cost
          entries[victim.key] = nil
        }
      }
    } else {
      missing.insert(key.path)
    }
    lock.unlock()
    guard image != nil else { return }
    DispatchQueue.main.async {
      NotificationCenter.default.post(name: Self.didLoad, object: key.path)
    }
  }

  static func decode(path: String, maxPixelSize: Int?) -> CGImage? {
    guard let url = AssetStore.resolve(path),
          let source = CGImageSourceCreateWithURL(url as CFURL, nil) else { return nil }
    guard let maxPixelSize else {
      return CGImageSourceCreateImageAtIndex(source, 0, [kCGImageSourceShouldCacheImmediately: true] as CFDictionary)
    }
    let options: [CFString: Any] = [
      kCGImageSourceCreateThumbnailFromImageAlways: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
      kCGImageSourceShouldCacheImmediately: true,
    ]
    return CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary)
  }
}

/// Fully decoded images handed over up front — the export render cannot wait on async thumbnails.
struct PreloadedImageSource: RenderImageSource {
  let images: [String: CGImage]

  init(cards: [CardState]) {
    var images: [String: CGImage] = [:]
    for card in cards where card.elementKind == .image {
      guard let path = card.imagePath, images[path] == nil else { continue }
      images[path] = RenderImageCache.decode(path: path, maxPixelSize: nil)
    }
    self.images = images
  }

  func image(for path: String, minPixelSize: CGFloat) -> CGImage? { images[path] }
}
