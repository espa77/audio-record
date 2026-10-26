import AudioRecordCore
import Foundation

// audiorecord — command-line companion of AudioRecord.app (same pipeline, no UI).
//
//   audiorecord transcribe <file> [--engine parakeet|apple] [--no-llm] [--no-vocab] [--vocab <file>] [--keep] [--out <dir>] [--mono]
//   audiorecord record [--seconds N]           record system + mic until Enter (or N seconds)
//   audiorecord bench <file>                   run both ASR engines + diarizer, print timings
//   audiorecord models                         download/prepare models now
//   audiorecord settings                       print effective settings

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(("error: " + message + "\n").data(using: .utf8)!)
    exit(1)
}

struct Args {
    var positional: [String] = []
    var flags: Set<String> = []
    var values: [String: String] = [:]
    init(_ argv: [String]) {
        var i = 0
        while i < argv.count {
            let a = argv[i]
            if a.hasPrefix("--") {
                let key = String(a.dropFirst(2))
                if ["engine", "out", "seconds", "vocab"].contains(key), i + 1 < argv.count { values[key] = argv[i + 1]; i += 1 }
                else { flags.insert(key) }
            } else { positional.append(a) }
            i += 1
        }
    }
}

func makeEngine(_ kind: ASREngineKind, vocabulary: Vocabulary) -> ASREngine {
    do { return try Engines.make(kind, vocabulary: vocabulary) } catch { fail("\(error)") }
}

func engineKind(_ s: String?) -> ASREngineKind? {
    switch s {
    case nil: return nil
    case "parakeet", "ultra": return .parakeetUltra
    case "apple": return .appleSpeech
    default: fail("unknown engine \(s!)")
    }
}

func printProgress(_ p: PipelineProgress) {
    print(String(format: "[%3.0f%%] %@", p.fraction * 100, p.stage))
}

let args = Args(Array(CommandLine.arguments.dropFirst()))
var settings = Settings.load()
if let k = engineKind(args.values["engine"]) { settings.asrEngine = k }
if args.flags.contains("keep") { settings.keepLosslessTracks = true }
if args.flags.contains("no-vocab") { settings.vocabularyEnabled = false }
let vocabulary: Vocabulary = {
    guard let path = args.values["vocab"] else { return Engines.vocabulary(for: settings) }
    do { return try Vocabulary.load(url: URL(fileURLWithPath: path)) } catch { fail("vocabulary: \(error)") }
}()

let semaphore = DispatchSemaphore(value: 0)
var exitCode: Int32 = 0

func runAsync(_ body: @escaping () async throws -> Void) {
    Task {
        do { try await body() } catch {
            FileHandle.standardError.write("error: \(error)\n".data(using: .utf8)!)
            exitCode = 1
        }
        semaphore.signal()
    }
    semaphore.wait()
    exit(exitCode)
}

switch args.positional.first {
case "transcribe":
    guard args.positional.count >= 2 else { fail("usage: audiorecord transcribe <file>") }
    let url = URL(fileURLWithPath: args.positional[1]).standardizedFileURL
    runAsync {
        var input = try TranscriptionInput.forFile(url, settings: settings)
        if args.flags.contains("mono") { input.layout = .monoEverything }
        var llm: LLMClient? = nil
        if !args.flags.contains("no-llm") {
            llm = await Engines.llmClient(for: settings)
            if llm == nil { print("note: LLM endpoint unreachable or disabled; names via pattern matching only") }
        }
        let job = TranscriptionJob(settings: settings, engine: makeEngine(settings.asrEngine, vocabulary: vocabulary), llm: llm)
        if let out = args.values["out"] { job.outputRoot = URL(fileURLWithPath: out, isDirectory: true) }
        let t0 = Date()
        let result = try await job.run(input, progress: printProgress)
        print("\nwrote \(result.markdownURL.path)")
        print("audio \(result.audioURL.path)")
        let stages = result.seconds.sorted { $0.key < $1.key }.map { String(format: "%@ %.1fs", $0.key, $0.value) }
        print(String(format: "total %.1fs  stages: ", Date().timeIntervalSince(t0)) + stages.joined(separator: ", "))
        print("speakers: " + result.identities.map { "\($0.label)=\($0.name)" }.joined(separator: ", "))
    }

case "bench":
    guard args.positional.count >= 2 else { fail("usage: audiorecord bench <file>") }
    let url = URL(fileURLWithPath: args.positional[1]).standardizedFileURL
    runAsync {
        let samples = try AudioLoader.loadMono16k(url: url)
        let dur = Double(samples.count) / 16_000
        print(String(format: "audio: %.1fs, rms %.1f dBFS", dur, AudioLoader.rmsDB(samples)))
        var engines: [ASREngine] = [ParakeetASR(version: .ultra, vocabulary: vocabulary)]
        if #available(macOS 26, *) { engines.append(AppleSpeechASR(vocabulary: vocabulary)) }
        for e in engines {
            do {
                let t0 = Date()
                try await e.prepare { print("  \($0)") }
                let tPrep = Date().timeIntervalSince(t0)
                let t1 = Date()
                let words = try await e.transcribe(samples16k: samples)
                let tRun = Date().timeIntervalSince(t1)
                let text = words.map(\.text).joined(separator: " ")
                print(String(format: "\n== %@\n   prepare %.1fs, transcribe %.1fs (%.0fx realtime), %d words",
                             e.name, tPrep, tRun, dur / max(tRun, 0.001), words.count))
                print("   " + String(text.prefix(400)))
                if let note = e.vocabularyNote { print("   " + note) }
            } catch {
                print("\n== \(e.name) FAILED: \(error)")
            }
        }
        do {
            let d = OfflineDiarizer()
            let t0 = Date()
            try await d.prepare { print("  \($0)") }
            let tPrep = Date().timeIntervalSince(t0)
            let t1 = Date()
            let segs = try await d.diarize(samples16k: samples) { _ in }
            let tRun = Date().timeIntervalSince(t1)
            let speakers = Set(segs.map(\.speaker)).sorted()
            print(String(format: "\n== %@\n   prepare %.1fs, diarize %.1fs (%.0fx realtime), %d segments, speakers: %@",
                         d.name, tPrep, tRun, dur / max(tRun, 0.001), segs.count, speakers.joined(separator: " ")))
            for s in segs.prefix(14) { print(String(format: "   %@ %7.2f – %7.2f", s.speaker, s.start, s.end)) }
        } catch {
            print("\n== diarizer FAILED: \(error)")
        }
    }

case "record":
    let seconds = args.values["seconds"].flatMap(Double.init)
    runAsync {
        guard await MicCapture.requestPermission() else { fail("microphone permission denied") }
        let session = RecordingSession(settings: settings)
        try session.start()
        print("recording → \(session.workDir.path)  (output \(session.outputDeviceName), mic \(session.micDeviceName))")
        if let seconds {
            try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        } else {
            print("press Enter to stop"); _ = readLine()
        }
        let r = try session.stop()
        print("saved \(r.audioURL.path) (\(Timestamps.duration(r.duration)))" + (session.restarts > 0 ? "  capture restarted \(session.restarts)×" : ""))
        let mic = try AudioLoader.loadMono16k(url: r.micTrackURL)
        let sys = try AudioLoader.loadMono16k(url: r.sysTrackURL)
        print(String(format: "levels: mic %.1f dBFS, system %.1f dBFS", AudioLoader.rmsDB(mic), AudioLoader.rmsDB(sys)))
    }

case "models":
    runAsync {
        try await makeEngine(settings.asrEngine, vocabulary: vocabulary).prepare { print($0) }
        try await OfflineDiarizer().prepare { print($0) }
        print("models ready")
    }

case "settings":
    print("outputRoot: \(settings.outputRoot.path)")
    print("myName: \(settings.myName)")
    print("asrEngine: \(settings.asrEngine.rawValue)")
    print("llm: \(settings.llmEnabled ? settings.llmEndpoint.absoluteString : "disabled") model=\(settings.llmModel.isEmpty ? "(auto)" : settings.llmModel)")
    print("keepLosslessTracks: \(settings.keepLosslessTracks)")
    print("vocabulary: \(settings.vocabularyEnabled ? (vocabulary.sourceURL?.path ?? "not found") : "disabled") (\(vocabulary.terms.count) terms)")

default:
    print("""
    usage:
      audiorecord transcribe <file> [--engine parakeet|apple] [--no-llm] [--no-vocab] [--vocab <file>] [--keep] [--out <dir>] [--mono]
      audiorecord record [--seconds N]
      audiorecord bench <file>
      audiorecord models
      audiorecord settings
    """)
}
