import SwiftUI

// The pieces the welcome scenes are drawn with: the menu bar, a call, a Transcript, a meeting
// note, the pointer. Each one is drawn for a moment of the scene, never animated on its own.

extension View {
    /// Places the view at `x`, `y` with that size, in a stage aligned top-leading.
    func at(_ x: CGFloat, _ y: CGFloat, _ width: CGFloat, _ height: CGFloat) -> some View {
        frame(width: width, height: height).offset(x: x, y: y)
    }

    /// A loose sheet on the paper.
    func card(_ seed: UInt64, radius: CGFloat = 6) -> some View {
        background {
            ZStack {
                box(seed, radius: radius).fill(Paper.card)
                box(seed &+ 1, radius: radius).stroke(Paper.ink, style: Paper.stroke)
            }
        }
    }
}

/// What the Takku item in the menu bar shows.
enum MenuBarItem: Equatable {
    case idle
    case recording(seconds: Int)
    case mark(seconds: Int)
    case screenshot(seconds: Int)
}

/// A strip of menu bar with Takku's item on the right.
struct MenuBarStrip: View {
    var item: MenuBarItem

    var body: some View {
        HStack(spacing: 14) {
            Spacer()
            ForEach(0 ..< 3) { index in
                Scribble(seed: 90 &+ UInt64(index))
                    .stroke(Paper.graphite.opacity(0.6), style: StrokeStyle(lineWidth: 1.2, lineCap: .round))
                    .frame(width: [26, 18, 30][index], height: 9)
            }
            takku.frame(minWidth: 56, alignment: .leading)
            Text(verbatim: "9:41").font(Paper.hand(13)).foregroundStyle(Paper.graphite)
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .card(95, radius: 4)
    }

    @ViewBuilder private var takku: some View {
        HStack(spacing: 4) {
            switch item {
            case .idle:
                Image("MenuBarIcon").renderingMode(.template).foregroundStyle(Paper.ink)
            case .recording(let seconds):
                Sketch(Circle(), seed: 96).pencil(Paper.red, outline: Paper.red).frame(width: 11, height: 11)
                time(seconds)
            case .mark(let seconds):
                Sketch(Star(), seed: 97, wobble: 0.5).pencil(Paper.yellow).frame(width: 15, height: 15)
                time(seconds)
            case .screenshot(let seconds):
                Image(systemName: "camera.fill").font(.system(size: 11)).foregroundStyle(Paper.ink)
                time(seconds)
            }
        }
    }

    private func time(_ seconds: Int) -> some View {
        Text(verbatim: String(format: "%d:%02d", seconds / 60, seconds % 60))
            .font(Paper.hand(13))
            .foregroundStyle(Paper.ink)
            .monospacedDigit()
    }
}

/// A person in a call: a head and shoulders in coloured pencil, with sound waves while speaking.
struct Person: View {
    var color: Color
    var seed: UInt64
    var isSpeaking = false

    var body: some View {
        GeometryReader { geometry in
            let size = min(geometry.size.width, geometry.size.height)
            ZStack {
                Sketch(Circle(), seed: seed).pencil(color, seed: seed &+ 1)
                    .frame(width: size * 0.34, height: size * 0.34)
                    .offset(y: -size * 0.14)
                Sketch(Ellipse(), seed: seed &+ 2).pencil(color, seed: seed &+ 3)
                    .frame(width: size * 0.62, height: size * 0.4)
                    .offset(y: size * 0.3)
                    .clipShape(Rectangle().offset(y: -size * 0.02))
                if isSpeaking {
                    ForEach(0 ..< 2) { ring in
                        Sketch(Circle().trim(from: 0.05, to: 0.2), seed: seed &+ 4 &+ UInt64(ring))
                            .stroke(color, style: Paper.stroke)
                            .frame(width: size * (0.5 + 0.18 * CGFloat(ring)), height: size * (0.5 + 0.18 * CGFloat(ring)))
                            .offset(y: -size * 0.14)
                    }
                }
            }
            .frame(width: geometry.size.width, height: geometry.size.height)
        }
    }
}

/// A call window: two people, and you in a corner. `slide` shares a slide instead.
struct CallWindow: View {
    var speaking: Int?
    var slide = false

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 5) {
                ForEach(0 ..< 3) { index in
                    Sketch(Circle(), seed: 100 &+ UInt64(index)).stroke(Paper.ink, lineWidth: 1.2).frame(width: 8, height: 8)
                }
                Spacer()
            }
            .padding(.horizontal, 8)
            .frame(height: 18)
            Sketch(Rectangle(), seed: 104, wobble: 0.5).frame(height: 1.4).foregroundStyle(Paper.ink)
            ZStack(alignment: .bottomTrailing) {
                if slide {
                    Slide().padding(10)
                } else {
                    HStack(spacing: 8) {
                        Person(color: Paper.blue, seed: 110, isSpeaking: speaking == 0)
                        Person(color: Paper.green, seed: 120, isSpeaking: speaking == 1)
                    }
                    .padding(10)
                }
                Person(color: Paper.red, seed: 130, isSpeaking: speaking == 2)
                    .frame(width: 34, height: 30)
                    .card(131, radius: 3)
                    .padding(6)
            }
        }
        .card(105)
    }
}

/// A slide shared in a call: a title and a bar chart.
struct Slide: View {
    var body: some View {
        GeometryReader { geometry in
            let w = geometry.size.width, h = geometry.size.height
            ZStack(alignment: .topLeading) {
                Scribble(seed: 140).stroke(Paper.ink, style: StrokeStyle(lineWidth: max(1, w / 140), lineCap: .round))
                    .frame(width: w * 0.5, height: h * 0.12)
                    .offset(x: w * 0.04, y: h * 0.04)
                HStack(alignment: .bottom, spacing: w * 0.06) {
                    ForEach(Array([0.35, 0.55, 0.45, 0.8].enumerated()), id: \.offset) { index, value in
                        Sketch(Rectangle(), seed: 141 &+ UInt64(index), wobble: max(0.3, w / 300))
                            .pencil([Paper.blue, Paper.green, Paper.blue, Paper.yellow][index], seed: 150 &+ UInt64(index))
                            .frame(width: w * 0.13, height: h * 0.62 * value)
                    }
                }
                .frame(width: w * 0.85, height: h * 0.7, alignment: .bottom)
                .offset(x: w * 0.06, y: h * 0.24)
                Sketch(Rectangle(), seed: 149, wobble: 0.4).frame(width: w * 0.88, height: 1.2)
                    .foregroundStyle(Paper.ink)
                    .offset(x: w * 0.04, y: h * 0.94)
            }
        }
    }
}

/// A line of a Transcript: who speaks, in their colour, and what they say.
struct TranscriptLine: View {
    var name: String
    var color: Color
    var lines = 1
    var seed: UInt64
    var progress = 1.0

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(verbatim: name).font(Paper.hand(13, bold: true)).foregroundStyle(color)
            Writing(lines: lines, color: color.opacity(0.85), seed: seed, progress: progress, lastLine: lines == 1 ? 0.8 : 0.55)
        }
        .opacity(progress > 0 ? 1 : 0)
    }
}

/// A meeting note, as in Obsidian: the title, the Summary highlighted on top, your notes under it.
struct NoteSketch<Title: View>: View {
    var summary: Double
    var seed: UInt64 = 160
    /// Lines of your own notes under the Summary.
    var personal = 2
    @ViewBuilder var title: Title

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            title.frame(height: 22, alignment: .leading)
            ZStack(alignment: .topLeading) {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0 ..< 3) { index in
                        Rectangle().fill(Paper.highlight)
                            .frame(height: 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .scaleEffect(x: clamp01(summary * 3 - Double(index)) * (index == 2 ? 0.6 : 1), anchor: .leading)
                    }
                }
                Writing(lines: 3, color: Paper.graphite, seed: seed, progress: summary)
            }
            if personal > 0 {
                Writing(lines: personal, color: Paper.graphite.opacity(0.45), seed: seed &+ 10)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 18)
        .padding(.bottom, 12)
        .frame(maxHeight: .infinity, alignment: .top)
        .card(seed)
        .overlay(alignment: .top) {
            HStack(spacing: 40) {
                ForEach(0 ..< 2) { ring in
                    Sketch(Capsule(), seed: seed &+ 20 &+ UInt64(ring)).stroke(Paper.ink, style: Paper.stroke)
                        .frame(width: 8, height: 18)
                }
            }
            .offset(y: -9)
        }
    }
}

/// Sound in a lane: bars that move while `isActive`.
struct Waveform: View {
    var t: Double
    var color: Color
    var isActive: Bool
    var seed: Double = 0

    var body: some View {
        Canvas { context, size in
            let count = Int(size.width / 5)
            var bars = Path()
            for i in 0 ..< count {
                let x = CGFloat(i) * 5 + 2
                let level = isActive
                    ? 0.2 + 0.8 * abs(sin(Double(i) * 0.7 + t * 9 + seed) * sin(Double(i) * 0.23 + t * 3.1 + seed * 2))
                    : 0.06
                let h = max(1.5, size.height * level)
                bars.move(to: CGPoint(x: x, y: size.height / 2 - h / 2))
                bars.addLine(to: CGPoint(x: x, y: size.height / 2 + h / 2))
            }
            context.stroke(bars, with: .color(color), style: StrokeStyle(lineWidth: 2.2, lineCap: .round))
        }
    }
}

/// The mouse pointer, drawn: an arrow of paper with an ink outline, pressed while `isClicking`.
struct Pointer: View {
    var isClicking = false

    var body: some View {
        Sketch(PointerShape(), seed: 170, wobble: 0.5)
            .pencil(Paper.card, outline: Paper.ink)
            .frame(width: 16, height: 22)
            .scaleEffect(isClicking ? 0.85 : 1, anchor: .topLeading)
            .overlay(alignment: .topLeading) {
                if isClicking {
                    Sketch(Circle(), seed: 171).stroke(Paper.red, style: Paper.stroke)
                        .frame(width: 22, height: 22)
                        .offset(x: -11, y: -11)
                }
            }
    }
}

private struct PointerShape: Shape {
    func path(in rect: CGRect) -> Path {
        Path { path in
            let w = rect.width, h = rect.height
            path.move(to: CGPoint(x: 0, y: 0))
            path.addLine(to: CGPoint(x: 0, y: h * 0.8))
            path.addLine(to: CGPoint(x: w * 0.3, y: h * 0.6))
            path.addLine(to: CGPoint(x: w * 0.55, y: h))
            path.addLine(to: CGPoint(x: w * 0.72, y: h * 0.92))
            path.addLine(to: CGPoint(x: w * 0.48, y: h * 0.55))
            path.addLine(to: CGPoint(x: w, y: h * 0.55))
            path.closeSubpath()
        }
    }
}

/// A file, with its corner folded.
struct FileIcon: View {
    var name: String

    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Sketch(Folded(), seed: 180).pencil(Paper.card)
                Waveform(t: 0.3, color: Paper.red, isActive: true, seed: 2).frame(width: 30, height: 18).offset(y: 6)
            }
            .frame(width: 46, height: 58)
            Text(verbatim: name).font(Paper.hand(12)).foregroundStyle(Paper.ink)
        }
    }

    private struct Folded: Shape {
        func path(in rect: CGRect) -> Path {
            Path { path in
                let fold = rect.width * 0.32
                path.move(to: CGPoint(x: rect.minX, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.maxY))
                path.addLine(to: CGPoint(x: rect.minX, y: rect.maxY))
                path.closeSubpath()
                path.move(to: CGPoint(x: rect.maxX - fold, y: rect.minY))
                path.addLine(to: CGPoint(x: rect.maxX - fold, y: rect.minY + fold))
                path.addLine(to: CGPoint(x: rect.maxX, y: rect.minY + fold))
            }
        }
    }
}

/// A small handwritten label.
struct HandLabel: View {
    var text: LocalizedStringKey
    var color: Color = Paper.ink
    var size: CGFloat = 14
    var bold = false

    init(_ text: LocalizedStringKey, color: Color = Paper.ink, size: CGFloat = 14, bold: Bool = false) {
        self.text = text
        self.color = color
        self.size = size
        self.bold = bold
    }

    var body: some View {
        Text(text).font(Paper.hand(size, bold: bold)).foregroundStyle(color).fixedSize()
    }
}
