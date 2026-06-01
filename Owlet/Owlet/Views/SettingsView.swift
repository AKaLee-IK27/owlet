import SwiftUI
import AppKit

/// The General tab of Owlet's Settings window: hotkey recorder,
/// rewriter/vision/autocomplete model pickers, and app toggles.
/// Width is fixed at 440 so the layout doesn't reflow as the model
/// list arrives asynchronously.
struct SettingsView: View {

    @State private var hotkey: Chord = Preferences.shared.hotkey
    @State private var isRecording: Bool = false
    @State private var model: String = Preferences.shared.model
    @State private var autocompleteEnabled: Bool = Preferences.shared.autocompleteEnabled
    @State private var autocompleteBackend: Preferences.AutocompleteBackend = Preferences.shared.autocompleteBackend
    @State private var autocompleteModel: String = Preferences.shared.autocompleteModel
    @State private var suggestionLength: Preferences.SuggestionLength = Preferences.shared.suggestionLength
    @State private var deniedApps: Set<String> = Preferences.shared.autocompleteDeniedApps
    @State private var runningApps: [(name: String, bundleID: String)] = []
    @State private var launchAtLogin: Bool = Preferences.shared.launchAtLogin

    @State private var models: [String] = []
    @State private var modelListFailed: Bool = false
    @State private var loginItemError: String? = nil
    @State private var isReverting: Bool = false

    var body: some View {
        Form {
            Section {
                LabeledContent("Hotkey") {
                    HStack(spacing: 8) {
                        HotkeyRecorderField(chord: $hotkey, isRecording: $isRecording)
                            .frame(height: 28)
                            .onChange(of: hotkey) { _, newValue in
                                Preferences.shared.hotkey = newValue
                            }
                        Button(isRecording ? "Cancel" : "Record") {
                            isRecording.toggle()
                        }
                        Button("Reset") {
                            isRecording = false
                            hotkey = .default
                            Preferences.shared.hotkey = .default
                        }
                    }
                }

                LabeledContent("Model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $model) {
                            ForEach(modelChoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .onChange(of: model) { _, newValue in
                            Preferences.shared.model = newValue
                        }
                        if modelListFailed {
                            Text("Couldn't list models — is `ollama serve` running?")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                    }
                }

                LabeledContent("Autocomplete") {
                    Toggle("Show inline suggestions", isOn: $autocompleteEnabled)
                        .onChange(of: autocompleteEnabled) { _, newValue in
                            Preferences.shared.autocompleteEnabled = newValue
                        }
                }

                LabeledContent("Suggestion engine") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $autocompleteBackend) {
                            ForEach(Preferences.AutocompleteBackend.allCases, id: \.self) { backend in
                                Text(backend.label).tag(backend)
                            }
                        }
                        .labelsHidden()
                        .disabled(!autocompleteEnabled)
                        .onChange(of: autocompleteBackend) { _, newValue in
                            Preferences.shared.autocompleteBackend = newValue
                        }
                        Text("Ollama is always available. The Owlet engine streams per-keystroke (needs the bundled helper).")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Autocomplete model") {
                    VStack(alignment: .leading, spacing: 4) {
                        Picker("", selection: $autocompleteModel) {
                            ForEach(autocompleteModelChoices, id: \.self) { name in
                                Text(name).tag(name)
                            }
                        }
                        .labelsHidden()
                        .disabled(!autocompleteEnabled)
                        .onChange(of: autocompleteModel) { _, newValue in
                            Preferences.shared.autocompleteModel = newValue
                        }
                        Text("Default: qwen2.5:1.5b. Autocomplete stays off until enabled.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }

                LabeledContent("Suggestion length") {
                    Picker("", selection: $suggestionLength) {
                        ForEach(Preferences.SuggestionLength.allCases, id: \.self) { length in
                            Text(length.label).tag(length)
                        }
                    }
                    .labelsHidden()
                    .disabled(!autocompleteEnabled)
                    .onChange(of: suggestionLength) { _, newValue in
                        Preferences.shared.suggestionLength = newValue
                    }
                }

                LabeledContent("Excluded apps") {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(excludedAppRows, id: \.bundleID) { app in
                            Toggle(isOn: denyBinding(for: app.bundleID)) {
                                Text(app.name).lineLimit(1)
                            }
                        }
                        Text("Owlet won't suggest in checked apps. Running apps appear here; toggles persist even after an app quits.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .disabled(!autocompleteEnabled)
                }

                LabeledContent("Launch at login") {
                    VStack(alignment: .leading, spacing: 4) {
                        Toggle("", isOn: $launchAtLogin)
                            .labelsHidden()
                            .onChange(of: launchAtLogin) { _, newValue in
                                if isReverting { isReverting = false; return }
                                do {
                                    try LoginItemManager.setRegistered(newValue)
                                    Preferences.shared.launchAtLogin = newValue
                                    loginItemError = nil
                                } catch {
                                    loginItemError = "\(error)"
                                    isReverting = true
                                    launchAtLogin = !newValue // triggers onChange; guard above absorbs it
                                }
                            }
                        if let loginItemError {
                            Text(loginItemError)
                                .font(.caption)
                                .foregroundStyle(.red)
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .frame(width: 440)
        .padding()
        .task {
            await loadModels()
            loadRunningApps()
        }
    }

    /// Rows shown under "Excluded apps": currently-running user apps, plus any
    /// already-excluded bundle IDs that aren't running (so they stay removable).
    private var excludedAppRows: [(name: String, bundleID: String)] {
        var rows = runningApps
        let running = Set(runningApps.map(\.bundleID))
        for id in deniedApps.subtracting(running).sorted() {
            rows.append((name: id, bundleID: id))
        }
        return rows
    }

    private func denyBinding(for bundleID: String) -> Binding<Bool> {
        Binding(
            get: { deniedApps.contains(bundleID) },
            set: { isDenied in
                if isDenied { deniedApps.insert(bundleID) } else { deniedApps.remove(bundleID) }
                Preferences.shared.autocompleteDeniedApps = deniedApps
            }
        )
    }

    /// User-facing running apps (regular activation policy), Owlet excluded,
    /// sorted by name. Snapshot at open — no live updates needed for this list.
    private func loadRunningApps() {
        let apps = NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular }
            .compactMap { app -> (name: String, bundleID: String)? in
                guard let id = app.bundleIdentifier,
                      id != Bundle.main.bundleIdentifier,
                      let name = app.localizedName else { return nil }
                return (name: name, bundleID: id)
            }
        // De-dupe by bundle ID, then sort by display name.
        var seen = Set<String>()
        runningApps = apps
            .filter { seen.insert($0.bundleID).inserted }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    /// Always include the currently saved model so the Picker has a valid
    /// selection even if `ollama list` returned nothing or failed.
    private var modelChoices: [String] {
        var set = Set(models)
        set.insert(model)
        return Array(set).sorted()
    }

    private var autocompleteModelChoices: [String] {
        var set = Set(models)
        set.insert(autocompleteModel)
        return Array(set).sorted()
    }

    private func loadModels() async {
        let result = await OllamaModelLister.list()
        await MainActor.run {
            if result.isEmpty {
                modelListFailed = true
                models = [model]
            } else {
                modelListFailed = false
                models = result
            }
        }
    }
}
