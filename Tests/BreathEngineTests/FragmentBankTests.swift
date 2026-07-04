import Testing
import Foundation
@testable import BreathEngine

struct FragmentBankSchemaTests {
    // MARK: - Manifest v2

    @Test func manifestCurrentVersionIsTwo() {
        #expect(BreathManifest.currentVersion == 2)
        #expect(BreathManifest().version == 2)
    }

    @Test func v2ManifestWithFragmentBankRoundTrips() throws {
        var palette = RolePalette()
        palette.oneShot = [BreathAsset(file: "rv_1.aifc", durationSec: 8, sampleRate: 44_100, channels: 1)]
        palette.fragmentBank = "rv_exhale.frags.json"
        var style = StyleManifest()
        style.exhale = palette
        var manifest = BreathManifest()
        manifest.styles["rv"] = style

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BreathManifest.self, from: data)
        #expect(decoded == manifest)
        #expect(decoded.palette(style: "rv", type: .exhale)?.fragmentBank == "rv_exhale.frags.json")
    }

    @Test func v1ManifestWithoutFragmentBankStillDecodes() throws {
        // A pre-bank v1 manifest (no fragmentBank/render/noiseProfile keys) must still load; the
        // new optional field decodes to nil.
        let json = """
        {"version":1,"styles":{"calm":{"inhale":{"start":[],"loop":[{"file":"calm.aifc","durationSec":7.3,"sampleRate":48000,"channels":1}],"end":[],"oneShot":[]},"exhale":{"start":[],"loop":[],"end":[],"oneShot":[]}}}}
        """
        let manifest = try JSONDecoder().decode(BreathManifest.self, from: Data(json.utf8))
        #expect(manifest.version == 1)
        #expect(manifest.palette(style: "calm", type: .inhale)?.fragmentBank == nil)
        #expect(manifest.palette(style: "calm", type: .inhale)?.loop.first?.file == "calm.aifc")
    }

    @Test func loadAcceptsV1AndV2RejectsFuture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func writeManifest(version: Int) throws -> URL {
            let url = dir.appendingPathComponent("m\(version).json")
            try Data("{\"version\":\(version),\"styles\":{}}".utf8).write(to: url)
            return url
        }
        #expect(try BreathManifest.load(from: writeManifest(version: 1)).version == 1)
        #expect(try BreathManifest.load(from: writeManifest(version: 2)).version == 2)
        let error = try #require(throws: BreathError.self) {
            try BreathManifest.load(from: writeManifest(version: 3))
        }
        guard case .unsupportedManifestVersion = error else {
            Issue.record("expected unsupportedManifestVersion, got \(error)")
            return
        }
    }

    // MARK: - FragmentBank sidecar

    @Test func fragmentBankRoundTrips() throws {
        let bank = FragmentBank(
            style: "packing", type: .inhale, sampleRate: 44_100, preparedSig: "abc123",
            referenceTake: "packing_gold.aifc", roomToneProfile: "room.aifc", builtAt: "2026-06-25T00:00:00Z",
            fragments: [
                Fragment(file: "packing_1.aifc", startFrame: 100, endFrame: 2_000, kind: .gulpCore,
                         accept: true, qaScore: 0.9, anomalyScore: 0.1, templateDistance: 0.2,
                         peakHeight: 0.4, gapToNext: 5_000),
                Fragment(file: "packing_1.aifc", startFrame: 2_000, endFrame: 3_800, kind: .gulpCore,
                         accept: false, reason: "clipped"),
            ]
        )
        let data = try JSONEncoder().encode(bank)
        let decoded = try JSONDecoder().decode(FragmentBank.self, from: data)
        #expect(decoded == bank)
    }

    @Test func acceptedFragmentsAreFilteredAndStablyOrdered() {
        let bank = FragmentBank(
            style: "calm", type: .inhale, preparedSig: "x",
            fragments: [
                Fragment(file: "b.aifc", startFrame: 0, endFrame: 10, kind: .grain, accept: true),
                Fragment(file: "a.aifc", startFrame: 50, endFrame: 60, kind: .grain, accept: true),
                Fragment(file: "a.aifc", startFrame: 10, endFrame: 20, kind: .grain, accept: true),
                Fragment(file: "a.aifc", startFrame: 5, endFrame: 8, kind: .grain, accept: false, reason: "anomaly"),
                Fragment(file: "a.aifc", startFrame: 0, endFrame: 10, kind: .gulpCore, accept: true),
            ]
        )
        let grains = bank.acceptedFragments(kind: .grain)
        // Rejects and other kinds excluded; remaining sorted by (file, startFrame).
        #expect(grains.map { "\($0.file):\($0.startFrame)" } == ["a.aifc:10", "a.aifc:50", "b.aifc:0"])
        #expect(grains.allSatisfy { $0.accept && $0.kind == .grain })
    }

    @Test func fragmentBankLoadRoundTripsAndRejectsFutureVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("bank.json")
        try FragmentBank(style: "calm", type: .inhale, preparedSig: "x").write(to: url)
        #expect(try FragmentBank.load(from: url).style == "calm")

        let future = dir.appendingPathComponent("future.json")
        try Data(#"{"version":99,"style":"calm","type":"inhale","sampleRate":44100,"preparedSig":"x","builtAt":"","fragments":[]}"#.utf8).write(to: future)
        let error = try #require(throws: BreathError.self) {
            try FragmentBank.load(from: future)
        }
        guard case .unsupportedBankVersion = error else {
            Issue.record("expected unsupportedBankVersion, got \(error)")
            return
        }
    }
}
