import SwiftUI

// Os tokens do design Kurz (os mesmos da app Avalonia): as cores existem so aqui.
enum K {
    static let scrim = Color.black.opacity(0.8)
    static let bg = Color(hex: "#101418")
    static let panel = Color(hex: "#0b0f12")
    static let surface = Color(hex: "#151b20")
    static let surface2 = Color(hex: "#1d252c")
    static let border = Color(hex: "#29333c")
    static let line = Color(hex: "#26292e")
    static let borderStrong = Color(hex: "#3a4651")
    static let accent = Color(hex: "#4fb5b3")
    static let onAccent = Color(hex: "#061819")
    static let accentText = Color(hex: "#b7eeee")
    static let accentWash = Color(hex: "#183436")
    static let text = Color(hex: "#eef2f5")
    static let textDim = Color(hex: "#a7b0bc")
    static let danger = Color(hex: "#ff6b73")
    static let errorText = Color(hex: "#e8737a")
    static let laneHead = Color(hex: "#121316")
    static let laneSub = Color(hex: "#17141f")
    static let done = Color(hex: "#34d399")
    static let mono = Font.system(size: 12, design: .monospaced)
    static let backdrop = LinearGradient(colors: [Color(hex: "#0f1418"), Color(hex: "#14262d")], startPoint: .top, endPoint: .bottom)
}

extension Color {
    init(hex: String) {
        let v = UInt64(hex.trimmingCharacters(in: CharacterSet(charactersIn: "#")), radix: 16) ?? 0
        self.init(.sRGB, red: Double(v >> 16 & 0xff) / 255, green: Double(v >> 8 & 0xff) / 255, blue: Double(v & 0xff) / 255)
    }
}

// Um botao so com icone, quadrado, como os do transporte.
struct IconButton: View {
    let system: String, label: String
    var size: CGFloat = 36
    var tint: Color = K.text
    var on = false
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Image(systemName: system).font(.system(size: size * 0.5, weight: .medium)).foregroundStyle(on ? K.accentText : tint)
                .frame(width: size, height: size).background(on ? K.accentWash : .clear, in: RoundedRectangle(cornerRadius: 8)).contentShape(Rectangle())
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
        #if os(iOS)
        .hoverEffect()
        #endif
    }
}

// "M" e "S" de cada faixa, e os passos do BPM: um quadrado pequeno com texto, aceso ou nao.
struct ChipButton: View {
    let text: String, label: String
    var on = false
    var tint: Color = K.accent
    var width: CGFloat = 34
    let action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(text).font(.system(size: 12, weight: .semibold, design: .monospaced))
                .foregroundStyle(on ? (tint == K.danger ? K.danger : K.onAccent) : K.textDim)
                .frame(width: width, height: 30)
                .background(on ? (tint == K.danger ? K.danger.opacity(0.15) : tint) : .clear, in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(on ? tint : K.border, lineWidth: 1))
        }
        .buttonStyle(.plain).accessibilityLabel(label).help(label)
    }
}

struct Pill: View {
    let text: String
    var system: String?
    var tint: Color = K.textDim
    var body: some View {
        HStack(spacing: 5) {
            if let system { Image(systemName: system).font(.system(size: 11)) }
            Text(text).font(.system(size: 11, weight: .medium)).lineLimit(1)
        }
        .foregroundStyle(tint).padding(.horizontal, 8).padding(.vertical, 3)
        .background(tint.opacity(0.12), in: Capsule()).overlay(Capsule().stroke(tint.opacity(0.35), lineWidth: 1))
    }
}

struct PrimaryButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 14, weight: .semibold)).foregroundStyle(K.onAccent).padding(.horizontal, 20).frame(minHeight: 36)
            .background(K.accent.opacity(configuration.isPressed ? 0.8 : 1), in: RoundedRectangle(cornerRadius: 8))
    }
}

struct OutlineButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.font(.system(size: 13)).foregroundStyle(K.text).padding(.horizontal, 14).frame(minHeight: 36)
            .background(K.surface.opacity(configuration.isPressed ? 0.6 : 1), in: RoundedRectangle(cornerRadius: 8)).overlay(RoundedRectangle(cornerRadius: 8).stroke(K.borderStrong, lineWidth: 1))
    }
}
