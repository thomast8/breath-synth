import SwiftUI

/// A minimal macOS SwiftUI app for debugging the BLE pulse-oximeter stack: scan, connect, watch the
/// raw notification hex and the decoded SpO2/PR live. Reuses `BluetoothStack.BLECentral` via `DebugModel`.
///
/// Run for development with `swift run sensor-debug`. For stable Bluetooth permission, bundle it into a
/// proper `.app` with `scripts/make-debug-app.sh` (a real bundle gets its own TCC identity).
@main
struct SensorDebugApp: App {
    var body: some Scene {
        WindowGroup("Pulse-Ox Debug") {
            ContentView()
        }
        .defaultSize(width: 900, height: 620)
    }
}
