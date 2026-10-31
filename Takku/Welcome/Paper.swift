import AppKit
import CoreText
import SwiftUI

/// The look of takku.app in the welcome window: a sheet of squared paper with a red margin, ink and
/// coloured pencil, Kalam for what is handwritten and Literata for the text. In dark mode, a
/// blueprint. Every line is drawn a little crooked, the same way at every frame (`seed`).
enum Paper {
    static let desk = dynamic(light: 0xE3E6DF, dark: 0x16325C)
    static let sheet = dynamic(light: 0xF1F3EE, dark: 0x1D3F73)
    /// A loose sheet on the paper: a Transcript, a note, a window.
    static let card = dynamic(light: 0xFAFBF8, dark: 0x234A85)
    static let grid = dynamic(light: 0x4060B0, dark: 0xBED7FF, lightAlpha: 0.16, darkAlpha: 0.13)
    static let ink = dynamic(light: 0x1C2230, dark: 0xEEF3FF)
    static let text = dynamic(light: 0x272B33, dark: 0xDBE5FA)
    static let red = dynamic(light: 0xC23B2E, dark: 0xFF9A8C)
    static let green = dynamic(light: 0x2F9A52, dark: 0x8FDCB0)
    static let pencil = dynamic(light: 0x3F58AE, dark: 0xA9C2FF)
    static let blue = dynamic(light: 0x2F62C8, dark: 0x9DBCFF)
    static let yellow = dynamic(light: 0xEFB43C, dark: 0xFFD27A)
    static let highlight = dynamic(light: 0xFFD632, dark: 0xFFD632, lightAlpha: 0.55, darkAlpha: 0.3)
    static let graphite = dynamic(light: 0x5B5E66, dark: 0xC9D6F2)

    private static func dynamic(light: Int, dark: Int, lightAlpha: CGFloat = 1, darkAlpha: CGFloat = 1) -> Color {
        func color(_ hex: Int, _ alpha: CGFloat) -> NSColor {
            NSColor(
                srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha
            )
        }
        return Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? color(dark, darkAlpha) : color(light, lightAlpha)
        })
    }

    /// Kalam, the handwriting of takku.app.
    static func hand(_ size: CGFloat, bold: Bool = false) -> Font {
        registerFonts
        return .custom(bold ? "Kalam-Bold" : "Kalam-Regular", size: size)
    }

    /// Literata, the text of takku.app.
    static func serif(_ size: CGFloat, italic: Bool = false) -> Font {
        registerFonts
        return .custom(italic ? "Literata-Italic" : "Literata-Regular", size: size)
    }

    /// The fonts travel inside Takku, the same files as the site (Fonts/, SIL Open Font License).
    private static let registerFonts: Void = {
        for url in Bundle.main.urls(forResourcesWithExtension: "woff2", subdirectory: nil) ?? [] {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }()

    static let stroke = StrokeStyle(lineWidth: 1.7, lineCap: .round, lineJoin: .round)
}

// MARK: - Drawn by hand

/// A small random generator that gives the same numbers for the same seed, so a drawing does not
/// change from one frame to the next.
struct SeededRandom: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) { state = seed &+ 0x9E37_79B9_7F4A_7C15 }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE5_E9B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

extension Path {
    /// The same path, drawn by hand: each line wavers a little around where it should be.
    func sketched(seed: UInt64, wobble: CGFloat = 1.1) -> Path {
        var lines: [[CGPoint]] = []
        var current: [CGPoint] = []
        cgPath.flattened(threshold: 0.4).applyWithBlock { element in
            let e = element.pointee
            switch e.type {
            case .moveToPoint:
                if current.count > 1 { lines.append(current) }
                current = [e.points[0]]
            case .closeSubpath:
                if let first = current.first { current.append(first) }
            default:
                current.append(e.points[0])
            }
        }
        if current.count > 1 { lines.append(current) }

        var random = SeededRandom(seed: seed)
        var path = Path()
        for line in lines {
            let phase1 = Double.random(in: 0 ... 6.28, using: &random)
            let phase2 = Double.random(in: 0 ... 6.28, using: &random)
            var distance: CGFloat = 0
            for (index, point) in line.resampled(every: 4).enumerated() {
                let shift = wobble * CGFloat(0.65 * sin(Double(distance) * 0.035 + phase1) + 0.35 * sin(Double(distance) * 0.12 + phase2))
                let shifted = CGPoint(x: point.p.x + point.normal.dx * shift, y: point.p.y + point.normal.dy * shift)
                if index == 0 { path.move(to: shifted) } else { path.addLine(to: shifted) }
                distance = point.distance
            }
        }
        return path
    }
}

private extension [CGPoint] {
    /// Points every `step` along the polyline, with the normal and the distance from the start.
    func resampled(every step: CGFloat) -> [(p: CGPoint, normal: CGVector, distance: CGFloat)] {
        var out: [(CGPoint, CGVector, CGFloat)] = []
        var walked: CGFloat = 0
        for (a, b) in zip(self, dropFirst()) {
            let length = hypot(b.x - a.x, b.y - a.y)
            guard length > 0 else { continue }
            let normal = CGVector(dx: -(b.y - a.y) / length, dy: (b.x - a.x) / length)
            var along: CGFloat = 0
            while along < length {
                let f = along / length
                out.append((CGPoint(x: a.x + (b.x - a.x) * f, y: a.y + (b.y - a.y) * f), normal, walked + along))
                along += step
            }
            walked += length
        }
        if let last, let normal = out.last?.1 { out.append((last, normal, walked)) }
        return out
    }
}

/// Any shape, drawn by hand.
struct Sketch<S: Shape>: Shape {
    let shape: S
    var seed: UInt64 = 1
    var wobble: CGFloat = 1.1

    init(_ shape: S, seed: UInt64 = 1, wobble: CGFloat = 1.1) {
        self.shape = shape
        self.seed = seed
        self.wobble = wobble
    }

    func path(in rect: CGRect) -> Path { shape.path(in: rect).sketched(seed: seed, wobble: wobble) }
}

/// A rounded rectangle drawn by hand, the outline of most things on the paper.
func box(_ seed: UInt64, radius: CGFloat = 6) -> Sketch<RoundedRectangle> {
    Sketch(RoundedRectangle(cornerRadius: radius), seed: seed)
}

/// Coloured pencil: close diagonal strokes, the way a shape is filled in with a pencil.
struct Hatch: Shape {
    var seed: UInt64 = 3
    var spacing: CGFloat = 3

    func path(in rect: CGRect) -> Path {
        var path = Path()
        var x = rect.minX - rect.height
        while x < rect.maxX {
            path.move(to: CGPoint(x: x, y: rect.maxY))
            path.addLine(to: CGPoint(x: x + rect.height * 0.8, y: rect.minY))
            x += spacing
        }
        return path.sketched(seed: seed, wobble: 0.6)
    }
}

extension Shape {
    /// Filled with coloured pencil, then outlined in ink.
    func pencil(_ color: Color, outline: Color? = Paper.ink, seed: UInt64 = 3) -> some View {
        ZStack {
            self.fill(color.opacity(0.22))
            Hatch(seed: seed).stroke(color.opacity(0.9), lineWidth: 1.6).clipShape(self)
            if let outline { self.stroke(outline, style: Paper.stroke) }
        }
    }
}

/// A line of fake handwriting, as on takku.app: words of small humps, with an ascender now and
/// then. Trim it to write it.
struct Scribble: Shape {
    var seed: UInt64

    func path(in rect: CGRect) -> Path {
        var random = SeededRandom(seed: seed)
        var path = Path()
        let y = rect.midY + 2.5
        var x = rect.minX
        while x < rect.maxX - 10 {
            let end = min(x + .random(in: 12 ... 34, using: &random), rect.maxX)
            path.move(to: CGPoint(x: x, y: y))
            var cx = x
            while cx < end {
                let step = CGFloat.random(in: 3.2 ... 4.6, using: &random)
                let tall = Double.random(in: 0 ... 1, using: &random) < 0.1
                let h = tall ? CGFloat.random(in: 5.5 ... 7.5, using: &random) : .random(in: 2.4 ... 4, using: &random)
                path.addCurve(
                    to: CGPoint(x: cx + step, y: y),
                    control1: CGPoint(x: cx + step * (tall ? -0.3 : 0.1), y: y - h),
                    control2: CGPoint(x: cx + step * 0.9, y: y - h)
                )
                cx += step
            }
            x = end + .random(in: 4.5 ... 8, using: &random)
        }
        return path
    }
}

/// Lines of handwriting in one colour, written up to `progress` (0 to 1).
struct Writing: View {
    var lines: Int
    var color: Color = Paper.graphite
    var seed: UInt64
    var progress: Double = 1
    var lineHeight: CGFloat = 13
    var lastLine: CGFloat = 0.6

    var body: some View {
        VStack(alignment: .leading, spacing: lineHeight - 9) {
            ForEach(0 ..< lines, id: \.self) { index in
                let shown = clamp01(progress * Double(lines) - Double(index))
                GeometryReader { geometry in
                    Scribble(seed: seed &+ UInt64(index))
                        .trim(from: 0, to: shown)
                        .stroke(color, style: StrokeStyle(lineWidth: 1.3, lineCap: .round, lineJoin: .round))
                        .frame(width: geometry.size.width * (index == lines - 1 ? lastLine : 1))
                }
                .frame(height: 9)
            }
        }
    }
}

/// A curved arrow drawn by hand, from `from` to `to` (in the parent's coordinates), drawn up to `progress`.
struct HandArrow: View {
    var from: CGPoint
    var to: CGPoint
    var bend: CGFloat = 0.25
    var progress: Double = 1
    var seed: UInt64 = 5
    var color: Color = Paper.graphite

    var body: some View {
        let mid = CGPoint(x: (from.x + to.x) / 2, y: (from.y + to.y) / 2)
        let control = CGPoint(x: mid.x - (to.y - from.y) * bend, y: mid.y + (to.x - from.x) * bend)
        let angle = atan2(to.y - control.y, to.x - control.x)
        ZStack {
            Path { path in
                path.move(to: from)
                path.addQuadCurve(to: to, control: control)
            }
            .sketched(seed: seed, wobble: 0.8)
            .trim(from: 0, to: progress)
            .stroke(color, style: Paper.stroke)
            Path { path in
                for side in [-1.0, 1.0] {
                    path.move(to: to)
                    path.addLine(to: CGPoint(x: to.x - 9 * cos(angle + side * 0.45), y: to.y - 9 * sin(angle + side * 0.45)))
                }
            }
            .stroke(color, style: Paper.stroke)
            .opacity(progress >= 0.98 ? 1 : 0)
        }
    }
}

/// A five-pointed star, for a marked moment.
struct Star: Shape {
    func path(in rect: CGRect) -> Path {
        let center = CGPoint(x: rect.midX, y: rect.midY)
        let outer = min(rect.width, rect.height) / 2
        var path = Path()
        for i in 0 ..< 10 {
            let radius = i.isMultiple(of: 2) ? outer : outer * 0.45
            let angle = Double(i) * .pi / 5 - .pi / 2
            let point = CGPoint(x: center.x + radius * cos(angle), y: center.y + radius * sin(angle))
            if i == 0 { path.move(to: point) } else { path.addLine(to: point) }
        }
        path.closeSubpath()
        return path
    }
}

/// A tick, a cross or a dashed circle drawn in pencil: a step done, refused, or still to do.
struct HandStatus: View {
    var isDone: Bool?

    var body: some View {
        ZStack {
            switch isDone {
            case true?:
                Sketch(Circle(), seed: 41).pencil(Paper.green, outline: Paper.green, seed: 42)
                Path { path in
                    path.move(to: CGPoint(x: 6, y: 11.5))
                    path.addLine(to: CGPoint(x: 9.5, y: 15))
                    path.addLine(to: CGPoint(x: 16, y: 6.5))
                }
                .stroke(Paper.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round, lineJoin: .round))
            case false?:
                Sketch(Circle(), seed: 43).pencil(Paper.red, outline: Paper.red, seed: 44)
                Path { path in
                    path.move(to: CGPoint(x: 7, y: 7))
                    path.addLine(to: CGPoint(x: 15, y: 15))
                    path.move(to: CGPoint(x: 15, y: 7))
                    path.addLine(to: CGPoint(x: 7, y: 15))
                }
                .stroke(Paper.ink, style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
            case nil:
                Sketch(Circle(), seed: 45)
                    .stroke(Paper.graphite, style: StrokeStyle(lineWidth: 1.5, lineCap: .round, dash: [3, 4]))
            }
        }
        .frame(width: 22, height: 22)
        .accessibilityHidden(true)
    }
}

// MARK: - The sheet

/// Squared paper with the double red margin of a notebook.
struct PaperSheet: View {
    var margin: CGFloat = 52

    var body: some View {
        Canvas { context, size in
            context.fill(Path(CGRect(origin: .zero, size: size)), with: .color(Paper.sheet))
            var grid = Path()
            for x in stride(from: 0, through: size.width, by: 24) {
                grid.move(to: CGPoint(x: x, y: 0))
                grid.addLine(to: CGPoint(x: x, y: size.height))
            }
            for y in stride(from: 0, through: size.height, by: 24) {
                grid.move(to: CGPoint(x: 0, y: y))
                grid.addLine(to: CGPoint(x: size.width, y: y))
            }
            context.stroke(grid, with: .color(Paper.grid), lineWidth: 1)
            for (x, seed) in [(margin, UInt64(7)), (margin + 5, 8)] {
                let rule = Path { path in
                    path.move(to: CGPoint(x: x, y: -4))
                    path.addLine(to: CGPoint(x: x, y: size.height + 4))
                }
                context.stroke(rule.sketched(seed: seed, wobble: 0.9), with: .color(Paper.red.opacity(0.7)), lineWidth: 1.4)
            }
        }
        .ignoresSafeArea()
    }
}

/// The yellow button of takku.app, or a quiet one underlined in pencil.
struct PaperButtonStyle: ButtonStyle {
    var isPrimary = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        let pressed = configuration.isPressed
        configuration.label
            .font(Paper.hand(isPrimary ? 17 : 15, bold: isPrimary))
            .foregroundStyle(isPrimary ? Color(red: 0.11, green: 0.13, blue: 0.19) : Paper.pencil)
            .padding(.horizontal, isPrimary ? 18 : 4)
            .padding(.vertical, isPrimary ? 5 : 2)
            .background {
                if isPrimary {
                    ZStack {
                        box(21, radius: 3).fill(Color(red: 0.94, green: 0.71, blue: 0.24))
                        box(22, radius: 3).stroke(Color(red: 0.11, green: 0.13, blue: 0.19), style: Paper.stroke)
                    }
                    .offset(x: pressed ? 1.5 : 0, y: pressed ? 1.5 : 0)
                    .background(box(23, radius: 3).fill(Color(red: 0.11, green: 0.13, blue: 0.19)).offset(x: 3, y: 3))
                } else {
                    Sketch(Rectangle(), seed: 24, wobble: 0.6)
                        .frame(height: 1.4)
                        .foregroundStyle(Paper.pencil.opacity(pressed ? 1 : 0.6))
                        .frame(maxHeight: .infinity, alignment: .bottom)
                }
            }
            .offset(x: isPrimary && pressed ? 1.5 : 0, y: isPrimary && pressed ? 1.5 : 0)
            .opacity(isEnabled ? 1 : 0.45)
            .contentShape(Rectangle())
    }
}

/// Keys as small cards of paper, pressed down when `isPressed`.
struct Keycaps: View {
    var keys: [String]
    var isPressed = false
    var size: CGFloat = 26

    /// `⌃⌥⌘R` → `⌃`, `⌥`, `⌘`, `R`.
    init(_ shortcut: String, isPressed: Bool = false, size: CGFloat = 26) {
        let modifiers = shortcut.prefix { "⌃⌥⇧⌘".contains($0) }
        keys = modifiers.map(String.init) + [String(shortcut.dropFirst(modifiers.count))].filter { !$0.isEmpty }
        self.isPressed = isPressed
        self.size = size
    }

    var body: some View {
        HStack(spacing: 4) {
            ForEach(Array(keys.enumerated()), id: \.offset) { index, key in
                Text(verbatim: key)
                    .font(.system(size: size * 0.5, weight: .medium, design: .rounded))
                    .foregroundStyle(Paper.ink)
                    .frame(minWidth: size, minHeight: size)
                    .padding(.horizontal, key.count > 1 ? 4 : 0)
                    .background {
                        ZStack {
                            box(60 &+ UInt64(index), radius: 4).fill(isPressed ? Paper.yellow.opacity(0.5) : Paper.card)
                            box(70 &+ UInt64(index), radius: 4).stroke(Paper.ink, style: Paper.stroke)
                        }
                    }
                    .background(box(80 &+ UInt64(index), radius: 4).fill(Paper.ink.opacity(0.75)).offset(y: isPressed ? 0.5 : 2.5))
                    .offset(y: isPressed ? 2 : 0)
            }
        }
        .accessibilityElement()
        .accessibilityLabel(Text(verbatim: keys.joined()))
    }
}

/// Clamps to 0…1.
func clamp01(_ x: Double) -> Double { min(1, max(0, x)) }

/// 0 before `a`, 1 after `b`, smooth in between.
func ramp(_ t: Double, _ a: Double, _ b: Double) -> Double {
    let p = clamp01((t - a) / (b - a))
    return p * p * (3 - 2 * p)
}

/// A pop: 0 before `start`, then a quick overshoot that settles on 1.
func pop(_ t: Double, _ start: Double, duration: Double = 0.45) -> Double {
    guard t > start else { return 0 }
    let p = min(1, (t - start) / duration) - 1
    return 1 + 2.7 * p * p * p + 1.7 * p * p
}

/// Whether `t` is within `length` seconds after `start`: a key held down, a flash.
func pulse(_ t: Double, _ start: Double, length: Double = 0.3) -> Bool { t >= start && t < start + length }

/// Between keyframes `(time, value)`, eased; before the first and after the last, their value.
func keyframes(_ t: Double, _ frames: [(Double, CGPoint)]) -> CGPoint {
    guard var previous = frames.first else { return .zero }
    for frame in frames.dropFirst() {
        if t < frame.0 {
            let p = ramp(t, previous.0, frame.0)
            return CGPoint(x: previous.1.x + (frame.1.x - previous.1.x) * p, y: previous.1.y + (frame.1.y - previous.1.y) * p)
        }
        previous = frame
    }
    return previous.1
}
