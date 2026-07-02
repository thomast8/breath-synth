import XCTest
@testable import BreathEngine

final class FragmentBankSchemaTests: XCTestCase {
    // MARK: - Manifest v2

    func testManifestCurrentVersionIsTwo() {
        XCTAssertEqual(BreathManifest.currentVersion, 2)
        XCTAssertEqual(BreathManifest().version, 2)
    }

    func testV2ManifestWithFragmentBankRoundTrips() throws {
        var palette = RolePalette()
        palette.oneShot = [BreathAsset(file: "rv_1.aifc", durationSec: 8, sampleRate: 44_100, channels: 1)]
        palette.fragmentBank = "rv_exhale.frags.json"
        var style = StyleManifest()
        style.exhale = palette
        var manifest = BreathManifest()
        manifest.styles["rv"] = style

        let data = try JSONEncoder().encode(manifest)
        let decoded = try JSONDecoder().decode(BreathManifest.self, from: data)
        XCTAssertEqual(decoded, manifest)
        XCTAssertEqual(decoded.palette(style: "rv", type: .exhale)?.fragmentBank, "rv_exhale.frags.json")
    }

    func testV1ManifestWithoutFragmentBankStillDecodes() throws {
        // A pre-bank v1 manifest (no fragmentBank/render/noiseProfile keys) must still load; the
        // new optional field decodes to nil.
        let json = """
        {"version":1,"styles":{"calm":{"inhale":{"start":[],"loop":[{"file":"calm.aifc","durationSec":7.3,"sampleRate":48000,"channels":1}],"end":[],"oneShot":[]},"exhale":{"start":[],"loop":[],"end":[],"oneShot":[]}}}}
        """
        let manifest = try JSONDecoder().decode(BreathManifest.self, from: Data(json.utf8))
        XCTAssertEqual(manifest.version, 1)
        XCTAssertNil(manifest.palette(style: "calm", type: .inhale)?.fragmentBank)
        XCTAssertEqual(manifest.palette(style: "calm", type: .inhale)?.loop.first?.file, "calm.aifc")
    }

    func testLoadAcceptsV1AndV2RejectsFuture() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        func writeManifest(version: Int) throws -> URL {
            let url = dir.appendingPathComponent("m\(version).json")
            try Data("{\"version\":\(version),\"styles\":{}}".utf8).write(to: url)
            return url
        }
        XCTAssertEqual(try BreathManifest.load(from: writeManifest(version: 1)).version, 1)
        XCTAssertEqual(try BreathManifest.load(from: writeManifest(version: 2)).version, 2)
        XCTAssertThrowsError(try BreathManifest.load(from: writeManifest(version: 3))) { error in
            guard case BreathError.unsupportedManifestVersion = error else {
                return XCTFail("expected unsupportedManifestVersion, got \(error)")
            }
        }
    }

    // MARK: - FragmentBank sidecar

    func testFragmentBankRoundTrips() throws {
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
        XCTAssertEqual(decoded, bank)
    }

    func testAcceptedFragmentsAreFilteredAndStablyOrdered() {
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
        XCTAssertEqual(grains.map { "\($0.file):\($0.startFrame)" }, ["a.aifc:10", "a.aifc:50", "b.aifc:0"])
        XCTAssertTrue(grains.allSatisfy { $0.accept && $0.kind == .grain })
    }

    func testFragmentBankLoadRoundTripsAndRejectsFutureVersion() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = dir.appendingPathComponent("bank.json")
        try FragmentBank(style: "calm", type: .inhale, preparedSig: "x").write(to: url)
        XCTAssertEqual(try FragmentBank.load(from: url).style, "calm")

        let future = dir.appendingPathComponent("future.json")
        try Data(#"{"version":99,"style":"calm","type":"inhale","sampleRate":44100,"preparedSig":"x","builtAt":"","fragments":[]}"#.utf8).write(to: future)
        XCTAssertThrowsError(try FragmentBank.load(from: future)) { error in
            guard case BreathError.unsupportedBankVersion = error else {
                return XCTFail("expected unsupportedBankVersion, got \(error)")
            }
        }
    }
}
