import AppKit
import CoreText

/// Everything the element renderer needs from the theme and typography settings, resolved once on
/// the main thread into immutable Core Graphics values. Drawing then touches no AppKit state, so
/// tiles can be rasterized on any thread.
///
/// Colors mirror `Theme.Palette` token for token — the renderer never invents a color.
final class RenderStyle: @unchecked Sendable {
  let isDark: Bool
  let body: CGColor
  let placeholder: CGColor
  let menuDesc: CGColor
  let accent: CGColor
  let markerDim: CGColor
  let elementStroke: CGColor
  /// Nil on light themes, where shapes are outline-only.
  let elementFill: CGColor?
  /// Nil on light themes — ink on paper casts no shadow.
  let elementShadow: CGColor?
  let labelChipFill: CGColor
  let panelHairline: CGColor
  let separator: CGColor
  let chromeText: CGColor
  let chromeDivider: CGColor
  let raisedTint: CGColor
  let codeChip: CGColor
  let stickyBase: CGColor
  let canvas: CGColor
  let tints: [CGColor]
  /// The user's body point size (Settings ▸ Appearance ▸ Text size).
  let bodyFontSize: CGFloat
  /// Changes whenever anything above would resolve differently — cached layouts key off it.
  let signature: String

  private let fontLock = NSLock()
  private var fonts: [FontKey: CTFont] = [:]

  private struct FontKey: Hashable {
    var size: CGFloat
    var weight: CGFloat
    var italic: Bool
    var monospaced: Bool
    var system: Bool
  }

  @MainActor
  init(flavor: ThemeFlavor = Theme.flavor,
       appearance: NSAppearance? = ComposerPreferences.effectiveTheme.nsAppearance) {
    let appearance = appearance ?? NSApp?.effectiveAppearance ?? NSAppearance.currentDrawing()
    var resolved: [CGColor] = []
    func cg(_ color: NSColor, _ alpha: CGFloat = 1) -> CGColor {
      var out = CGColor(gray: 0, alpha: 1)
      appearance.performAsCurrentDrawingAppearance {
        let srgb = color.usingColorSpace(.sRGB) ?? color
        out = (alpha == 1 ? srgb : srgb.withAlphaComponent(srgb.alphaComponent * alpha)).cgColor
      }
      resolved.append(out)
      return out
    }
    isDark = flavor.isDark
    body = cg(flavor.text)
    placeholder = cg(flavor.overlay1)
    menuDesc = cg(flavor.subtext0)
    accent = cg(flavor.accent)
    markerDim = cg(flavor.overlay0)
    elementStroke = cg(flavor.text, 0.85)
    elementFill = flavor.isDark ? cg(flavor.surface0, 0.55) : nil
    elementShadow = flavor.isDark ? cg(flavor.crust, 0.55) : nil
    labelChipFill = cg(flavor.isDark ? flavor.surface0 : flavor.mantle)
    panelHairline = cg(flavor.overlay0, 0.35)
    separator = cg(flavor.surface2, 0.60)
    chromeText = cg(flavor.subtext1)
    chromeDivider = cg(flavor.surface2, 0.80)
    raisedTint = cg(flavor.base, 0.45)
    codeChip = cg(flavor.surface0, 0.55)
    stickyBase = cg(NSColor.systemYellow)
    canvas = cg(flavor.base)
    tints = flavor.tints.map { cg($0) }
    bodyFontSize = ComposerPreferences.editorFontSize
    let colors = resolved.map { ($0.components ?? []).map { String(format: "%.3f", $0) }.joined(separator: ",") }
    signature = "\(ComposerPreferences.appFontFamily.rawValue)|\(bodyFontSize)|" + colors.joined(separator: ";")
  }

  func tint(_ slot: Int?) -> CGColor? {
    guard let slot, tints.indices.contains(slot) else { return nil }
    return tints[slot]
  }

  /// The app's body family at `size` (the Core Text twin of `ComposerPreferences.appFont`).
  func font(_ size: CGFloat, weight: NSFont.Weight = .regular, italic: Bool = false) -> CTFont {
    cached(FontKey(size: size, weight: weight.rawValue, italic: italic, monospaced: false, system: false)) {
      let base = ComposerPreferences.appFont(ofSize: size, weight: weight) as CTFont
      guard italic else { return base }
      return CTFontCreateCopyWithSymbolicTraits(base, size, nil, .traitItalic, .traitItalic)
        ?? CTFontCreateCopyWithAttributes(base, size, [CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)], nil)
    }
  }

  /// San Francisco regardless of the selected family — graph furniture and glyph-adjacent labels.
  func systemFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> CTFont {
    cached(FontKey(size: size, weight: weight.rawValue, italic: false, monospaced: false, system: true)) {
      NSFont.systemFont(ofSize: size, weight: weight) as CTFont
    }
  }

  func monospacedFont(_ size: CGFloat, weight: NSFont.Weight = .regular) -> CTFont {
    cached(FontKey(size: size, weight: weight.rawValue, italic: false, monospaced: true, system: true)) {
      NSFont.monospacedSystemFont(ofSize: size, weight: weight) as CTFont
    }
  }

  private func cached(_ key: FontKey, _ make: () -> CTFont) -> CTFont {
    fontLock.lock()
    defer { fontLock.unlock() }
    if let font = fonts[key] { return font }
    let font = make()
    fonts[key] = font
    return font
  }
}

extension CGColor {
  func alpha(_ multiplier: CGFloat) -> CGColor {
    copy(alpha: alpha * multiplier) ?? self
  }
}
