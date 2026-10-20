import SwiftUI

// Render-only: the scene the approved island mockups were drawn on (design/mockups/Sources/VerseMockups/Wallpapers.swift,
// copied so `--render-screens` shows the island on the same backdrop at the same size and the renders can be compared
// side by side). Not used by the app.


/// Test wallpapers, drawn (no image files): a daylight dune scene and a night one. Large soft shapes with real
/// contrast edges, so the glass has something to bend and frost.
enum MockWallpaper: String, CaseIterable {
    case light, dark

    var scheme: ColorScheme { self == .light ? .light : .dark }
}

struct MockWallpaperView: View {
    var kind: MockWallpaper

    var body: some View {
        GeometryReader { g in
            let w = g.size.width, h = g.size.height
            ZStack {
                if kind == .light {
                    LinearGradient(colors: [Color(mockHex: 0xA9CBE6), Color(mockHex: 0xDCE7EE), Color(mockHex: 0xF3E3CC)],
                                   startPoint: .top, endPoint: .bottom)
                    Circle().fill(Color(mockHex: 0xFFF6E4)).frame(width: w * 0.16).position(x: w * 0.78, y: h * 0.22).blur(radius: 2)
                    MockDune(peak: 0.42, shift: 0.0).fill(Color(mockHex: 0xE8C9A4)).frame(height: h * 0.62).offset(y: h * 0.19)
                    MockDune(peak: 0.66, shift: 0.3).fill(Color(mockHex: 0xD9A577)).frame(height: h * 0.48).offset(y: h * 0.26)
                    MockDune(peak: 0.25, shift: 0.55).fill(Color(mockHex: 0xC27F53)).frame(height: h * 0.34).offset(y: h * 0.33)
                    MockDune(peak: 0.80, shift: 0.15).fill(Color(mockHex: 0x9C5A3A)).frame(height: h * 0.18).offset(y: h * 0.41)
                } else {
                    LinearGradient(colors: [Color(mockHex: 0x070B14), Color(mockHex: 0x121C2C), Color(mockHex: 0x1F2B3B)],
                                   startPoint: .top, endPoint: .bottom)
                    ForEach(0..<40, id: \.self) { i in
                        Circle().fill(Color.white.opacity(0.25 + Double(i % 4) * 0.15))
                            .frame(width: CGFloat(1 + i % 3), height: CGFloat(1 + i % 3))
                            .position(x: w * CGFloat((i * 37 % 100)) / 100, y: h * CGFloat((i * 53 % 45)) / 100)
                    }
                    if h > 600 {   // the moon sits beside the home window; the island scenes are too short for it
                        Circle().fill(Color(mockHex: 0xE9E4D6)).frame(width: w * 0.07).position(x: w * 0.965, y: h * 0.09)
                    }
                    MockDune(peak: 0.42, shift: 0.0).fill(Color(mockHex: 0x2A3A50)).frame(height: h * 0.62).offset(y: h * 0.19)
                    MockDune(peak: 0.66, shift: 0.3).fill(Color(mockHex: 0x34485F)).frame(height: h * 0.48).offset(y: h * 0.26)
                    MockDune(peak: 0.25, shift: 0.55).fill(Color(mockHex: 0x1B2738)).frame(height: h * 0.34).offset(y: h * 0.33)
                    MockDune(peak: 0.80, shift: 0.15).fill(Color(mockHex: 0x111A27)).frame(height: h * 0.18).offset(y: h * 0.41)
                }
            }
        }
    }
}

struct MockDune: Shape {
    var peak: CGFloat
    var shift: CGFloat
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX, y: r.maxY))
        p.addLine(to: CGPoint(x: r.minX, y: r.minY + r.height * (0.55 + shift * 0.3)))
        p.addCurve(to: CGPoint(x: r.minX + r.width * peak, y: r.minY),
                   control1: CGPoint(x: r.minX + r.width * peak * 0.4, y: r.minY + r.height * 0.5),
                   control2: CGPoint(x: r.minX + r.width * peak * 0.7, y: r.minY))
        p.addCurve(to: CGPoint(x: r.maxX, y: r.minY + r.height * (0.35 + shift * 0.4)),
                   control1: CGPoint(x: r.minX + r.width * (peak + (1 - peak) * 0.3), y: r.minY),
                   control2: CGPoint(x: r.minX + r.width * (peak + (1 - peak) * 0.6), y: r.minY + r.height * 0.3))
        p.addLine(to: CGPoint(x: r.maxX, y: r.maxY))
        p.closeSubpath()
        return p
    }
}

extension Color {
    init(mockHex: UInt32) {
        self.init(red: Double((mockHex >> 16) & 0xFF) / 255, green: Double((mockHex >> 8) & 0xFF) / 255, blue: Double(mockHex & 0xFF) / 255)
    }
}

/// The macOS menu bar over the wallpaper, with the frontmost app's menus.
struct MockMenuBar: View {
    var kind: MockWallpaper
    var body: some View {
        let ink: Color = kind == .light ? .black.opacity(0.85) : .white.opacity(0.92)
        HStack(spacing: 18) {
            Image(systemName: "apple.logo").font(.system(size: 14, weight: .medium))
            Text(verbatim: "Comet").font(.system(size: 13, weight: .bold))
            ForEach(["File", "Edit", "View", "History", "Window"], id: \.self) { Text($0).font(.system(size: 13)) }
            Spacer()
            Image(systemName: "battery.75percent")
            Image(systemName: "wifi")
            Image(systemName: "magnifyingglass")
            Text(verbatim: "Thu 16 Oct  14:29").font(.system(size: 13))
        }
        .foregroundStyle(ink)
        .padding(.horizontal, 18)
        .frame(height: 32)
        .background(kind == .light ? Color.white.opacity(0.25) : Color.black.opacity(0.18))
    }
}

/// What sits under the island during a call: a document page (light) or a video call (dark), inside an app window.
struct MockAppUnderIsland: View {
    var kind: MockWallpaper
    var body: some View {
        ZStack(alignment: .topLeading) {
            if kind == .light { DocPage() } else { CallFrame() }
        }
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
    }
}

private struct DocPage: View {
    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.white
            VStack(alignment: .leading, spacing: 10) {
                Spacer().frame(height: 34)
                Text(verbatim: "Q3 delivery review").font(.system(size: 30, weight: .bold)).foregroundStyle(.black)
                Text(verbatim: "Halden Logistics · Platform team").font(.system(size: 14)).foregroundStyle(.gray)
                ForEach(0..<16, id: \.self) { i in
                    Text(String(repeating: "Route planning latency and ETA drift across the Milan depots. ", count: 3))
                        .font(.system(size: 15)).foregroundStyle(.black.opacity(i % 5 == 0 ? 0.95 : 0.78)).lineLimit(1)
                }
            }
            .padding(.horizontal, 48)
        }
    }
}

private struct CallFrame: View {
    var body: some View {
        ZStack {
            Color(mockHex: 0x111318)
            HStack(spacing: 8) {
                tile(bg: [Color(mockHex: 0x8C6B4C), Color(mockHex: 0x2E2420)], shirt: Color(mockHex: 0x1F4C9E), skin: Color(mockHex: 0xDBAB87), name: "Ingrid Solberg")
                tile(bg: [Color(mockHex: 0xF2EDE0), Color(mockHex: 0x525966)], shirt: Color(mockHex: 0xBF382E), skin: Color(mockHex: 0x9E7052), name: "Mara Castellan")
            }
            .padding(8)
        }
    }

    private func tile(bg: [Color], shirt: Color, skin: Color, name: String) -> some View {
        ZStack(alignment: .bottomLeading) {
            LinearGradient(colors: bg, startPoint: .topLeading, endPoint: .bottomTrailing)
            Rectangle().fill(Color.white.opacity(0.85)).frame(width: 140, height: 200).offset(x: 300, y: -220).blur(radius: 6)
            ForEach(0..<5, id: \.self) { i in
                Rectangle().fill([Color.orange, .yellow, .green, .pink, .cyan][i].opacity(0.75))
                    .frame(width: 22, height: 70 + CGFloat(i * 9)).offset(x: 40 + CGFloat(i) * 26, y: -300 + CGFloat(i * 4))
            }
            VStack(spacing: -14) {
                Circle().fill(skin).frame(width: 140, height: 160)
                RoundedRectangle(cornerRadius: 90).fill(shirt).frame(width: 310, height: 220)
            }
            .offset(x: 110, y: 70)
            Text(name).font(.system(size: 13, weight: .medium)).foregroundStyle(.white)
                .padding(.horizontal, 8).padding(.vertical, 4)
                .background(Color.black.opacity(0.45), in: RoundedRectangle(cornerRadius: 6))
                .padding(12)
        }
        .clipShape(RoundedRectangle(cornerRadius: 12))
    }
}
