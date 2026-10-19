import Foundation

/// The app ships `mrm` inside its own bundle (Contents/MacOS/mrm). On every
/// launch, make sure `~/.local/bin/mrm` points at it — no manual install step,
/// no sudo, user directory only. Never overwrites a real file the user placed.
nonisolated enum CLILinkManager {
    static func ensureLinked() {
        let manager = FileManager.default
        let embedded = (Bundle.main.bundlePath as NSString)
            .appendingPathComponent("Contents/MacOS/mrm")
        // Dev builds without the embed phase have nothing to link.
        guard manager.isExecutableFile(atPath: embedded) else { return }
        let linkDir = (NSHomeDirectory() as NSString).appendingPathComponent(".local/bin")
        try? manager.createDirectory(atPath: linkDir, withIntermediateDirectories: true)
        let link = (linkDir as NSString).appendingPathComponent("mrm")
        if let current = try? manager.destinationOfSymbolicLink(atPath: link) {
            guard current != embedded else { return }
            // Our namespace: repoint stale links at the current bundle.
            try? manager.removeItem(atPath: link)
            try? manager.createSymbolicLink(atPath: link, withDestinationPath: embedded)
        } else if !manager.fileExists(atPath: link) {
            try? manager.createSymbolicLink(atPath: link, withDestinationPath: embedded)
        }
    }
}
