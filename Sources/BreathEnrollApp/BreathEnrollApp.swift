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
    init() {
        // TEMPORARY (Phase 4 hardware verification diagnostics): stdout is fully-buffered when piped
        // to a file/log rather than a TTY, so print() calls never surface until process exit. Force
        // line buffering so the [PHASE4]/[PHASE4-CAL] diagnostic prints appear in real time. Remove
        // with the prints.
        setvbuf(stdout, nil, _IOLBF, 0)
    }

    var body: some Scene {
        WindowGroup("Breath Enroll") {
            EnrollContentView()
        }
        .defaultSize(width: 760, height: 660)
    }
}
