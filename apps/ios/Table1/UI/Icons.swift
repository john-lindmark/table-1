import SwiftUI

/// A Material icon (weight 300) from the Figma file, drawn from its SVG path in an 18 pt box. Paths use absolute
/// M / L / H / V / C / Z only, as Figma exports them.
struct T1Icon: Shape {
    let d: String

    func path(in r: CGRect) -> Path {
        let s = min(r.width, r.height) / 18
        var p = Path()
        var cur = CGPoint.zero
        func pt(_ x: CGFloat, _ y: CGFloat) -> CGPoint { CGPoint(x: r.minX + x * s, y: r.minY + y * s) }
        var tokens = Self.tokens(d)[...]
        var cmd: Character = "M"
        func num() -> CGFloat { if case .num(let n)? = tokens.popFirst() { return n }; return 0 }
        while let t = tokens.first {
            if case .cmd(let c) = t { cmd = c; tokens.removeFirst() }
            switch cmd {
            case "M": cur = CGPoint(x: num(), y: num()); p.move(to: pt(cur.x, cur.y)); cmd = "L"
            case "L": cur = CGPoint(x: num(), y: num()); p.addLine(to: pt(cur.x, cur.y))
            case "H": cur.x = num(); p.addLine(to: pt(cur.x, cur.y))
            case "V": cur.y = num(); p.addLine(to: pt(cur.x, cur.y))
            case "C":
                let c1 = CGPoint(x: num(), y: num()), c2 = CGPoint(x: num(), y: num())
                cur = CGPoint(x: num(), y: num())
                p.addCurve(to: pt(cur.x, cur.y), control1: pt(c1.x, c1.y), control2: pt(c2.x, c2.y))
            case "Z": p.closeSubpath(); if case .num? = tokens.first { tokens.removeFirst() }
            default: tokens.removeFirst()
            }
        }
        return p
    }

    private enum Token { case cmd(Character), num(CGFloat) }

    private static func tokens(_ d: String) -> [Token] {
        var out: [Token] = []
        var n = ""
        func flush() { if let v = Double(n) { out.append(.num(CGFloat(v))) }; n = "" }
        for ch in d {
            if ch.isLetter && ch != "e" { flush(); out.append(.cmd(ch)) }
            else if ch == "-" && !n.isEmpty && n.last != "e" { flush(); n.append(ch) }
            else if ch == " " || ch == "," { flush() }
            else { n.append(ch) }
        }
        flush()
        return out
    }

    static let plus = T1Icon(d: "M8.4375 9.5625H4.125V8.4375H8.4375V4.125H9.5625V8.4375H13.875V9.5625H9.5625V13.875H8.4375V9.5625Z")
    static let search = T1Icon(d: "M14.6567 15.4328L9.94613 10.722C9.57113 11.0316 9.13987 11.2739 8.65237 11.4489C8.16487 11.6239 7.66056 11.7114 7.13944 11.7114C5.85869 11.7114 4.77406 11.2673 3.88556 10.3789C2.99719 9.49038 2.553 8.40575 2.553 7.125C2.553 5.84425 2.99719 4.75963 3.88556 3.87113C4.77406 2.98275 5.85869 2.53856 7.13944 2.53856C8.42019 2.53856 9.50481 2.98275 10.3933 3.87113C11.2817 4.75963 11.7259 5.84425 11.7259 7.125C11.7259 7.66063 11.636 8.17219 11.4562 8.65969C11.2764 9.14719 11.0364 9.57119 10.7364 9.93169L15.447 14.6422L14.6567 15.4328ZM7.13944 10.5866C8.10581 10.5866 8.92431 10.2513 9.59494 9.5805C10.2657 8.90987 10.6011 8.09138 10.6011 7.125C10.6011 6.15862 10.2657 5.34012 9.59494 4.6695C8.92431 3.99875 8.10581 3.66337 7.13944 3.66337C6.17306 3.66337 5.35456 3.99875 4.68394 4.6695C4.01319 5.34012 3.67781 6.15862 3.67781 7.125C3.67781 8.09138 4.01319 8.90987 4.68394 9.5805C5.35456 10.2513 6.17306 10.5866 7.13944 10.5866Z")
    static let arrowRight = T1Icon(d: "M10.3847 13.2403L9.59419 12.4269L12.4586 9.5625H3.375V8.4375H12.4586L9.59419 5.57306L10.3847 4.75969L14.625 9L10.3847 13.2403Z")
    static let decks = T1Icon(d: "M8.22295 9.81524L1.95395 6.56561L9.82163 2.36842L16.0979 5.61824L8.22295 9.81524ZM8.22295 12.7431L2.3852 9.73005L3.56345 9.08373L8.22295 11.4624L14.4883 8.13637L15.6667 8.78268L8.22295 12.7431ZM8.22295 15.6711L2.3852 12.6579L3.56345 12.0117L8.22295 14.3902L14.4883 11.0644L15.6667 11.7105L8.22295 15.6711ZM8.22295 8.53462L13.7527 5.61824L9.82163 3.64923L4.29901 6.56561L8.22295 8.53462Z")
    static let binders = T1Icon(d: "M5.14912 16.125C4.6635 16.125 4.24644 15.962 3.89794 15.636C3.54931 15.3101 3.375 14.9068 3.375 14.4259V4.18706C3.375 3.75531 3.51469 3.37237 3.79406 3.03825C4.07331 2.70412 4.42881 2.49188 4.86056 2.4015L11.8558 0.975V12.4558L4.98037 13.8879C4.84862 13.9178 4.73562 13.982 4.64137 14.0805C4.54712 14.1791 4.5 14.2943 4.5 14.4259C4.5 14.5923 4.56469 14.7296 4.69406 14.8378C4.82331 14.9459 4.975 15 5.14912 15H13.5V3.375H14.625V16.125H5.14912ZM6.51919 12.4343L10.7308 11.5586V2.35819L6.51919 3.21919V12.4343ZM5.39419 12.6621V3.44719L5.09138 3.51056C4.92025 3.54519 4.77887 3.62381 4.66725 3.74644C4.55575 3.86906 4.5 4.01594 4.5 4.18706V12.9218C4.57688 12.8823 4.65575 12.8483 4.73662 12.8199C4.81737 12.7916 4.89863 12.7687 4.98037 12.7515L5.39419 12.6621Z")
    static let cubes = T1Icon(d: "M8.4375 14.6769V9.32306L3.75 6.60863V11.9625L8.4375 14.6769ZM9.5625 14.6769L14.25 11.9625V6.60863L9.5625 9.32306V14.6769ZM9 8.35387L13.6313 5.67694L9 3L4.36875 5.67694L9 8.35387ZM2.625 12.6274V5.37262L9 1.70775L15.375 5.37262V12.6274L9 16.2923L2.625 12.6274Z")
}

/// An icon in a 50 × 50 tap area (the Figma bar's icon buttons: 16 pt padding around 18 pt).
struct T1IconButton: View {
    let icon: T1Icon
    let label: String
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            icon.fill(T1.text, style: FillStyle(eoFill: false)).frame(width: 18, height: 18)
                .frame(width: 50, height: 50).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(label)
    }
}
