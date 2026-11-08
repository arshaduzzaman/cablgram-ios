import SwiftUI
import CoreHaptics

// MARK: - Model

enum InkColor: String, Codable, CaseIterable, Identifiable {
    case pink, white, black, yellow, blue, green
    var id: String { rawValue }

    var color: Color {
        switch self {
        case .pink: .brand
        case .white: .white
        case .black: .black
        case .yellow: Color(red: 1.0, green: 0.84, blue: 0.04)
        case .blue: Color(red: 0.2, green: 0.68, blue: 0.9)
        case .green: Color(red: 0.19, green: 0.82, blue: 0.35)
        }
    }
}

enum BrushSize: CGFloat, CaseIterable, Identifiable {
    // Fraction of the picture's width.
    case thin = 0.008, medium = 0.016, thick = 0.032
    var id: CGFloat { rawValue }
}

/// One finger stroke, with points stored as fractions of the picture's size
/// so it lines up at any screen size.
struct Stroke: Codable, Identifiable {
    var id = UUID()
    var points: [CGPoint]
    var color: InkColor
    var width: CGFloat

    func path(in size: CGSize) -> Path {
        var path = Path()
        let pts = points.map { CGPoint(x: $0.x * size.width, y: $0.y * size.height) }
        guard let first = pts.first else { return path }
        path.move(to: first)
        if pts.count == 1 {
            path.addLine(to: first) // a dot
            return path
        }
        // Smooth curve through the midpoints.
        for i in 1..<pts.count {
            let mid = CGPoint(x: (pts[i - 1].x + pts[i].x) / 2, y: (pts[i - 1].y + pts[i].y) / 2)
            path.addQuadCurve(to: mid, control: pts[i - 1])
        }
        path.addLine(to: pts[pts.count - 1])
        return path
    }
}

/// A drawing left on a post, like a comment.
struct DoodleComment: Codable, Identifiable, Equatable {
    var id = UUID()
    var author: String
    var date: Date
    var strokes: [Stroke]

    static func == (lhs: DoodleComment, rhs: DoodleComment) -> Bool { lhs.id == rhs.id }
}

/// Drawing comments per post, saved on the phone for now. A backend can
/// replace this later so everyone sees each other's drawings.
@MainActor
final class DrawingStore: ObservableObject {
    @Published private(set) var comments: [String: [DoodleComment]] = [:]

    private static let folder: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }()
    private let url = folder.appendingPathComponent("doodle-comments.json")

    init() {
        if let data = try? Data(contentsOf: url),
           let saved = try? JSONDecoder().decode([String: [DoodleComment]].self, from: data) {
            comments = saved
        } else if let data = try? Data(contentsOf: Self.folder.appendingPathComponent("doodles.json")),
                  let old = try? JSONDecoder().decode([String: [Stroke]].self, from: data) {
            // Drawings from the earlier version become your first comments.
            comments = old.mapValues { [DoodleComment(author: "You", date: .now, strokes: $0)] }
            save()
        }
    }

    func comments(for postID: String) -> [DoodleComment] { comments[postID] ?? [] }

    func post(_ strokes: [Stroke], by author: String, on postID: String) {
        guard !strokes.isEmpty else { return }
        comments[postID, default: []].append(DoodleComment(author: author, date: .now, strokes: strokes))
        save()
    }

    func delete(_ commentID: UUID, on postID: String) {
        comments[postID]?.removeAll { $0.id == commentID }
        if comments[postID]?.isEmpty == true { comments[postID] = nil }
        save()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(comments) {
            try? data.write(to: url, options: .atomic)
        }
    }
}

/// Draws saved strokes over a picture.
struct DoodleCanvas: View {
    let strokes: [Stroke]
    var current: Stroke?

    var body: some View {
        Canvas { context, size in
            for stroke in strokes + [current].compactMap({ $0 }) {
                context.stroke(stroke.path(in: size), with: .color(stroke.color.color),
                               style: StrokeStyle(lineWidth: stroke.width * size.width,
                                                  lineCap: .round, lineJoin: .round))
            }
        }
        .allowsHitTesting(false)
    }
}

// MARK: - Haptics

/// Core Haptics for drawing: a continuous "pen on paper" buzz that follows
/// your speed, fine grain ticks along the stroke, and clicks on sharp corners.
@MainActor
final class DrawHaptics {
    private var engine: CHHapticEngine?
    private var pen: CHHapticAdvancedPatternPlayer?
    private var distanceSinceTick: CGFloat = 0
    private let supported = CHHapticEngine.capabilitiesForHardware().supportsHaptics

    private var enabled: Bool { supported && Haptics.isEnabled }

    func prepare() {
        guard enabled, engine == nil else { return }
        let engine = try? CHHapticEngine()
        engine?.playsHapticsOnly = true
        engine?.isAutoShutdownEnabled = false
        engine?.resetHandler = { [weak self] in
            Task { @MainActor in
                self?.pen = nil
                try? self?.engine?.start()
            }
        }
        try? engine?.start()
        self.engine = engine
    }

    func stop() {
        try? pen?.stop(atTime: CHHapticTimeImmediate)
        pen = nil
        engine?.stop()
        engine = nil
    }

    /// The hold that turns the photo into a canvas: a firm thump that
    /// swells briefly, like picking up a pen.
    func pickUp() {
        guard enabled else { return }
        prepare()
        let thump = transient(at: 0, intensity: 1, sharpness: 0.45)
        let swell = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 0.6),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.3),
        ], relativeTime: 0.02, duration: 0.14)
        let fade = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0.02, value: 1),
            .init(relativeTime: 0.16, value: 0),
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [thump, swell], parameterCurves: [fade]) {
            try? engine?.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        }
    }

    /// Pen touches the page.
    func strokeBegan(brush: BrushSize) {
        guard enabled else { return }
        prepare()
        distanceSinceTick = 0
        tap(intensity: brush == .thick ? 0.9 : 0.7, sharpness: brush == .thin ? 0.85 : 0.6)
        startPen()
    }

    /// Pen moving: `speed` in points per second, `turn` in radians.
    func strokeMoved(distance: CGFloat, speed: CGFloat, turn: CGFloat, brush: BrushSize) {
        guard enabled, let pen else { return }
        let weight: Float = brush == .thick ? 1.15 : (brush == .thin ? 0.8 : 1)
        let intensity = min(max(0.16 + Float(speed) / 1_700, 0.16), 0.9) * weight
        let sharpness = min(max(0.22 + Float(speed) / 2_600, 0.2), 0.85) - (brush == .thick ? 0.12 : 0)

        try? pen.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: min(intensity, 1), relativeTime: 0),
            CHHapticDynamicParameter(parameterID: .hapticSharpnessControl, value: max(sharpness, 0), relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)

        // Paper grain: a tiny tick every few millimetres of ink.
        distanceSinceTick += distance
        let spacing: CGFloat = brush == .thin ? 10 : 14
        if distanceSinceTick >= spacing {
            distanceSinceTick = 0
            tap(intensity: min(intensity * 0.55, 0.6), sharpness: 0.95)
        }

        // Sharp corner: a crisp click.
        if turn > 1.1 && distance > 2 {
            tap(intensity: 0.85, sharpness: 0.75)
        }
    }

    /// Pen lifts off.
    func strokeEnded() {
        guard enabled else { return }
        try? pen?.stop(atTime: CHHapticTimeImmediate)
        pen = nil
        tap(intensity: 0.35, sharpness: 0.2)
    }

    /// Undo: a quick double pop.
    func undo() {
        guard enabled else { return }
        prepare()
        play([
            transient(at: 0, intensity: 0.9, sharpness: 0.9),
            transient(at: 0.07, intensity: 0.5, sharpness: 0.9),
        ])
    }

    /// Clear: a rumble that fades out, like wiping the page.
    func wipe() {
        guard enabled else { return }
        prepare()
        let rumble = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.25),
        ], relativeTime: 0, duration: 0.45)
        let fade = CHHapticParameterCurve(parameterID: .hapticIntensityControl, controlPoints: [
            .init(relativeTime: 0, value: 0.9),
            .init(relativeTime: 0.45, value: 0),
        ], relativeTime: 0)
        if let pattern = try? CHHapticPattern(events: [rumble], parameterCurves: [fade]) {
            try? engine?.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
        }
    }

    /// Picking a colour or brush.
    func pick() {
        guard enabled else { return }
        prepare()
        tap(intensity: 0.5, sharpness: 0.7)
    }

    // MARK: Building blocks

    private func startPen() {
        guard let engine else { return }
        let hum = CHHapticEvent(eventType: .hapticContinuous, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: 1),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: 0.5),
        ], relativeTime: 0, duration: 100)
        guard let pattern = try? CHHapticPattern(events: [hum], parameters: []),
              let player = try? engine.makeAdvancedPlayer(with: pattern) else { return }
        try? player.start(atTime: CHHapticTimeImmediate)
        try? player.sendParameters([
            CHHapticDynamicParameter(parameterID: .hapticIntensityControl, value: 0.16, relativeTime: 0),
        ], atTime: CHHapticTimeImmediate)
        pen = player
    }

    private func tap(intensity: Float, sharpness: Float) {
        play([transient(at: 0, intensity: intensity, sharpness: sharpness)])
    }

    private func transient(at time: TimeInterval, intensity: Float, sharpness: Float) -> CHHapticEvent {
        CHHapticEvent(eventType: .hapticTransient, parameters: [
            CHHapticEventParameter(parameterID: .hapticIntensity, value: intensity),
            CHHapticEventParameter(parameterID: .hapticSharpness, value: sharpness),
        ], relativeTime: time)
    }

    private func play(_ events: [CHHapticEvent]) {
        guard let engine, let pattern = try? CHHapticPattern(events: events, parameters: []) else { return }
        try? engine.makePlayer(with: pattern).start(atTime: CHHapticTimeImmediate)
    }
}
