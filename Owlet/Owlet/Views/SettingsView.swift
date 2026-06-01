import SwiftUI

/// The General tab of Owlet's Settings window: hotkey recorder,
/// rewriter/vision/autocomplete model pickers, and app toggles.
/// Width is fixed at 440 so the layout doesn't reflow as the model
/// list arrives asynchronously.
struct SettingsView: View {

    @State private var hotkey: Chord = Preferences.shared.hotkey
    @State private var isRecording: Bool = false
    @State private var model: String = Preferences.shared.model
    @State private var autocompleteEnabled: Bool = Preferences.shared.autocompleteEnabled
    @State private var autocompleteModel: String = Preferences.shared.autocompleteModel
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
        }
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
