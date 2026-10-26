import AppKit
import AudioRecordCore
import UserNotifications

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, UNUserNotificationCenterDelegate {
    private enum State { case idle, recording(RecordingSession), finalizing }

    private var state: State = .idle
    private var settings = Settings.load()
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var activeJobs: [String: PipelineProgress] = [:]
    private var settingsWindow: SettingsWindowController?

    private let menu = NSMenu()
    private let recordItem = NSMenuItem(title: "Start Recording", action: #selector(toggleRecording), keyEquivalent: "r")
    private let statusLine = NSMenuItem(title: "Idle", action: nil, keyEquivalent: "")
    private let transcribeItem = NSMenuItem(title: "Transcribe Recording", action: nil, keyEquivalent: "")
    private let recoverItem = NSMenuItem(title: "Recover Interrupted Recording", action: nil, keyEquivalent: "")

    private var isBundled: Bool { Bundle.main.bundleURL.pathExtension == "app" && Bundle.main.bundleIdentifier != nil }

    // MARK: Lifecycle

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem.button?.image = NSImage(systemSymbolName: "waveform.circle", accessibilityDescription: "AudioRecord")
        statusItem.button?.imagePosition = .imageLeading
        buildMenu()
        statusItem.menu = menu
        if isBundled {
            let center = UNUserNotificationCenter.current()
            center.delegate = self
            center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
        }
        try? FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
        updateUI()
    }

    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        if case .recording = state {
            let alert = NSAlert()
            alert.messageText = "A recording is in progress"
            alert.informativeText = "Stop and save it before quitting?"
            alert.addButton(withTitle: "Stop & Save")
            alert.addButton(withTitle: "Cancel")
            if alert.runModal() == .alertFirstButtonReturn { stopRecording(thenQuit: true); return .terminateLater }
            return .terminateCancel
        }
        if !activeJobs.isEmpty {
            let alert = NSAlert()
            alert.messageText = "Transcription in progress"
            alert.informativeText = "Quitting now abandons it (the recording stays on disk). Quit anyway?"
            alert.addButton(withTitle: "Quit")
            alert.addButton(withTitle: "Cancel")
            return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
        }
        return .terminateNow
    }

    // MARK: Menu

    private func buildMenu() {
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        recordItem.target = self
        menu.addItem(statusLine)
        menu.addItem(.separator())
        menu.addItem(recordItem)
        transcribeItem.submenu = NSMenu()
        menu.addItem(transcribeItem)
        recoverItem.submenu = NSMenu()
        menu.addItem(recoverItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Open Recordings Folder", action: #selector(openFolder), keyEquivalent: "o").target = self
        menu.addItem(withTitle: "Settings…", action: #selector(openSettings), keyEquivalent: ",").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit AudioRecord", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.delegate = self
    }

    private func refreshSubmenus() {
        let tMenu = transcribeItem.submenu!
        tMenu.removeAllItems()
        let pending = Recovery.untranscribedRecordings(settings: settings)
        for url in pending.prefix(20) {
            let item = NSMenuItem(title: url.deletingPathExtension().lastPathComponent, action: #selector(transcribeFile(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = url
            item.isEnabled = activeJobs[url.deletingPathExtension().lastPathComponent] == nil
            tMenu.addItem(item)
        }
        transcribeItem.isHidden = pending.isEmpty

        let rMenu = recoverItem.submenu!
        rMenu.removeAllItems()
        let interrupted = Recovery.pendingTimestamps(settings: settings)
        for ts in interrupted {
            let item = NSMenuItem(title: ts, action: #selector(recover(_:)), keyEquivalent: "")
            item.target = self
            item.representedObject = ts
            rMenu.addItem(item)
        }
        recoverItem.isHidden = interrupted.isEmpty
    }

    private func updateUI() {
        var title = ""
        switch state {
        case .idle:
            recordItem.title = "Start Recording"
            recordItem.isEnabled = true
            statusLine.title = activeJobs.isEmpty ? "Idle" : "Transcribing…"
        case .recording(let session):
            recordItem.title = "Stop Recording"
            recordItem.isEnabled = true
            title = "● " + Timestamps.duration(session.elapsed)
            statusLine.title = "Recording — \(session.outputDeviceName.isEmpty ? "system audio" : session.outputDeviceName) + \(session.micDeviceName.isEmpty ? "microphone" : session.micDeviceName)"
                + (session.restarts > 0 ? " · capture restarted \(session.restarts)×" : "")
        case .finalizing:
            recordItem.title = "Saving…"
            recordItem.isEnabled = false
            statusLine.title = "Saving recording…"
        }
        if let (name, p) = activeJobs.min(by: { $0.key < $1.key }) {
            statusLine.title = "\(name): \(p.stage) (\(Int(p.fraction * 100))%)"
            if title.isEmpty { title = "⋯ \(Int(p.fraction * 100))%" }
        }
        statusItem.button?.title = title.isEmpty ? "" : " " + title
        statusItem.button?.image = NSImage(systemSymbolName: {
            if case .recording = state { return "record.circle.fill" }
            return activeJobs.isEmpty ? "waveform.circle" : "waveform.circle.fill"
        }(), accessibilityDescription: "AudioRecord")
        statusItem.button?.contentTintColor = { if case .recording = state { return .systemRed }; return nil }()
    }

    // MARK: Recording

    @objc private func toggleRecording() {
        switch state {
        case .idle: startRecording()
        case .recording: stopRecording(thenQuit: false)
        case .finalizing: break
        }
    }

    private func startRecording() {
        Task { @MainActor in
            guard await MicCapture.requestPermission() else {
                showError("Microphone access is required", detail: "Allow AudioRecord under System Settings → Privacy & Security → Microphone, then try again.")
                return
            }
            let session = RecordingSession(settings: settings)
            do {
                try session.start()
            } catch {
                showError("Could not start recording", detail: error.localizedDescription + "\n\nSystem audio needs permission under System Settings → Privacy & Security → Screen & System Audio Recording (System Audio Recording Only).")
                return
            }
            state = .recording(session)
            timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
                Task { @MainActor in self?.updateUI() }
            }
            updateUI()
        }
    }

    private func stopRecording(thenQuit: Bool) {
        guard case .recording(let session) = state else { return }
        timer?.invalidate(); timer = nil
        state = .finalizing
        updateUI()
        Task.detached { [self] in
            let outcome = Result { try session.stop() }
            await MainActor.run {
                self.state = .idle
                self.updateUI()
                switch outcome {
                case .success(let result):
                    if thenQuit { NSApp.reply(toApplicationShouldTerminate: true); return }
                    self.askToTranscribe(result)
                case .failure(let error):
                    self.showError("Recording could not be saved", detail: error.localizedDescription)
                    if thenQuit { NSApp.reply(toApplicationShouldTerminate: true) }
                }
            }
        }
    }

    private func askToTranscribe(_ result: RecordingResult) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Recording saved (\(Timestamps.duration(result.duration)))"
        alert.informativeText = "\(result.audioURL.lastPathComponent)\n\nTranscribe it now? The transcript is created locally and saved next to the audio in \(result.timestamp)_meeting."
        alert.addButton(withTitle: "Transcribe")
        alert.addButton(withTitle: "Later")
        if alert.runModal() == .alertFirstButtonReturn {
            transcribe(TranscriptionInput.forRecording(result), name: result.timestamp)
        }
        refreshSubmenus()
    }

    // MARK: Transcription

    @objc private func transcribeFile(_ sender: NSMenuItem) {
        guard let url = sender.representedObject as? URL else { return }
        do {
            let input = try TranscriptionInput.forFile(url, settings: settings)
            transcribe(input, name: input.timestamp)
        } catch {
            showError("Cannot transcribe \(url.lastPathComponent)", detail: error.localizedDescription)
        }
    }

    @objc private func recover(_ sender: NSMenuItem) {
        guard let ts = sender.representedObject as? String else { return }
        do {
            let result = try Recovery.finalize(timestamp: ts, settings: settings)
            askToTranscribe(result)
        } catch {
            showError("Recovery failed", detail: error.localizedDescription)
        }
    }

    private func transcribe(_ input: TranscriptionInput, name: String) {
        guard activeJobs[name] == nil else { return }
        activeJobs[name] = PipelineProgress(stage: "Starting", fraction: 0)
        updateUI()
        let settings = self.settings
        Task.detached { [self] in
            do {
                let engine = try Engines.make(settings.asrEngine, vocabulary: Engines.vocabulary(for: settings))
                let llm = await Engines.llmClient(for: settings)
                let job = TranscriptionJob(settings: settings, engine: engine, llm: llm)
                job.outputRoot = settings.outputRoot
                let output = try await job.run(input) { p in
                    Task { @MainActor in self.activeJobs[name] = p; self.updateUI() }
                }
                await MainActor.run { self.finished(name: name, output: output) }
            } catch {
                await MainActor.run {
                    self.activeJobs[name] = nil
                    self.updateUI()
                    self.showError("Transcription failed for \(name)", detail: error.localizedDescription)
                }
            }
        }
    }

    private func finished(name: String, output: TranscriptionOutput) {
        activeJobs[name] = nil
        updateUI()
        refreshSubmenus()
        let speakers = output.identities.map(\.name).joined(separator: ", ")
        notify(title: "Transcript ready: \(name)", body: "Speakers: \(speakers)", folder: output.folderURL)
    }

    private func notify(title: String, body: String, folder: URL) {
        guard isBundled else { NSWorkspace.shared.activateFileViewerSelecting([folder]); return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.userInfo = ["folder": folder.path]
        let request = UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request)
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, didReceive response: UNNotificationResponse) async {
        if let path = response.notification.request.content.userInfo["folder"] as? String {
            await MainActor.run { NSWorkspace.shared.open(URL(fileURLWithPath: path)) }
        }
    }

    nonisolated func userNotificationCenter(_ center: UNUserNotificationCenter, willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    // MARK: Misc actions

    @objc private func openFolder() {
        try? FileManager.default.createDirectory(at: settings.outputRoot, withIntermediateDirectories: true)
        NSWorkspace.shared.open(settings.outputRoot)
    }

    @objc private func openSettings() {
        if settingsWindow == nil {
            settingsWindow = SettingsWindowController(settings: settings) { [weak self] updated in
                self?.settings = updated
                updated.save()
                self?.refreshSubmenus()
                self?.updateUI()
            }
        }
        NSApp.activate(ignoringOtherApps: true)
        settingsWindow?.show(settings: settings)
    }

    private func showError(_ message: String, detail: String) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.alertStyle = .warning
        alert.messageText = message
        alert.informativeText = detail
        alert.runModal()
    }
}

extension AppDelegate: NSMenuDelegate {
    func menuNeedsUpdate(_ menu: NSMenu) {
        refreshSubmenus()
        updateUI()
    }
}
