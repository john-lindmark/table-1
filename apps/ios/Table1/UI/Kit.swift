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
    @ViewBuilder var actions: Actions
    var body: some View {
        HStack(spacing: 16) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(T1.mono(13)).lineLimit(1)
                if let subtitle { LabelText(subtitle) }
            }
            Spacer(minLength: 0)
            actions
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(T1.surface)
    }
}

extension Bar where Actions == EmptyView {
    init(title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
        self.actions = EmptyView()
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
    @ViewBuilder var trailing: Trailing
    var body: some View {
        HStack(spacing: 12) {
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
    init(title: String, detail: String? = nil) {
        self.title = title
        self.detail = detail
        self.trailing = EmptyView()
    }
}

struct Field: View {
    let label: String
    @Binding var text: String
    var number = false
    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            LabelText(label)
            TextField("", text: $text)
                .font(T1.mono(15)).tint(T1.accent)
                .keyboardType(number ? .numberPad : .default)
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
