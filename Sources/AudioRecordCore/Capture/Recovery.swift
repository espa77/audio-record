import Foundation

/// Finds recordings that were interrupted before finalisation (app quit, crash) and finishes them.
public enum Recovery {
    public static func pendingTimestamps(settings: Settings) -> [String] {
        let fm = FileManager.default
        guard let dirs = try? fm.contentsOfDirectory(at: settings.inProgressDir, includingPropertiesForKeys: nil) else { return [] }
        return dirs.compactMap { dir -> String? in
            let ts = dir.lastPathComponent
            guard Timestamps.date(fromFileStamp: ts) != nil,
                  fm.fileExists(atPath: dir.appendingPathComponent("sys.caf").path),
                  fm.fileExists(atPath: dir.appendingPathComponent("mic.caf").path),
                  !fm.fileExists(atPath: settings.outputRoot.appendingPathComponent("\(ts).m4a").path),
                  !fm.fileExists(atPath: settings.outputRoot.appendingPathComponent("\(ts)_meeting").path)
            else { return nil }
            return ts
        }.sorted()
    }

    /// Mixes the lossless tracks down to `<root>/<ts>.m4a` (no clock offsets are known any more, so none are applied).
    public static func finalize(timestamp: String, settings: Settings) throws -> RecordingResult {
        let work = settings.inProgressDir.appendingPathComponent(timestamp, isDirectory: true)
        let mic = work.appendingPathComponent("mic.caf"), sys = work.appendingPathComponent("sys.caf")
        let out = settings.outputRoot.appendingPathComponent("\(timestamp).m4a")
        try FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
        try AudioMixdown.writeStereoM4A(mic: mic, micLeadIn: 0, sys: sys, sysLeadIn: 0, to: out)
        let duration = max((try? AudioLoader.durationSeconds(url: mic)) ?? 0, (try? AudioLoader.durationSeconds(url: sys)) ?? 0)
        return RecordingResult(timestamp: timestamp, startedAt: Timestamps.date(fromFileStamp: timestamp) ?? Date(),
                               duration: duration, audioURL: out, workDir: work)
    }

    /// `.m4a` files sitting directly in the output root = recorded but not yet transcribed.
    public static func untranscribedRecordings(settings: Settings) -> [URL] {
        let fm = FileManager.default
        guard let items = try? fm.contentsOfDirectory(at: settings.outputRoot, includingPropertiesForKeys: nil) else { return [] }
        return items.filter { $0.pathExtension.lowercased() == "m4a" }.sorted { $0.lastPathComponent > $1.lastPathComponent }
    }
}
