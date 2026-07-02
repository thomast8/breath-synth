import SwiftUI

/// A macOS SwiftUI app for guided breath enrollment: a person follows a reference-led script
/// (room tone first, then the high-value techniques), and their takes are written to a per-person
/// folder for the `breath-bank` builder to grade and pool. Deliberately a SEPARATE app from
/// `BreathDebugApp` so capture concerns never bleed into the engine debug tool.
///
/// Run for development with `swift run breath-enroll`. For a Dock app that bundles the reference
/// palette and carries the microphone entitlement, build with `scripts/make-enroll-app.sh`.
@main
struct BreathEnrollApp: App {
    var body: some Scene {
        WindowGroup("Breath Enroll") {
            EnrollContentView()
        }
        .defaultSize(width: 760, height: 660)
    }
}
