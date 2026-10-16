import AppKit
import SwiftUI

// verse-mockups OUT_DIR [filter ...]: renders every island state and home page over the light and dark wallpaper.
// A filter keeps only renders whose name contains it.
let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let args = Array(CommandLine.arguments.dropFirst())
let out = URL(fileURLWithPath: args.first ?? "out")
let filters = Array(args.dropFirst())

func wanted(_ name: String) -> Bool { filters.isEmpty || filters.contains { name.contains($0) } }

Task { @MainActor in
    do {
        try FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
        for wp in Wallpaper.allCases {
            for state in IslandState.allCases {
                let name = "\(state.rawValue)-\(wp.rawValue)"
                guard wanted(name) else { continue }
                try await Capture.png(IslandScene(state: state, wallpaper: wp), size: IslandScene.size,
                                      appearance: wp == .light ? .aqua : .darkAqua, to: out.appendingPathComponent(name + ".png"))
                print(name)
            }
            for page in HomePage.allCases {
                for variant in HomeVariant.allCases where variant.applies(to: page) {
                    let name = "home-\(page.rawValue)\(variant.suffix)-\(wp.rawValue)"
                    guard wanted(name) else { continue }
                    try await Capture.png(HomeScene(page: page, wallpaper: wp, variant: variant), size: HomeScene.size,
                                          appearance: wp == .light ? .aqua : .darkAqua, to: out.appendingPathComponent(name + ".png"))
                    print(name)
                }
            }
        }
    } catch { print("error: \(error)") }
    exit(0)
}
app.run()
