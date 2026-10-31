import SwiftUI

// The scenes of the welcome tour. Each one is a function of `t`, the seconds since its loop
// started: any moment draws the same, live or rendered (`-renderWelcome`), and with Reduce Motion
// the window shows one still moment (`still`). The stage is 620 × 350 and holds only drawings:
// what they mean is said by the caption under it, one beat at a time.

/// The shortcuts as the user set them, for the scenes to show.
struct WelcomeShortcuts {
    var startStop = "⌃⌥⌘R"
    var mark = "⌃⌥⌘M"
    var screenshot = "⌃⌥⌘S"
}

enum WelcomeStage {
    static let size = CGSize(width: 620, height: 350)

    /// Everything fades out in the last half second of a loop, before it starts again.
    static func fade(_ t: Double, loop: Double) -> Double { 1 - ramp(t, loop - 0.5, loop - 0.05) }
}

/// A line of the caption, shown from `start` until the next one.
struct Beat {
    var start: Double
    var text: Text
}

/// The caption under the stage: the beat of the moment, fading in and out.
struct Caption: View {
    var beats: [Beat]
    var t: Double
    var loop: Double

    var body: some View {
        let index = beats.lastIndex { $0.start <= t } ?? 0
        let end = index + 1 < beats.count ? beats[index + 1].start : loop
        beats[index].text
            .opacity(ramp(t, beats[index].start, beats[index].start + 0.4) * (1 - ramp(t, end - 0.4, end)))
    }
}

// MARK: - 1. What Takku does

/// Your microphone and the call become a Transcript on your Mac, then a note with the Summary on top.
struct HeroScene: View {
    static let loop = 14.5
    static let still = 13.0
    var t: Double

    static let beats = [
        Beat(start: 0, text: Text("Takku hears your microphone and the call, from Meet, Zoom, Teams or any other app.")),
        Beat(start: 4.5, text: Text("It transcribes them on this Mac: the audio never leaves it.")),
        Beat(start: 9, text: Text("Then it writes the note in your Obsidian vault, with the Summary on top.")),
    ]

    var body: some View {
        ZStack(alignment: .topLeading) {
            Microphone().at(52, 44, 40, 92)
            CallWindow(speaking: t < 9 ? Int(t / 1.3) % 3 : nil).at(10, 196, 150, 104)

            HandArrow(from: CGPoint(x: 100, y: 88), to: CGPoint(x: 220, y: 122), bend: -0.2, progress: ramp(t, 0.5, 1.2))
            HandArrow(from: CGPoint(x: 166, y: 246), to: CGPoint(x: 220, y: 212), bend: 0.2, progress: ramp(t, 0.5, 1.2), seed: 6)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(Array([Paper.red, Paper.blue, Paper.blue, Paper.green, Paper.red, Paper.green, Paper.blue].enumerated()), id: \.offset) { index, color in
                    Writing(lines: 1, color: color, seed: 200 &+ UInt64(index), progress: clamp01(ramp(t, 4.5, 8.5) * 7 - Double(index)), lastLine: 1)
                }
            }
            .padding(14)
            .frame(maxHeight: .infinity, alignment: .top)
            .card(210)
            .at(226, 84, 170, 180)
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Paper.red)
                .offset(x: 376, y: 64)
                .scaleEffect(pop(t, 4.8), anchor: .center)

            HandArrow(from: CGPoint(x: 402, y: 174), to: CGPoint(x: 444, y: 174), bend: 0, progress: ramp(t, 9, 9.5), seed: 7)

            NoteSketch(summary: ramp(t, 9.6, 12)) {
                Scribble(seed: 220).stroke(Paper.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 80, height: 12)
            }
            .at(452, 60, 156, 230)
            .opacity(ramp(t, 9.2, 9.6))
        }
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
        .opacity(WelcomeStage.fade(t, loop: Self.loop))
    }
}

/// A microphone in red pencil.
private struct Microphone: View {
    var body: some View {
        ZStack(alignment: .top) {
            Sketch(Capsule(), seed: 230).pencil(Paper.red, seed: 231).frame(width: 24, height: 46)
            Sketch(Circle().trim(from: 0, to: 0.5), seed: 232).stroke(Paper.ink, style: Paper.stroke)
                .frame(width: 36, height: 36).offset(y: 22)
            Sketch(Rectangle(), seed: 233, wobble: 0.4).frame(width: 1.6, height: 22).foregroundStyle(Paper.ink).offset(y: 58)
            Sketch(Rectangle(), seed: 234, wobble: 0.4).frame(width: 22, height: 1.6).foregroundStyle(Paper.ink).offset(y: 80)
        }
        .frame(maxHeight: .infinity, alignment: .top)
    }
}

// MARK: - 2. How it goes

/// The shortcut starts a Meeting, the menu bar counts, the call is heard; at the stop the
/// Summary is written at the top of the note, which gets a title.
struct HowItWorksScene: View {
    static let loop = 17.0
    static let still = 15.5
    var t: Double
    var shortcuts: WelcomeShortcuts

    private static let start = 2.0
    private static let stop = 10.0
    private var isRecording: Bool { t >= Self.start && t < Self.stop }
    private var speaker: Int? { isRecording && t > Self.start + 0.4 ? Int((t - Self.start - 0.4) / 1.6) % 3 : nil }

    static func beats(_ shortcuts: WelcomeShortcuts) -> [Beat] {
        [
            Beat(start: 0, text: Text("Press \(shortcuts.startStop) from any app, or start from the menu bar.")),
            Beat(start: 4, text: Text("Takku hears your microphone and the call, apart, and transcribes them on this Mac.")),
            Beat(start: 10, text: Text("Press it again to stop: the Summary goes at the top of the note, which gets a short title.")),
        ]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuBarStrip(item: isRecording ? .recording(seconds: Int(t - Self.start)) : .idle).at(0, 0, 620, 28)

            CallWindow(speaking: speaker).at(20, 44, 280, 190)

            lane(symbol: "mic.fill", color: Paper.red, isActive: speaker == 2, seed: 0).at(20, 252, 280, 26)
            lane(symbol: "speaker.wave.2.fill", color: Paper.blue, isActive: speaker == 0 || speaker == 1, seed: 1.3).at(20, 290, 280, 26)

            VStack(alignment: .leading, spacing: 6) {
                let rows: [(String, Color)] = [
                    ("Speaker 1", Paper.blue), ("Speaker 2", Paper.green),
                    ("Me", Paper.red), ("Speaker 1", Paper.blue),
                ]
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    TranscriptLine(name: row.0, color: row.1, seed: 300 &+ UInt64(index), progress: ramp(t, 3.2 + 1.6 * Double(index), 4.2 + 1.6 * Double(index)))
                }
            }
            .padding(12)
            .frame(maxHeight: .infinity, alignment: .top)
            .card(310)
            .at(330, 40, 270, 182)

            NoteSketch(summary: ramp(t, 10.8, 12.8), seed: 320, personal: 0) {
                ZStack(alignment: .leading) {
                    Scribble(seed: 321).stroke(Paper.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round))
                        .frame(width: 90, height: 12)
                        .opacity(1 - ramp(t, 13, 13.2))
                    Text("Q4 launch plan").font(Paper.hand(16, bold: true)).foregroundStyle(Paper.ink)
                        .scaleEffect(pop(t, 13.1), anchor: .leading)
                }
            }
            .at(330, 244, 270, 100)
            .opacity(ramp(t, 10.3, 10.7))
            .offset(y: 12 * (1 - ramp(t, 10.3, 10.7)))
        }
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
        .clipped()
        .opacity(WelcomeStage.fade(t, loop: Self.loop))
    }

    /// The keys, under the stage next to the caption: shown while the caption talks about them.
    static func keys(_ t: Double, shortcuts: WelcomeShortcuts) -> some View {
        Keycaps(shortcuts.startStop, isPressed: pulse(t, start - 0.15) || pulse(t, stop - 0.15), size: 30)
            .opacity(ramp(t, 0.2, 0.5) * (1 - ramp(t, 3.6, 4)) + ramp(t, 8.6, 9) * (1 - ramp(t, 16, 16.4)))
    }

    private func lane(symbol: String, color: Color, isActive: Bool, seed: Double) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol).font(.system(size: 13)).foregroundStyle(color).frame(width: 22)
            Waveform(t: t, color: color, isActive: isActive, seed: seed)
        }
    }
}

// MARK: - 3. Mark and capture

/// ⌃⌥⌘M stars a moment in the Summary; ⌃⌥⌘S takes the shared window and puts it under its point.
/// The keys are on the stage from the start, one shortcut at a time, then both to try.
struct MarkAndCaptureScene: View {
    static let loop = 17.0
    static let still = 12.0
    /// When the keys go down: a shortcut tried during this page starts the loop here.
    static let markAt = 2.0
    static let screenshotAt = 8.6
    private static let tryAt = 13.0
    var t: Double
    var shortcuts: WelcomeShortcuts

    static func beats(_ shortcuts: WelcomeShortcuts) -> [Beat] {
        [
            Beat(start: 0, text: Text("\(shortcuts.mark) marks a moment: it gets a star, and the Summary gives it priority.")),
            Beat(start: 6.6, text: Text("\(shortcuts.screenshot) keeps the window you are looking at, under its point in the Summary.")),
            Beat(start: tryAt, text: Text("Try them now: press \(shortcuts.mark) or \(shortcuts.screenshot).")),
        ]
    }

    private var item: MenuBarItem {
        let seconds = 754 + Int(t)
        if t >= Self.markAt && t < Self.markAt + 1.2 { return .mark(seconds: seconds) }
        if t >= Self.screenshotAt && t < Self.screenshotAt + 1.2 { return .screenshot(seconds: seconds) }
        return .recording(seconds: seconds)
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuBarStrip(item: item).at(0, 0, 620, 28)

            CallWindow(slide: true).at(20, 64, 300, 240)
            box(260, radius: 6).fill(.white)
                .at(20, 64, 300, 240)
                .opacity(t > Self.screenshotAt ? 0.9 * (1 - ramp(t, Self.screenshotAt, Self.screenshotAt + 0.5)) : 0)

            note.at(350, 44, 250, 296)

            if t > Self.screenshotAt + 0.2 {
                let p = ramp(t, Self.screenshotAt + 0.2, Self.screenshotAt + 1.5)
                let from = CGRect(x: 30, y: 92, width: 280, height: 204)
                let to = CGRect(x: 384, y: 210, width: 112, height: 72)
                Slide()
                    .padding(4)
                    .card(270, radius: 2)
                    .overlay(alignment: .top) {
                        Rectangle().fill(Paper.yellow.opacity(0.5)).frame(width: 34, height: 11)
                            .rotationEffect(.degrees(-8))
                            .offset(y: -6)
                            .opacity(ramp(t, Self.screenshotAt + 1.5, Self.screenshotAt + 1.7))
                    }
                    .rotationEffect(.degrees(-3 * p))
                    .at(
                        from.minX + (to.minX - from.minX) * p, from.minY + (to.minY - from.minY) * p,
                        from.width + (to.width - from.width) * p, from.height + (to.height - from.height) * p
                    )
            }
        }
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
        .opacity(WelcomeStage.fade(t, loop: Self.loop))
    }

    /// The keys, under the stage next to the caption: one shortcut, then the other, then both to try.
    static func keys(_ t: Double, shortcuts: WelcomeShortcuts) -> some View {
        let apart = ramp(t, tryAt, tryAt + 0.5)
        return ZStack {
            Keycaps(shortcuts.mark, isPressed: pulse(t, markAt - 0.15), size: 30)
                .offset(x: -85 * apart)
                .opacity((1 - ramp(t, 6.2, 6.6)) + apart)
            Keycaps(shortcuts.screenshot, isPressed: pulse(t, screenshotAt - 0.15), size: 30)
                .offset(x: 85 * apart)
                .opacity(ramp(t, 6.6, 7))
        }
    }

    private var note: some View {
        VStack(alignment: .leading, spacing: 10) {
            HandLabel("Summary", size: 16, bold: true)
            ForEach(0 ..< 3) { index in
                HStack(alignment: .top, spacing: 6) {
                    ZStack {
                        Text(verbatim: "•").font(Paper.hand(15)).foregroundStyle(Paper.ink).opacity(index == 1 && t > Self.markAt + 0.2 ? 0 : 1)
                        if index == 1 {
                            Sketch(Star(), seed: 280, wobble: 0.5).pencil(Paper.yellow)
                                .frame(width: 16, height: 16)
                                .scaleEffect(pop(t, Self.markAt + 0.2))
                        }
                    }
                    .frame(width: 16, height: 16)
                    ZStack(alignment: .topLeading) {
                        if index == 1 {
                            Rectangle().fill(Paper.highlight).frame(height: 22)
                                .scaleEffect(x: ramp(t, Self.markAt + 0.5, Self.markAt + 1.3), anchor: .leading)
                                .offset(y: -1)
                        }
                        Writing(lines: 2, color: Paper.graphite, seed: 290 &+ UInt64(index))
                    }
                }
            }
            Spacer()
        }
        .padding(.horizontal, 14)
        .padding(.top, 14)
        .card(285)
    }
}

// MARK: - 4. Who spoke

/// *Name speakers…* plays each voice and suggests the calendar's participants; a voice named
/// before is recognised; on Save the names go into the Transcript.
struct SpeakersScene: View {
    static let loop = 15.5
    static let still = 13.0
    var t: Double

    private static let play = 1.4
    private static let chip = 5.2
    private static let save = 10.0

    static let beats = [
        Beat(start: 0, text: Text("*Name speakers…* plays a few seconds of each voice, so you know who is who.")),
        Beat(start: 4.5, text: Text("It suggests who was invited to the event, and recognises the voices you named before, only on this Mac.")),
        Beat(start: 9.6, text: Text("Save: the names go into the Transcript and the Summary.")),
    ]

    private var pointer: CGPoint {
        keyframes(t, [
            (0.2, CGPoint(x: 600, y: 360)), (1.1, CGPoint(x: 575, y: 82)), (2.2, CGPoint(x: 575, y: 82)),
            (4.6, CGPoint(x: 380, y: 270)), (8.4, CGPoint(x: 380, y: 270)),
            (9.6, CGPoint(x: 540, y: 316)), (10.8, CGPoint(x: 540, y: 316)), (11.8, CGPoint(x: 640, y: 370)),
        ])
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            transcript.at(20, 20, 260, 316)
            card.at(310, 20, 290, 316)
            Pointer(isClicking: pulse(t, Self.play, length: 0.2) || pulse(t, Self.chip, length: 0.2) || pulse(t, Self.save, length: 0.2))
                .offset(x: pointer.x, y: pointer.y)
        }
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
        .clipped()
        .opacity(WelcomeStage.fade(t, loop: Self.loop))
    }

    private var transcript: some View {
        VStack(alignment: .leading, spacing: 9) {
            HandLabel("Transcript", size: 15, bold: true)
            ForEach(Array([(0, 2), (1, 1), (0, 1), (1, 2), (0, 1)].enumerated()), id: \.offset) { index, row in
                let at = Self.save + 0.3 + 0.2 * Double(index)
                let named = ramp(t, at, at + 0.3)
                VStack(alignment: .leading, spacing: 2) {
                    ZStack(alignment: .leading) {
                        Text(verbatim: "Speaker \(row.0 + 1)").opacity(1 - named)
                        Text(verbatim: row.0 == 0 ? "Mario Rossi" : "Anna Bianchi").opacity(named)
                            .scaleEffect(named > 0 ? pop(t, at, duration: 0.35) : 1, anchor: .leading)
                    }
                    .font(Paper.hand(13, bold: true))
                    .foregroundStyle(row.0 == 0 ? Paper.blue : Paper.green)
                    Writing(lines: row.1, color: (row.0 == 0 ? Paper.blue : Paper.green).opacity(0.85), seed: 400 &+ UInt64(index), lastLine: row.1 == 1 ? 0.75 : 0.5)
                }
            }
            Spacer()
        }
        .padding(14)
        .card(410)
    }

    private var card: some View {
        let isPlaying = t > Self.play && t < Self.play + 2.4
        let typed = Int(ramp(t, Self.chip + 0.1, Self.chip + 0.9) * 11)
        return VStack(alignment: .leading, spacing: 0) {
            Text("Name speakers").font(Paper.hand(15, bold: true)).foregroundStyle(Paper.ink).padding(.bottom, 10)

            speakerHeader(number: 1, color: Paper.blue) {
                Waveform(t: t, color: Paper.blue, isActive: isPlaying)
                    .frame(width: 70, height: 16)
                    .opacity(isPlaying ? 1 : 0)
                play(isPlaying: isPlaying)
            }
            quote("“Let’s start from the numbers of the quarter…”")
            field(String("Mario Rossi".prefix(typed)), isFocused: t > Self.chip && t < Self.chip + 1.4)

            speakerHeader(number: 2, color: Paper.green) {
                HStack(spacing: 3) {
                    Image(systemName: "waveform").font(.system(size: 10))
                    HandLabel("recognised by voice", color: Paper.green, size: 12)
                }
                .foregroundStyle(Paper.green)
                .scaleEffect(pop(t, 7.2))
                play(isPlaying: false)
            }
            .padding(.top, 12)
            quote("“Yes, I have them here: we are above target.”")
            field("Anna Bianchi", isFocused: false).opacity(ramp(t, 6.8, 7.1))

            HStack(spacing: 6) {
                Image(systemName: "calendar").font(.system(size: 11)).foregroundStyle(Paper.graphite)
                ForEach(["Mario Rossi", "Anna Bianchi"], id: \.self) { name in
                    Text(verbatim: name).font(Paper.hand(12)).foregroundStyle(Paper.ink)
                        .padding(.horizontal, 7).padding(.vertical, 1)
                        .background(Sketch(Capsule(), seed: 420).stroke(Paper.graphite, style: Paper.stroke))
                }
            }
            .padding(.top, 12)
            Spacer(minLength: 0)
            HStack {
                Spacer()
                Text("Save and Regenerate")
                    .font(Paper.hand(13, bold: true))
                    .foregroundStyle(Color(red: 0.11, green: 0.13, blue: 0.19))
                    .padding(.horizontal, 10).padding(.vertical, 2)
                    .background(box(421, radius: 3).pencil(Paper.yellow, outline: Color(red: 0.11, green: 0.13, blue: 0.19)))
                    .offset(y: pulse(t, Self.save, length: 0.2) ? 1.5 : 0)
            }
        }
        .padding(14)
        .card(430)
    }

    private func speakerHeader(number: Int, color: Color, @ViewBuilder trailing: () -> some View) -> some View {
        HStack(spacing: 6) {
            Sketch(Circle(), seed: 440 &+ UInt64(number)).pencil(color).frame(width: 10, height: 10)
            Text(verbatim: "Speaker \(number)").font(Paper.hand(14, bold: true)).foregroundStyle(color)
            Spacer()
            trailing()
        }
        .frame(height: 22)
    }

    private func play(isPlaying: Bool) -> some View {
        Image(systemName: isPlaying ? "pause.fill" : "play.fill")
            .font(.system(size: 9))
            .foregroundStyle(Paper.ink)
            .frame(width: 22, height: 22)
            .background(Sketch(Circle(), seed: 450).stroke(Paper.ink, style: Paper.stroke))
    }

    private func quote(_ text: LocalizedStringKey) -> some View {
        Text(text).font(Paper.serif(11.5, italic: true)).foregroundStyle(Paper.graphite).lineLimit(1).padding(.vertical, 3)
    }

    private func field(_ text: String, isFocused: Bool) -> some View {
        HStack(spacing: 1) {
            Text(verbatim: text).font(Paper.hand(14)).foregroundStyle(Paper.ink)
            if isFocused { Rectangle().fill(Paper.ink).frame(width: 1.2, height: 15) }
            Spacer()
        }
        .padding(.horizontal, 8)
        .frame(height: 26)
        .background(box(460, radius: 4).stroke(isFocused ? Paper.pencil : Paper.graphite.opacity(0.6), style: Paper.stroke))
    }
}

// MARK: - 5. Beyond calls

/// Import a recording, choose a Template, teach Takku your words: one panel at a time, the others
/// dimmed, each played on its own clock.
struct BeyondCallsScene: View {
    static let loop = 18.0
    static let still = 17.0
    private static let turn = 6.0
    var t: Double

    static let beats = [
        Beat(start: 0, text: Text("Import audio: a voice memo, a lecture, a meeting in person or a video becomes a note like the others.")),
        Beat(start: turn, text: Text("Templates are Markdown files you write: notes for a lecture, a 1to1, your team’s meetings.")),
        Beat(start: 2 * turn, text: Text("The Vocabulary fixes names and jargon in the Transcript, and spells them right in the Summary.")),
    ]

    private var active: Int { min(2, Int(t / Self.turn)) }

    /// The panel's own time: playing while it is active, at its start before, at its end after.
    private func local(_ panel: Int) -> Double {
        panel == active ? t - Double(panel) * Self.turn : panel < active ? Self.turn : 0
    }

    var body: some View {
        HStack(alignment: .top, spacing: 25) {
            panel(0) { importing(local(0)) }
            panel(1) { templates(local(1), isActive: active == 1) }
            panel(2) { vocabulary(local(2)) }
        }
        .padding(.top, 30)
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
        .opacity(WelcomeStage.fade(t, loop: Self.loop))
    }

    private func panel(_ index: Int, @ViewBuilder content: () -> some View) -> some View {
        ZStack(alignment: .topLeading) { content() }
            .frame(width: 190, height: 260, alignment: .topLeading)
            .clipped()
            .opacity(index == active ? 1 : 0.35)
            .scaleEffect(index == active ? 1 : 0.96)
            .animation(.easeInOut(duration: 0.4), value: active)
    }

    private func importing(_ u: Double) -> some View {
        let drop = ramp(u, 0.8, 1.8)
        return ZStack(alignment: .topLeading) {
            Image(nsImage: NSImage(named: "AppIcon") ?? NSApp.applicationIconImage)
                .resizable()
                .frame(width: 64, height: 64)
                .scaleEffect(u > 1.8 ? pop(u, 1.8, duration: 0.4) * 0.15 + 0.85 + (u > 2.25 ? 0.15 : 0) : 1)
                .offset(x: 63, y: 70)
            FileIcon(name: "memo.m4a")
                .scaleEffect(1 - 0.6 * drop)
                .offset(x: 10 + 62 * drop, y: 2 + 70 * drop)
                .opacity(1 - ramp(u, 1.7, 1.85))
            HandArrow(from: CGPoint(x: 95, y: 140), to: CGPoint(x: 95, y: 158), bend: 0, progress: ramp(u, 2.3, 2.6), seed: 9)
            NoteSketch(summary: ramp(u, 2.8, 4.4), seed: 470, personal: 0) {
                Scribble(seed: 471).stroke(Paper.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 50, height: 10)
            }
            .at(30, 164, 130, 92)
            .opacity(ramp(u, 2.4, 2.8))
        }
    }

    private func templates(_ u: Double, isActive: Bool) -> some View {
        let cycle = Self.turn / 3
        let index = isActive ? min(2, Int(u / cycle)) : 0
        let shown = isActive ? ramp(u.truncatingRemainder(dividingBy: cycle), 0, 0.35) * (1 - ramp(u.truncatingRemainder(dividingBy: cycle), cycle - 0.3, cycle)) : 1
        return ZStack(alignment: .topLeading) {
            HStack(spacing: 6) {
                ForEach(Array(["Notes", "Lecture", "1to1"].enumerated()), id: \.offset) { position, name in
                    // Literata: in Kalam the 1 of 1to1 reads as an I.
                    Text(verbatim: name)
                        .font(Paper.serif(12.5))
                        .foregroundStyle(position == index ? Paper.ink : Paper.graphite)
                        .padding(.horizontal, 7)
                        .background {
                            if position == index { Sketch(Capsule(), seed: 480).pencil(Paper.yellow, outline: Paper.ink) }
                        }
                }
            }
            .offset(x: 6, y: 0)
            Group {
                switch index {
                case 0: notesLayout
                case 1: lectureLayout
                default: oneToOneLayout
                }
            }
            .padding(12)
            .frame(width: 176, height: 218, alignment: .topLeading)
            .opacity(shown)
            .card(490)
            .offset(x: 6, y: 30)
        }
    }

    private var notesLayout: some View {
        VStack(alignment: .leading, spacing: 9) {
            Scribble(seed: 500).stroke(Paper.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 70, height: 12)
            ForEach(0 ..< 4) { row in
                HStack(alignment: .top, spacing: 5) {
                    Text(verbatim: "•").font(Paper.hand(13)).foregroundStyle(Paper.ink)
                    Writing(lines: row == 1 ? 2 : 1, seed: 501 &+ UInt64(row), lastLine: 0.7)
                }
            }
        }
    }

    private var lectureLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            Scribble(seed: 510).stroke(Paper.ink, style: StrokeStyle(lineWidth: 2, lineCap: .round)).frame(width: 90, height: 12)
            Writing(lines: 2, seed: 511)
            Text(verbatim: "E = mc²").font(Paper.hand(15, bold: true)).foregroundStyle(Paper.pencil)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 3)
                .background(box(512, radius: 3).stroke(Paper.pencil, style: Paper.stroke))
            Scribble(seed: 513).stroke(Paper.ink, style: StrokeStyle(lineWidth: 1.8, lineCap: .round)).frame(width: 60, height: 10)
            Writing(lines: 2, seed: 514)
        }
    }

    private var oneToOneLayout: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .top, spacing: 12) {
                ForEach(Array(["Mario", "Anna"].enumerated()), id: \.offset) { column, name in
                    VStack(alignment: .leading, spacing: 5) {
                        Text(verbatim: name).font(Paper.hand(14, bold: true)).foregroundStyle(column == 0 ? Paper.blue : Paper.green)
                        Writing(lines: 3, color: column == 0 ? Paper.blue : Paper.green, seed: 520 &+ UInt64(column), lastLine: 0.6)
                    }
                }
            }
            ForEach(0 ..< 2) { row in
                HStack(spacing: 6) {
                    Sketch(Rectangle(), seed: 530 &+ UInt64(row)).stroke(Paper.ink, style: Paper.stroke).frame(width: 11, height: 11)
                    Writing(lines: 1, seed: 532 &+ UInt64(row), lastLine: 0.8)
                }
            }
        }
    }

    private func vocabulary(_ u: Double) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Writing(lines: 1, seed: 540, lastLine: 1)
            correction(heard: "cubernetes", right: "Kubernetes", at: 1, u: u)
            Writing(lines: 1, seed: 541, lastLine: 0.9)
            correction(heard: "di bi ti", right: "dbt", at: 3, u: u)
            Writing(lines: 2, seed: 542)
        }
        .padding(.horizontal, 12)
        .padding(.top, 26)
        .frame(width: 184, height: 248, alignment: .topLeading)
        .card(550)
    }

    private func correction(heard: String, right: String, at start: Double, u: Double) -> some View {
        HStack(alignment: .bottom, spacing: 6) {
            Scribble(seed: 560 &+ UInt64(start * 10)).stroke(Paper.graphite, style: StrokeStyle(lineWidth: 1.3, lineCap: .round))
                .frame(width: 30, height: 9)
                .padding(.bottom, 3)
            Text(verbatim: heard)
                .font(Paper.hand(14))
                .foregroundStyle(Paper.graphite)
                .overlay {
                    Sketch(Rectangle(), seed: 570, wobble: 0.6)
                        .frame(height: 1.8)
                        .foregroundStyle(Paper.red)
                        .scaleEffect(x: ramp(u, start, start + 0.4), anchor: .leading)
                }
                .overlay(alignment: .topLeading) {
                    Text(verbatim: right)
                        .font(Paper.hand(15, bold: true))
                        .foregroundStyle(Paper.green)
                        .fixedSize()
                        .mask(alignment: .leading) {
                            Rectangle().frame(width: 120 * ramp(u, start + 0.6, start + 1.3))
                        }
                        .offset(x: 2, y: -20)
                }
        }
        .padding(.top, 14)
    }
}

// MARK: - 8. Ready

/// Takku lives in the menu bar.
struct ReadyScene: View {
    static let loop = 8.0
    static let still = 6.5
    var t: Double
    var shortcuts: WelcomeShortcuts

    static func beats(_ shortcuts: WelcomeShortcuts) -> [Beat] {
        [Beat(start: 0, text: Text("Takku lives in the menu bar. \(shortcuts.startStop) starts and stops a meeting, from any app."))]
    }

    var body: some View {
        ZStack(alignment: .topLeading) {
            MenuBarStrip(item: t > 3.5 && t < 7.4 ? .recording(seconds: Int(t - 3.5)) : .idle).at(20, 50, 580, 32)
            HandArrow(from: CGPoint(x: 360, y: 220), to: CGPoint(x: 504, y: 96), bend: -0.3, progress: ramp(t, 0.4, 1.3), seed: 10, color: Paper.red)
            Keycaps(shortcuts.startStop, isPressed: pulse(t, 3.4) || pulse(t, 7.3), size: 44)
                .offset(x: 160, y: 220)
                .opacity(ramp(t, 1.5, 1.9))
        }
        .frame(width: WelcomeStage.size.width, height: WelcomeStage.size.height, alignment: .topLeading)
    }
}
