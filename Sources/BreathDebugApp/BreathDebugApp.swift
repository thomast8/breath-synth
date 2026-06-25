import SwiftUI

/// A macOS SwiftUI app for exercising the breath engine end to end: pick a style + parameters, render
/// any of the engine's four paths (single / counted / cycle / sequence), see the exact rendered
/// waveform and stats, and play / loop / save it. Reuses `BreathEngine` through `DebugModel`.
///
/// Run for development with `swift run breath-debug` from the package root (it reads `Assets/breaths`).
/// For a proper Dock app that bundles the palette, build with `scripts/make-debug-app.sh`.
@main
struct BreathDebugApp: App {
    var body: some Scene {
        WindowGroup("Breath Debug") {
            ContentView()
        }
        .defaultSize(width: 1040, height: 720)
    }
}
