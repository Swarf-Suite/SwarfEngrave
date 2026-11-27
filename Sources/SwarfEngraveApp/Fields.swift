// Shared inspector controls: number fields that take arithmetic, dark sections with Eyebrow headings, colour helpers.

import AppKit
import SwiftUI

// MARK: Units in the environment

private struct UseInchesKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Lengths shown in inches (stored in mm either way).
    var useInches: Bool {
        get { self[UseInchesKey.self] }
        set { self[UseInchesKey.self] = newValue }
    }
}

// MARK: Arithmetic

/// A tiny parser for number fields: `+ - * /`, parentheses, unary minus and an optional trailing unit
/// (`mm`, `cm`, `in` or `"`), so `120/2-3` or `1 1/2"`-style input works without evaluating arbitrary code.
enum Arithmetic {
    enum Unit { case mm, cm, inch }

    static func evaluate(_ input: String) -> (value: Double, unit: Unit?)? {
        var s = input.lowercased().trimmingCharacters(in: .whitespaces)
            .replacingOccurrences(of: "×", with: "*").replacingOccurrences(of: "÷", with: "/")
            .replacingOccurrences(of: "−", with: "-").replacingOccurrences(of: ",", with: ".")
        var unit: Unit?
        for (suffix, u) in [("mm", Unit.mm), ("cm", .cm), ("in", .inch), ("\"", .inch)] where s.hasSuffix(suffix) {
            unit = u
            s = String(s.dropLast(suffix.count))
            break
        }
        let allowed = Set("0123456789.+-*/() ")
        guard !s.isEmpty, s.allSatisfy({ allowed.contains($0) }) else { return nil }
        var p = Parser(chars: Array(s.filter { $0 != " " }))
        guard let v = p.expr(), p.i == p.chars.count, v.isFinite else { return nil }
        return (v, unit)
    }

    private struct Parser {
        let chars: [Character]
        var i = 0
        var depth = 0

        mutating func peek() -> Character? { i < chars.count ? chars[i] : nil }

        mutating func expr() -> Double? {
            guard var v = term() else { return nil }
            while let c = peek(), c == "+" || c == "-" {
                i += 1
                guard let r = term() else { return nil }
                v = c == "+" ? v + r : v - r
            }
            return v
        }

        mutating func term() -> Double? {
            guard var v = factor() else { return nil }
            while let c = peek(), c == "*" || c == "/" {
                i += 1
                guard let r = factor() else { return nil }
                if c == "*" { v *= r } else {
                    guard r != 0 else { return nil }
                    v /= r
                }
            }
            return v
        }

        mutating func factor() -> Double? {
            guard let c = peek() else { return nil }
            if c == "-" { i += 1; return factor().map { -$0 } }
            if c == "+" { i += 1; return factor() }
            if c == "(" {
                depth += 1
                guard depth < 64 else { return nil }
                i += 1
                guard let v = expr(), peek() == ")" else { return nil }
                i += 1
                depth -= 1
                return v
            }
            var s = ""
            while let d = peek(), d.isNumber || d == "." { s.append(d); i += 1 }
            return Double(s)
        }
    }
}

// MARK: Number field

enum ValueKind {
    case length  // mm, shown in inches when the window uses them
    case angle  // degrees
    case plain  // no unit
    case count  // whole numbers
    case percent
}

/// A number field that accepts arithmetic, shows mm or inches, and commits on Return or when it loses focus.
struct NumberField: View {
    var title: String = ""
    @Binding var value: Double
    var kind: ValueKind = .length
    var range: ClosedRange<Double>? = nil
    var step: Double? = nil
    var width: CGFloat = 72
    var mixed = false

    @Environment(\.useInches) private var inches
    @State private var text = ""
    @FocusState private var focused: Bool

    private var factor: Double { kind == .length && inches ? 25.4 : 1 }
    private var unitLabel: String {
        switch kind {
        case .length: return inches ? "in" : "mm"
        case .angle: return "°"
        case .percent: return "%"
        case .plain, .count: return ""
        }
    }
    private var digits: Int { kind == .count ? 0 : kind == .length && inches ? 4 : kind == .length ? 2 : 2 }

    var body: some View {
        HStack(spacing: 4) {
            if !title.isEmpty {
                Text(title).font(.system(size: 11)).foregroundStyle(Color.steel).lineLimit(1)
            }
            TextField("", text: $text, prompt: mixed ? Text("Mixed") : nil)
                .font(.mono)
                .multilineTextAlignment(.trailing)
                .swarfField()
                .frame(width: width)
                .focused($focused)
                .onSubmit(commit)
                .help("Type a number or a sum, such as 120/2-3")
            if let step {
                Stepper("", onIncrement: { set(value + step) }, onDecrement: { set(value - step) })
                    .labelsHidden()
                    .controlSize(.small)
            }
            if !unitLabel.isEmpty {
                Text(unitLabel).font(.system(size: 10)).foregroundStyle(Color.steelDim).frame(width: 16, alignment: .leading)
            }
        }
        .onAppear(perform: refresh)
        .onChange(of: value) { _, _ in if !focused { refresh() } }
        .onChange(of: inches) { _, _ in refresh() }
        .onChange(of: mixed) { _, _ in refresh() }
        .onChange(of: focused) { _, f in if !f { commit() } }
    }

    private func refresh() {
        text = mixed ? "" : UnitFormat.trimmed(value / factor, digits: digits)
    }

    private func commit() {
        // Unchanged text: keep the exact value rather than the rounded one shown.
        if !mixed && text == UnitFormat.trimmed(value / factor, digits: digits) { return }
        guard let r = Arithmetic.evaluate(text) else {
            refresh()
            return
        }
        var v = r.value
        if kind == .length {
            switch r.unit {
            case .mm: break
            case .cm: v *= 10
            case .inch: v *= 25.4
            case nil: v *= factor
            }
        }
        set(v)
        refresh()
    }

    private func set(_ v0: Double) {
        var v = kind == .count ? v0.rounded() : v0
        if let range { v = min(max(v, range.lowerBound), range.upperBound) }
        if abs(v - value) > 1e-12 || mixed { value = v }
        if !focused { refresh() }
    }
}

// MARK: Sections and rows

/// A dark inspector section with an Eyebrow heading that folds away.
struct InspectorSection<Accessory: View, Content: View>: View {
    let title: String
    @ViewBuilder var accessory: Accessory
    @ViewBuilder var content: Content
    @AppStorage private var expanded: Bool

    init(_ title: String, @ViewBuilder accessory: () -> Accessory, @ViewBuilder content: () -> Content) {
        self.title = title
        self.accessory = accessory()
        self.content = content()
        _expanded = AppStorage(wrappedValue: true, "inspector.expanded.\(title)")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 6) {
                Button {
                    withAnimation(.easeOut(duration: 0.15)) { expanded.toggle() }
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "chevron.right")
                            .font(.system(size: 9, weight: .bold))
                            .rotationEffect(.degrees(expanded ? 90 : 0))
                            .foregroundStyle(Color.steelDim)
                        Eyebrow(title)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                Spacer()
                accessory
            }
            if expanded { content }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(alignment: .bottom) { Rectangle().fill(Color.line).frame(height: 1) }
    }
}

extension InspectorSection where Accessory == EmptyView {
    init(_ title: String, @ViewBuilder content: () -> Content) { self.init(title, accessory: { EmptyView() }, content: content) }
}

/// A labelled row: label on the left in steel, controls on the right.
struct FieldRow<Content: View>: View {
    let label: String
    @ViewBuilder var content: Content
    init(_ label: String, @ViewBuilder content: () -> Content) {
        self.label = label
        self.content = content()
    }
    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(label).font(.system(size: 12)).foregroundStyle(Color.steel).frame(width: 78, alignment: .leading)
            content
            Spacer(minLength: 0)
        }
    }
}

/// A warning line with its own symbol (never colour alone).
struct WarningRow: View {
    let text: String
    var error = false
    var body: some View {
        Label {
            Text(text).fixedSize(horizontal: false, vertical: true)
        } icon: {
            Image(systemName: error ? "xmark.octagon.fill" : "exclamationmark.triangle.fill")
        }
        .font(.system(size: 11.5))
        .foregroundStyle(error ? Color.danger : Color.warn)
    }
}

// MARK: Colours

extension Color {
    /// "#rrggbb" (or "rrggbb"); nil when it doesn't parse.
    init?(hexString: String) {
        let s = hexString.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: "#", with: "")
        guard s.count == 6, let v = UInt32(s, radix: 16) else { return nil }
        self.init(hex: v)
    }

    var hexString: String {
        let c = NSColor(self).usingColorSpace(.sRGB) ?? .gray
        func b(_ x: CGFloat) -> Int { Int((min(max(x, 0), 1) * 255).rounded()) }
        return String(format: "#%02x%02x%02x", b(c.redComponent), b(c.greenComponent), b(c.blueComponent))
    }
}
