import SwiftUI

/// Table 1 design language: hard rectangles, 1px hairlines, monospace, one teal accent
/// that only ever means "this is the result".
enum T1 {
    static let bg = Color(red: 0x17 / 255, green: 0x17 / 255, blue: 0x25 / 255)
    static let surface = Color(red: 0x28 / 255, green: 0x28 / 255, blue: 0x39 / 255)
    static let surfaceHover = Color(red: 0x33 / 255, green: 0x33 / 255, blue: 0x4A / 255)
    static let text = Color.white
    static let muted = Color(red: 0xC4 / 255, green: 0xC4 / 255, blue: 0xCA / 255)
    static let disabled = Color(red: 0x54 / 255, green: 0x54 / 255, blue: 0x61 / 255)
    static let ink = bg
    static let accent = Color(red: 0, green: 1, blue: 0xD9 / 255)
    static let danger = Color(red: 1, green: 0.42, blue: 0.42)
    static let warning = Color(red: 0xFB / 255, green: 0xBF / 255, blue: 0x24 / 255)
    /// Library Error (pink): the tracker's round clock in overtime and a lost total.
    static let error = Color(red: 0xF2 / 255, green: 0xA3 / 255, blue: 0xE5 / 255)

    static func mono(_ size: CGFloat, _ weight: Font.Weight = .regular) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

/// Full-bleed stack; blocks separated by 1px of background (the hairline grid).
struct T1Screen<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        VStack(spacing: 1) { content }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            .background(T1.bg.ignoresSafeArea())
            .foregroundStyle(T1.text)
            .toolbar(.hidden, for: .navigationBar)
    }
}

struct LabelText: View {
    let text: String
    var color: Color = T1.muted
    init(_ text: String, color: Color = T1.muted) { self.text = text; self.color = color }
    var body: some View {
        Text(text.uppercased()).font(T1.mono(11)).tracking(1.5).foregroundStyle(color).lineLimit(1)
    }
}

struct Bar<Actions: View>: View {
    let title: String
    var subtitle: String?
    /// Shown as the left arrow (Figma Bar, node 95:11022) on screens pushed above a tab's root.
    var back: (() -> Void)?
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 16) {
            if let back { BackArrowButton(action: back) }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T1.mono(13)).lineLimit(1)
                if let subtitle { LabelText(subtitle) }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.leading, back == nil ? 16 : 0).padding(.trailing, 16).padding(.vertical, 12)
        .background(T1.surface)
    }
}

extension Bar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil, back: (() -> Void)? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.back = back
        self.actions = EmptyView()
    }
}

/// Material "arrow_left_alt" (weight 300) from the Figma Bar, drawn in an 18 pt box.
struct BackArrow: Shape {
    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var p = Path()
        p.move(to: pt(7.464, 13.2403)); p.addLine(to: pt(3.2235, 9)); p.addLine(to: pt(7.464, 4.75969))
        p.addLine(to: pt(8.25431, 5.57306)); p.addLine(to: pt(5.38987, 8.4375)); p.addLine(to: pt(14.7765, 8.4375))
        p.addLine(to: pt(14.7765, 9.5625)); p.addLine(to: pt(5.38987, 9.5625)); p.addLine(to: pt(8.25431, 12.4269))
        p.closeSubpath()
        return p
    }
}

/// The arrow in a 50 × 50 tap area; the arrow sits 16 pt from the screen edge, like the Figma bar.
struct BackArrowButton: View {
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            BackArrow().fill(T1.text).frame(width: 18, height: 18)
                .frame(width: 50, height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, -12).padding(.trailing, -16)
        .accessibilityLabel("Back")
    }
}

struct BarButton: View {
    let text: String
    let action: () -> Void
    init(_ text: String, action: @escaping () -> Void) { self.text = text; self.action = action }
    var body: some View { Button(action: action) { LabelText(text, color: T1.text) }.buttonStyle(.plain) }
}

/// The one giant full-width action bar.
struct BigAction: View {
    let text: String
    var enabled = true
    var busy = false
    var accent = false
    let action: () -> Void
    var body: some View {
        let on = enabled && !busy
        Button(action: action) {
            Text((busy ? "Working…" : text).uppercased())
                .font(T1.mono(16, .bold)).tracking(5)
                .foregroundStyle(T1.ink)
                .frame(maxWidth: .infinity).padding(.vertical, 26)
                .background(on ? (accent ? T1.accent : T1.text) : T1.disabled)
        }
        .buttonStyle(.plain)
        .disabled(!on)
        .sensoryFeedback(.impact, trigger: busy)
    }
}

struct Ghost: View {
    let text: String
    var accent = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            LabelText(text, color: accent ? T1.ink : T1.text)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(accent ? T1.accent : T1.surface)
        }
        .buttonStyle(.plain)
    }
}

struct Notice: View {
    let text: String
    var error = false
    init(_ text: String, error: Bool = false) { self.text = text; self.error = error }
    var body: some View {
        Text(text).font(T1.mono(12)).lineSpacing(4)
            .foregroundStyle(error ? T1.danger : T1.muted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 12)
            .background(error ? T1.danger.opacity(0.15) : T1.surface)
    }
}

struct Section1: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        LabelText(text).frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 16).padding(.vertical, 8).background(T1.surface)
    }
}

struct ListRow<Trailing: View>: View {
    let title: String
    var detail: String?
    /// A player's tile left of the name.
    var avatar: AvatarView?
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
            if let avatar { avatar }
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T1.mono(14)).lineLimit(1)
                if let detail { LabelText(detail) }
            }
            Spacer(minLength: 0)
            trailing
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(T1.surface)
        .contentShape(Rectangle())
    }
}

extension ListRow where Trailing == EmptyView {
    init(title: String, detail: String? = nil, avatar: AvatarView? = nil) {
        self.title = title
        self.detail = detail
        self.avatar = avatar
        self.trailing = EmptyView()
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var number = false
    /// Links: URL keyboard, no capitals, no autocorrect.
    var url = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            TextField("", text: $text)
                .font(T1.mono(15)).tint(T1.accent)
                .keyboardType(number ? .numberPad : url ? .URL : .default)
                .textInputAutocapitalization(url ? .never : .sentences)
                .autocorrectionDisabled(url)
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(T1.surface)
    }
}

/// Scrollable column that keeps the 1px hairline grid.
struct HairlineList<Content: View>: View {
    @ViewBuilder let content: Content
    var body: some View {
        ScrollView { LazyVStack(spacing: 1) { content } }
            .frame(maxHeight: .infinity)
    }
}

/// The Table 1 mark: eleven tiles on a 6 × 3 grid, scaled from the library's "Table 1 Logo" vector
/// (393 × 192.69). Fill it and give it the width; the height follows the aspect ratio.
struct T1Logo: Shape {
    static let aspect: CGFloat = 393 / 192.69
    /// (column, row) of each tile.
    private static let tiles: [(Int, Int)] = [
        (0, 0), (1, 0), (2, 0), (3, 0), (4, 0),
        (1, 1), (4, 1),
        (1, 2), (3, 2), (4, 2), (5, 2),
    ]

    func path(in rect: CGRect) -> Path {
        let sx = rect.width / 393, sy = rect.height / 192.69
        var p = Path()
        for (c, r) in Self.tiles {
            p.addRect(CGRect(x: rect.minX + CGFloat(c) * 65.8036 * sx, y: rect.minY + CGFloat(r) * 64.8302 * sy,
                             width: 63.982 * sx, height: 63.0294 * sy))
        }
        return p
    }
}

/// Counts down to a fixed end time (or shows a paused clock). Every phone shows the same number
/// because the end time comes from the server.
struct Countdown: View {
    let end: Date?
    var paused: Int?
    var size: CGFloat = 56

    var body: some View {
        if let end {
            TimelineView(.periodic(from: .now, by: 1)) { context in
                let left = max(0, Int(end.timeIntervalSince(context.date)))
                Text(left == 0 ? "TIME" : Self.mmss(left))
                    .font(T1.mono(size)).tracking(size / 14)
                    .foregroundStyle(left == 0 ? T1.danger : T1.text)
                    .monospacedDigit()
            }
        } else if let paused {
            Text(Self.mmss(paused)).font(T1.mono(size)).tracking(size / 14).foregroundStyle(T1.muted)
        }
    }

    static func mmss(_ s: Int) -> String { String(format: "%02d:%02d", s / 60, s % 60) }
}

/// Small stacked label + value, used in hero cards.
struct Stat: View {
    let label: String
    let value: String
    var accent = false
    var alignment: HorizontalAlignment = .leading
    var body: some View {
        VStack(alignment: alignment, spacing: 2) {
            LabelText(label)
            Text(value).font(T1.mono(17)).lineLimit(1).foregroundStyle(accent ? T1.accent : T1.text)
        }
        .frame(maxWidth: .infinity, alignment: alignment == .leading ? .leading : .trailing)
    }
}

// MARK: controls (no system chrome: everything below is drawn in the T1 language)

/// Equal-width options in a hairline row; the selected one is solid text color with ink text.
struct T1Segmented<Value: Hashable>: View {
    let options: [(value: Value, label: String)]
    @Binding var selection: Value

    var body: some View {
        HStack(spacing: 1) {
            ForEach(options.indices, id: \.self) { i in
                let option = options[i]
                let on = option.value == selection
                Button { selection = option.value } label: {
                    LabelText(option.label, color: on ? T1.ink : T1.text)
                        .frame(maxWidth: .infinity).padding(.vertical, 14)
                        .background(on ? T1.text : T1.surface)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .sensoryFeedback(.selection, trigger: selection)
    }
}

/// Label, then − value + on one row.
struct T1Stepper: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    var step = 1
    var unit = ""

    var body: some View {
        HStack(spacing: 1) {
            Text(label).font(T1.mono(13)).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.leading, 16)
            stepButton("−", enabled: value > range.lowerBound) { value = max(range.lowerBound, value - step) }
            Text("\(value)\(unit)").font(T1.mono(20)).monospacedDigit().foregroundStyle(T1.accent)
                .lineLimit(1).minimumScaleFactor(0.6)
                .frame(minWidth: 72).padding(.horizontal, 4)
            stepButton("+", enabled: value < range.upperBound) { value = min(range.upperBound, value + step) }
        }
        .frame(minHeight: 52)
        .background(T1.surface)
        .sensoryFeedback(.selection, trigger: value)
    }

    private func stepButton(_ glyph: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(glyph).font(T1.mono(22))
                .foregroundStyle(enabled ? T1.text : T1.disabled)
                .frame(width: 52, height: 52)
                .background(T1.surfaceHover)
        }
        .buttonStyle(.plain)
        .disabled(!enabled)
    }
}

/// A settings row whose value reads On / Off; tapping flips it.
struct T1Switch: View {
    let title: String
    var detail: String?
    @Binding var isOn: Bool

    var body: some View {
        Button { isOn.toggle() } label: {
            ListRow(title: title, detail: detail) {
                LabelText(isOn ? "On" : "Off", color: isOn ? T1.accent : T1.muted)
            }
        }
        .buttonStyle(.plain)
        .sensoryFeedback(.selection, trigger: isOn)
    }
}

/// Search box in the field style: glyph, plain text field, clear.
struct T1SearchField: View {
    @Binding var text: String
    let prompt: String

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass").foregroundStyle(T1.muted)
            TextField("", text: $text, prompt: Text(prompt).foregroundStyle(T1.muted))
                .font(T1.mono(15)).tint(T1.accent)
                .autocorrectionDisabled()
            if !text.isEmpty { BarButton("Clear") { text = "" } }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .background(T1.surface)
    }
}

// MARK: tab bar

/// Tiles on a 3 × 2 grid, the logo's construction at glyph size.
struct T1TileGlyph: Shape {
    let tiles: [(Int, Int)]

    func path(in rect: CGRect) -> Path {
        let gap: CGFloat = 2
        let w = (rect.width - gap * 2) / 3, h = (rect.height - gap) / 2
        var p = Path()
        for (c, r) in tiles {
            p.addRect(CGRect(x: rect.minX + CGFloat(c) * (w + gap), y: rect.minY + CGFloat(r) * (h + gap), width: w, height: h))
        }
        return p
    }

    static let events: [(Int, Int)] = [(0, 0), (1, 0), (2, 0), (0, 1), (1, 1), (2, 1)]
    static let collection: [(Int, Int)] = [(0, 0), (2, 0), (0, 1), (1, 1), (2, 1)]
    static let account: [(Int, Int)] = [(1, 0), (0, 1), (1, 1), (2, 1)]
}

struct T1TabItem<ID: Hashable>: Identifiable {
    let id: ID
    let label: String
    let tiles: [(Int, Int)]
    var enabled = true
    /// Small note next to the label ("Soon").
    var note: String?
}

/// The app's bottom bar: tile glyph + label. Selected = text color with an accent glyph; others muted;
/// disabled items grey. Taps on a disabled item still reach `onSelect` (to explain why).
struct T1TabBar<ID: Hashable>: View {
    let items: [T1TabItem<ID>]
    let selection: ID
    let onSelect: (ID) -> Void

    var body: some View {
        HStack(spacing: 1) {
            ForEach(items) { item in
                let on = item.id == selection && item.enabled
                Button { onSelect(item.id) } label: {
                    VStack(spacing: 6) {
                        T1TileGlyph(tiles: item.tiles)
                            .fill(on ? T1.accent : item.enabled ? T1.muted : T1.disabled)
                            .frame(width: 24, height: 15)
                        HStack(spacing: 4) {
                            LabelText(item.label, color: on ? T1.text : item.enabled ? T1.muted : T1.disabled)
                            if let note = item.note {
                                Text(note.uppercased()).font(T1.mono(8)).tracking(1).foregroundStyle(T1.disabled).lineLimit(1)
                            }
                        }
                    }
                    .frame(maxWidth: .infinity).padding(.top, 10).padding(.bottom, 8)
                    .background(T1.surface)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityAddTraits(on ? .isSelected : [])
            }
        }
        .padding(.top, 1)
        .background(T1.bg)
        .background(T1.surface.ignoresSafeArea(edges: .bottom))
        .sensoryFeedback(.selection, trigger: selection)
    }
}

// MARK: overlays (menus and panels drawn by the app, above everything, under native alerts)

struct T1MenuItem: Identifiable {
    let id = UUID()
    let title: String
    var detail: String?
    var destructive = false
    var checked = false
    var enabled = true
    let action: () -> Void
}

struct T1MenuSpec: Identifiable {
    let id = UUID()
    let title: String?
    let message: String?
    let items: [T1MenuItem]
}

struct T1PanelSpec: Identifiable {
    let id = UUID()
    /// Full screen, or a panel rising from the bottom over a dimmed scrim.
    let full: Bool
    let content: AnyView
}

/// The one place menus and panels are shown, so they cover the tab bar and the life tracker too.
/// `T1OverlayHost` draws them at the root.
@MainActor
@Observable
final class T1Overlays {
    static let shared = T1Overlays()
    var menu: T1MenuSpec?
    var panels: [T1PanelSpec] = []

    func showMenu(_ title: String? = nil, message: String? = nil, _ items: [T1MenuItem]) {
        menu = T1MenuSpec(title: title, message: message, items: items)
    }

    func present<V: View>(full: Bool = false, @ViewBuilder _ content: () -> V) {
        panels.append(T1PanelSpec(full: full, content: AnyView(content())))
    }

    func dismissPanel() {
        if !panels.isEmpty { panels.removeLast() }
    }

    func dismissAll() {
        menu = nil
        panels = []
    }
}

struct T1OverlayHost: View {
    var body: some View {
        let overlays = T1Overlays.shared
        ZStack {
            ForEach(overlays.panels) { panel in
                if panel.full {
                    panel.content
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(T1.bg.ignoresSafeArea())
                        .transition(.move(edge: .bottom))
                } else {
                    ZStack(alignment: .bottom) {
                        T1Scrim { overlays.dismissPanel() }
                        panel.content
                            .frame(maxWidth: .infinity)
                            .padding(.top, 1)
                            .background(T1.bg.ignoresSafeArea(edges: .bottom))
                            .transition(.move(edge: .bottom))
                    }
                }
            }
            if let menu = overlays.menu {
                ZStack(alignment: .bottom) {
                    T1Scrim { overlays.menu = nil }
                    T1MenuPanel(spec: menu) { overlays.menu = nil }
                        .transition(.move(edge: .bottom))
                }
            }
        }
        .foregroundStyle(T1.text)
        .animation(.snappy(duration: 0.22), value: overlays.panels.map(\.id))
        .animation(.snappy(duration: 0.18), value: overlays.menu?.id)
    }
}

/// Dimmed backdrop; tapping it closes what's on top.
struct T1Scrim: View {
    let onTap: () -> Void
    var body: some View {
        Color.black.opacity(0.6).ignoresSafeArea()
            .contentShape(Rectangle())
            .onTapGesture(perform: onTap)
            .transition(.opacity)
    }
}

/// A column of hairline rows with a Cancel row; the item's action runs after the menu closes.
struct T1MenuPanel: View {
    let spec: T1MenuSpec
    let close: () -> Void

    var body: some View {
        VStack(spacing: 1) {
            if spec.title != nil || spec.message != nil {
                VStack(alignment: .leading, spacing: 4) {
                    if let title = spec.title { LabelText(title) }
                    if let message = spec.message {
                        Text(message).font(T1.mono(12)).foregroundStyle(T1.muted).fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 16).padding(.vertical, 12)
                .background(T1.surface)
            }
            VStack(spacing: 1) {
                ForEach(spec.items) { item in
                    Button {
                        close()
                        item.action()
                    } label: {
                        HStack(spacing: 12) {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.title).font(T1.mono(15)).lineLimit(1)
                                    .foregroundStyle(!item.enabled ? T1.disabled : item.destructive ? T1.danger : T1.text)
                                if let detail = item.detail { LabelText(detail) }
                            }
                            Spacer(minLength: 0)
                            if item.checked { LabelText("Selected", color: T1.accent) }
                        }
                        .padding(.horizontal, 16).padding(.vertical, 16)
                        .frame(maxWidth: .infinity)
                        .background(T1.surface)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .disabled(!item.enabled)
                }
            }
            Button(action: close) {
                LabelText("Cancel", color: T1.text)
                    .frame(maxWidth: .infinity).padding(.vertical, 18)
                    .background(T1.surfaceHover)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .padding(.top, 1)
        .background(T1.bg.ignoresSafeArea(edges: .bottom))
    }
}
