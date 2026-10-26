import AppKit
import AudioRecordCore

@MainActor
final class SettingsWindowController: NSWindowController {
    private let onSave: (Settings) -> Void
    private let outputField = NSTextField()
    private let nameField = NSTextField()
    private let enginePopup = NSPopUpButton()
    private let llmEnabled = NSButton(checkboxWithTitle: "Resolve speaker names with a local LLM (OpenAI-compatible endpoint)", target: nil, action: nil)
    private let endpointField = NSTextField()
    private let modelField = NSTextField()
    private let keepTracks = NSButton(checkboxWithTitle: "Keep lossless mic/system tracks after transcription", target: nil, action: nil)
    private let vocabEnabled = NSButton(checkboxWithTitle: "Boost domain vocabulary (vocabulary.txt)", target: nil, action: nil)

    init(settings: Settings, onSave: @escaping (Settings) -> Void) {
        self.onSave = onSave
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 560, height: 350),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "AudioRecord Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        build()
        fill(settings)
    }

    required init?(coder: NSCoder) { fatalError() }

    func show(settings: Settings) {
        fill(settings)
        window?.center()
        showWindow(nil)
        window?.makeKeyAndOrderFront(nil)
    }

    private func label(_ s: String) -> NSTextField {
        let l = NSTextField(labelWithString: s)
        l.alignment = .right
        return l
    }

    private func build() {
        guard let content = window?.contentView else { return }
        for e in ASREngineKind.allCases { enginePopup.addItem(withTitle: e.label) }
        vocabEnabled.title = "Boost domain vocabulary (\(Vocabulary.bundled().terms.count) terms from vocabulary.txt)"
        let choose = NSButton(title: "Choose…", target: self, action: #selector(chooseFolder))
        let outputRow = NSStackView(views: [outputField, choose])
        outputRow.orientation = .horizontal
        outputField.setContentHuggingPriority(.defaultLow, for: .horizontal)

        let grid = NSGridView(views: [
            [label("Recordings folder"), outputRow],
            [label("My name (microphone speaker)"), nameField],
            [label("Transcription engine"), enginePopup],
            [NSGridCell.emptyContentView, llmEnabled],
            [label("LLM endpoint"), endpointField],
            [label("LLM model (blank = first available)"), modelField],
            [NSGridCell.emptyContentView, keepTracks],
            [NSGridCell.emptyContentView, vocabEnabled],
        ])
        grid.rowSpacing = 10
        grid.columnSpacing = 12
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).width = 360

        let save = NSButton(title: "Save", target: self, action: #selector(save))
        save.keyEquivalent = "\r"
        let cancel = NSButton(title: "Cancel", target: self, action: #selector(cancel))
        let buttons = NSStackView(views: [cancel, save])
        buttons.orientation = .horizontal

        let stack = NSStackView(views: [grid, buttons])
        stack.orientation = .vertical
        stack.alignment = .trailing
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 20, left: 20, bottom: 20, right: 20)
        stack.translatesAutoresizingMaskIntoConstraints = false
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
        ])
    }

    private func fill(_ s: Settings) {
        outputField.stringValue = s.outputRoot.path
        nameField.stringValue = s.myName
        enginePopup.selectItem(at: ASREngineKind.allCases.firstIndex(of: s.asrEngine) ?? 0)
        llmEnabled.state = s.llmEnabled ? .on : .off
        endpointField.stringValue = s.llmEndpoint.absoluteString
        modelField.stringValue = s.llmModel
        keepTracks.state = s.keepLosslessTracks ? .on : .off
        vocabEnabled.state = s.vocabularyEnabled ? .on : .off
    }

    @objc private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = URL(fileURLWithPath: outputField.stringValue)
        if panel.runModal() == .OK, let url = panel.url { outputField.stringValue = url.path }
    }

    @objc private func save() {
        var s = Settings.load()
        s.outputRoot = URL(fileURLWithPath: (outputField.stringValue as NSString).expandingTildeInPath, isDirectory: true)
        s.myName = nameField.stringValue.trimmingCharacters(in: .whitespaces)
        s.asrEngine = ASREngineKind.allCases[max(enginePopup.indexOfSelectedItem, 0)]
        s.llmEnabled = llmEnabled.state == .on
        if let url = URL(string: endpointField.stringValue.trimmingCharacters(in: .whitespaces)), url.scheme != nil { s.llmEndpoint = url }
        s.llmModel = modelField.stringValue.trimmingCharacters(in: .whitespaces)
        s.keepLosslessTracks = keepTracks.state == .on
        s.vocabularyEnabled = vocabEnabled.state == .on
        onSave(s)
        window?.close()
    }

    @objc private func cancel() { window?.close() }
}
