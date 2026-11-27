// Installed fonts for the text inspector: families, faces and variable-font axes, from Core Text (system fonts,
// fonts installed in Font Book and activated fonts). Cached; call `reload()` after fonts change.

import CoreText
import Foundation

public struct FontFace: Hashable, Sendable, Identifiable {
    public var postScriptName: String
    public var styleName: String
    public var displayName: String
    public var id: String { postScriptName }
    public init(postScriptName: String, styleName: String, displayName: String) {
        self.postScriptName = postScriptName
        self.styleName = styleName
        self.displayName = displayName
    }
}

public struct FontAxis: Hashable, Sendable, Identifiable {
    /// Four-character tag, e.g. "wght" (the key for `TextSpec.variations`).
    public var tag: String
    public var name: String
    public var min: Double
    public var max: Double
    public var `default`: Double
    public var id: String { tag }
    public init(tag: String, name: String, min: Double, max: Double, default d: Double) {
        self.tag = tag
        self.name = name
        self.min = min
        self.max = max
        self.default = d
    }
}

public enum FontCatalog {
    /// Every font family name available, sorted (hidden system families excluded).
    public static func families() -> [String] {
        FontCatalogStore.shared.families {
            let names = (CTFontManagerCopyAvailableFontFamilyNames() as? [String]) ?? []
            return Array(Set(names.filter { !$0.hasPrefix(".") && !$0.isEmpty }))
                .sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        }
    }

    /// The faces of a family, lightest upright first.
    public static func faces(family: String) -> [FontFace] {
        FontCatalogStore.shared.faces(family) {
            let desc = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: family] as CFDictionary)
            let mandatory: Set<String> = [kCTFontFamilyNameAttribute as String]
            guard let matches = CTFontDescriptorCreateMatchingFontDescriptors(desc, mandatory as CFSet) as? [CTFontDescriptor] else { return [] }
            var seen = Set<String>()
            var rows: [(FontFace, Double, Double)] = []
            for d in matches {
                guard let ps = CTFontDescriptorCopyAttribute(d, kCTFontNameAttribute) as? String, seen.insert(ps).inserted else { continue }
                let style = CTFontDescriptorCopyAttribute(d, kCTFontStyleNameAttribute) as? String ?? ""
                let display = CTFontDescriptorCopyAttribute(d, kCTFontDisplayNameAttribute) as? String ?? "\(family) \(style)"
                let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [String: Any] ?? [:]
                let weight = (traits[kCTFontWeightTrait as String] as? NSNumber)?.doubleValue ?? 0
                let slant = (traits[kCTFontSlantTrait as String] as? NSNumber)?.doubleValue ?? 0
                rows.append((FontFace(postScriptName: ps, styleName: style, displayName: display), weight, abs(slant)))
            }
            return rows.sorted { a, b in
                if a.1 != b.1 { return a.1 < b.1 }
                if a.2 != b.2 { return a.2 < b.2 }
                return a.0.styleName < b.0.styleName
            }.map(\.0)
        }
    }

    /// Variation axes of a variable font; empty for static fonts.
    public static func axes(postScriptName: String) -> [FontAxis] {
        FontCatalogStore.shared.axes(postScriptName) {
            let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
            guard let raw = CTFontCopyVariationAxes(font) as? [[String: Any]] else { return [] }
            return raw.compactMap { a in
                guard let id = (a[kCTFontVariationAxisIdentifierKey as String] as? NSNumber)?.uint32Value,
                      let lo = (a[kCTFontVariationAxisMinimumValueKey as String] as? NSNumber)?.doubleValue,
                      let hi = (a[kCTFontVariationAxisMaximumValueKey as String] as? NSNumber)?.doubleValue,
                      let def = (a[kCTFontVariationAxisDefaultValueKey as String] as? NSNumber)?.doubleValue
                else { return nil }
                if let hidden = a[kCTFontVariationAxisHiddenKey as String] as? NSNumber, hidden.boolValue { return nil }
                let tag = TextOutliner.tagString(id)
                let name = a[kCTFontVariationAxisNameKey as String] as? String ?? tag
                return FontAxis(tag: tag, name: name, min: lo, max: hi, default: def)
            }
        }
    }

    /// The family a PostScript name belongs to, when it's installed.
    public static func family(of postScriptName: String) -> String? {
        guard TextOutliner.isInstalled(postScriptName) else { return nil }
        let font = CTFontCreateWithName(postScriptName as CFString, 12, nil)
        return CTFontCopyFamilyName(font) as String
    }

    public static func isInstalled(_ postScriptName: String) -> Bool { TextOutliner.isInstalled(postScriptName) }

    /// Drops every cached font lookup (call when fonts are installed or removed).
    public static func reload() {
        FontCatalogStore.shared.reset()
        TextCache.shared.reset()
    }
}

final class FontCatalogStore: @unchecked Sendable {
    static let shared = FontCatalogStore()
    private let lock = NSLock()
    private var familyList: [String]?
    private var faceMap: [String: [FontFace]] = [:]
    private var axisMap: [String: [FontAxis]] = [:]

    private func cached<T>(_ get: () -> T?, _ set: (T) -> Void, _ make: () -> T) -> T {
        lock.lock()
        if let v = get() { lock.unlock(); return v }
        lock.unlock()
        let v = make()
        lock.lock()
        set(v)
        lock.unlock()
        return v
    }

    func families(_ make: () -> [String]) -> [String] { cached({ familyList }, { familyList = $0 }, make) }
    func faces(_ f: String, _ make: () -> [FontFace]) -> [FontFace] { cached({ faceMap[f] }, { faceMap[f] = $0 }, make) }
    func axes(_ n: String, _ make: () -> [FontAxis]) -> [FontAxis] { cached({ axisMap[n] }, { axisMap[n] = $0 }, make) }

    func reset() {
        lock.lock()
        familyList = nil
        faceMap = [:]
        axisMap = [:]
        lock.unlock()
    }
}
