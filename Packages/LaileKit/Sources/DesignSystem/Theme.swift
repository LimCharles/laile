import LaileCore
import SwiftUI
import UIKit

/// Laile's visual language: warm, calm, high-contrast, big type. Colors adapt to dark mode.
public enum Theme {
    public static let accent = Color(light: 0x0F8A6A, dark: 0x3CC49B)
    public static let accentSoft = Color(light: 0xDFF3EC, dark: 0x173A2F)
    public static let reward = Color(light: 0xE8930C, dark: 0xF5B041)
    public static let rewardSoft = Color(light: 0xFFF1DC, dark: 0x3A2A12)
    public static let flame = Color(light: 0xE8590C, dark: 0xFF8A3D)
    public static let danger = Color(light: 0xC62828, dark: 0xFF8A80)
    public static let dangerSoft = Color(light: 0xFDE7E5, dark: 0x3D1C1A)
    public static let warn = Color(light: 0xB35C00, dark: 0xF0A24A)
    public static let background = Color(light: 0xF6F7F5, dark: 0x0E1311)
    public static let surface = Color(light: 0xFFFFFF, dark: 0x171E1B)
    public static let surface2 = Color(light: 0xEEF2EF, dark: 0x202925)
    public static let text = Color(light: 0x17211C, dark: 0xE8EEEA)
    public static let muted = Color(light: 0x5D6B63, dark: 0x9AABA2)
    public static let live = Color(light: 0xD62D20, dark: 0xFF5A4E)

    public static let corner: CGFloat = 20
}

public extension Color {
    init(light: UInt32, dark: UInt32) {
        self.init(uiColor: UIColor { traits in
            UIColor(hex: traits.userInterfaceStyle == .dark ? dark : light)
        })
    }
}

public extension UIColor {
    convenience init(hex: UInt32) {
        self.init(red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255, blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

public extension Font {
    static let laileHero = Font.system(size: 64, weight: .heavy, design: .rounded)
    static let laileTitle = Font.system(.title2, design: .rounded).weight(.bold)
    static let laileHeadline = Font.system(.headline, design: .rounded)
}

// MARK: - Components

public struct Card<Content: View>: View {
    let content: Content
    var padding: CGFloat

    public init(padding: CGFloat = 16, @ViewBuilder content: () -> Content) {
        self.content = content()
        self.padding = padding
    }

    public var body: some View {
        content
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Theme.surface, in: RoundedRectangle(cornerRadius: Theme.corner, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.corner, style: .continuous).stroke(Theme.surface2, lineWidth: 1))
    }
}

public struct PrimaryButtonStyle: ButtonStyle {
    var color: Color
    public init(color: Color = Theme.accent) { self.color = color }

    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.laileHeadline)
            .foregroundStyle(.white)
            .padding(.vertical, 14)
            .frame(maxWidth: .infinity)
            .background(color.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .scaleEffect(configuration.isPressed ? 0.98 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

public struct SecondaryButtonStyle: ButtonStyle {
    public init() {}
    public func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.laileHeadline)
            .foregroundStyle(Theme.accent)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity)
            .background(Theme.accentSoft.opacity(configuration.isPressed ? 0.7 : 1), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

public struct SectionHeader: View {
    let title: String
    let subtitle: String?
    public init(_ title: String, subtitle: String? = nil) {
        self.title = title
        self.subtitle = subtitle
    }

    public var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(title).font(.laileTitle).foregroundStyle(Theme.text)
            if let subtitle { Text(subtitle).font(.subheadline).foregroundStyle(Theme.muted) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

public struct Pill: View {
    let text: String
    let color: Color
    let background: Color
    public init(_ text: String, color: Color = Theme.muted, background: Color = Theme.surface2) {
        self.text = text
        self.color = color
        self.background = background
    }

    public var body: some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            .background(background, in: Capsule())
    }
}

public struct RingProgress: View {
    let progress: Double
    let lineWidth: CGFloat
    let color: Color
    public init(progress: Double, lineWidth: CGFloat = 10, color: Color = Theme.accent) {
        self.progress = progress
        self.lineWidth = lineWidth
        self.color = color
    }

    public var body: some View {
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.001, min(1, progress)))
                .stroke(color, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeOut(duration: 0.35), value: progress)
        }
    }
}

public struct IntensityDots: View {
    let level: Int
    public init(_ level: Int) { self.level = level }
    public var body: some View {
        HStack(spacing: 3) {
            ForEach(1...5, id: \.self) { i in
                Circle().fill(i <= level ? Theme.flame : Theme.surface2).frame(width: 6, height: 6)
            }
        }
        .accessibilityLabel("Intensity \(level) of 5")
    }
}

/// Lightweight celebration burst — no dependencies, respects Reduce Motion.
public struct Confetti: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var animate = false
    static let colors: [Color] = [Theme.accent, Theme.reward, Theme.flame, .pink, .blue]

    public init() {}

    public var body: some View {
        GeometryReader { geo in
            ZStack {
                if !reduceMotion {
                    ForEach(0..<36, id: \.self) { i in
                        ConfettiPiece(index: i, animate: animate, center: CGPoint(x: geo.size.width / 2, y: geo.size.height / 2))
                    }
                }
            }
            .onAppear { withAnimation(.easeOut(duration: 1.2)) { animate = true } }
        }
        .allowsHitTesting(false)
    }
}

struct ConfettiPiece: View {
    let index: Int
    let animate: Bool
    let center: CGPoint

    var body: some View {
        let angle = Double(index) / 36 * 2 * .pi
        let distance = CGFloat(80 + (index * 37) % 120)
        let dx: CGFloat = animate ? CGFloat(cos(angle)) * distance : 0
        let dy: CGFloat = animate ? CGFloat(sin(angle)) * distance + 60 : 0
        let color = Confetti.colors[index % Confetti.colors.count]
        return RoundedRectangle(cornerRadius: 2)
            .fill(color)
            .frame(width: 7, height: 12)
            .rotationEffect(.degrees(animate ? Double(index * 40) : 0))
            .position(x: center.x + dx, y: center.y + dy)
            .opacity(animate ? 0 : 1)
    }
}

public extension View {
    func screenBackground() -> some View {
        background(Theme.background.ignoresSafeArea())
    }
}

public enum Haptics {
    @MainActor public static func success() { UINotificationFeedbackGenerator().notificationOccurred(.success) }
    @MainActor public static func tap() { UIImpactFeedbackGenerator(style: .light).impactOccurred() }
    @MainActor public static func rep() { UIImpactFeedbackGenerator(style: .rigid).impactOccurred(intensity: 0.7) }
    @MainActor public static func warning() { UINotificationFeedbackGenerator().notificationOccurred(.warning) }
}

public extension ExerciseSpec {
    /// SF Symbol that best depicts the exercise.
    var symbol: String {
        switch id {
        case "squat", "mini-squat", "deep-squat-hold", "wall-sit": return "figure.strengthtraining.functional"
        case "push-up", "knee-push-up", "incline-push-up", "plank": return "figure.core.training"
        case "jumping-jacks": return "figure.mixed.cardio"
        case "high-knees": return "figure.run"
        case "reverse-lunge": return "figure.step.training"
        case "sit-to-stand", "long-arc-quad": return "chair.fill"
        case "glute-bridge": return "figure.pilates"
        case "hamstring-stretch", "hip-flexor-stretch": return "figure.flexibility"
        case "chest-opener", "neck-shoulder-rolls": return "figure.mind.and.body"
        case "heel-slide", "quad-set", "straight-leg-raise", "ankle-pumps": return "figure.cooldown"
        default: return "figure.walk"
        }
    }
}

public extension ExerciseCategory {
    var label: String { rawValue.capitalized }
    var color: Color {
        switch self {
        case .stretch: return .purple
        case .mobility: return .teal
        case .strength: return Theme.accent
        case .cardio: return Theme.flame
        case .circulation: return .blue
        }
    }
}
