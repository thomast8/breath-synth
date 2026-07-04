import Foundation

/// Guards every client-supplied string that ends up as a path component — object storage keys
/// (`TakesController`), gold-reference filenames passed into `LiveTakeGrader` (which builds
/// `assetsDir.appendingPathComponent(reference)` with no validation of its own), and ZIP entry
/// names (`SessionExporter`). Mirrors `AssetLibrary.samples(for:)`'s existing guard in this same
/// codebase ("reject path separators / traversal so a crafted manifest can't read files outside
/// the assets directory") — same threat, same fix, applied at every new boundary that takes
/// untrusted input from the browser instead of a manifest.
enum SlugValidation {
    static func isSafe(_ value: String) -> Bool {
        guard !value.isEmpty, value.count <= 128 else { return false }
        guard !value.contains("/"), !value.contains("\\"), !value.contains("..") else { return false }
        return true
    }
}
