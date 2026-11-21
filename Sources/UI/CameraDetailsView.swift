import SwiftUI

struct CameraDetailsView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State var camera: Camera
    @State private var password = ""
    @State private var webPassword = ""
    @State private var webError: String?
    @State private var saving = false
    @State private var confirmRemove = false

    @State private var recording: RecordingSettings?

    private var needsWebPassword: Bool {
        camera.kind == .thingino && (CameraSecrets(id: camera.id).apiKey == nil || recording?.phase == .needsWebPassword)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("Name", text: $camera.name)
                }
                Section {
                    TextField("Tailscale name or address", text: Binding(
                        get: { camera.awayHost ?? "" },
                        set: { camera.awayHost = $0.isEmpty ? nil : $0 }))
                        .plainTextEntry(url: true)
                        .autocorrectionDisabled()
                        .accessibilityIdentifier("awayField")
                } header: {
                    Text("Away from Home")
                } footer: {
                    Text("Used when the home address doesn't answer. Any address your phone can reach works, including Tailscale or WireGuard.")
                }
                Section {
                    SecureField("New password", text: $password)
                } header: {
                    Text("Password")
                } footer: {
                    Text("Leave blank to keep the current one. Update it here if the camera's password changed.")
                }
                if needsWebPassword {
                    Section {
                        SecureField("Web password", text: $webPassword)
                            .accessibilityIdentifier("webPasswordField")
                    } header: {
                        Text("Camera Controls")
                    } footer: {
                        Text(webError ?? "The password for the camera's web page. It turns on day/night and pan, and CamFetti doesn't keep it.")
                            .foregroundStyle(Theme.noteColor(isError: webError != nil))
                    }
                }
                if let recording { recordingSection(recording) }
                Section("Camera") {
                    LabeledContent("Address", value: camera.host)
                    LabeledContent("Type", value: typeName)
                    if let streamer = camera.streamer { LabeledContent("Streamer", value: streamer) }
                    if camera.username.isEmpty == false { LabeledContent("User", value: camera.username) }
                }
                Section {
                    Button("Remove Camera", role: .destructive) { confirmRemove = true }
                }
            }
            .navigationTitle("Details")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") { Task { await save() } }
                        .fontWeight(.semibold)
                        .disabled(saving)
                }
            }
            .confirmationDialog("Remove \(camera.name)?", isPresented: $confirmRemove, titleVisibility: .visible) {
                Button("Remove", role: .destructive) {
                    model.remove(camera)
                    dismiss()
                }
            }
            .task {
                guard recording == nil else { return }
                let settings: RecordingSettings
                if camera.kind == .thingino {
                    settings = RecordingSettings(client: model.thinginoClient(for: camera))
                } else {
                    // Asked without a password, so finding out never counts against the sign-in limit.
                    guard let base = camera.webBase(),
                          await ReolinkClient(base: base, username: "", password: "").isReolink() else { return }
                    settings = RecordingSettings(reolink: model.reolinkClients(for: camera), cameraID: camera.id)
                }
                recording = settings
                await settings.load()
            }
        }
    }

    /// One switch. It changes the camera right away, so it isn't part of Save.
    private func recordingSection(_ recording: RecordingSettings) -> some View {
        Section {
            HStack {
                Toggle("Record to SD Card", isOn: Binding(
                    get: { recording.isOn },
                    set: { on in Task { await recording.set(on) } }))
                    .disabled(!Self.canToggle(recording.phase) || recording.busy)
                    .accessibilityIdentifier("recordToggle")
                if recording.phase == .checking || recording.busy { ProgressView().padding(.leading, Theme.Space.sm) }
            }
            if recording.isOn, !recording.modes.isEmpty {
                Picker("Record", selection: Binding(
                    get: { recording.mode },
                    set: { mode in if let mode { Task { await recording.choose(mode) } } })) {
                    ForEach(recording.modes, id: \.self) { mode in
                        Text(Self.modeName(mode, ai: recording.aiTriggers)).tag(Optional(mode))
                    }
                    if recording.mode == nil { Text("Custom").tag(ReolinkClient.RecordMode?.none) }
                }
                .disabled(recording.busy)
                .accessibilityIdentifier("recordMode")
            }
        } header: {
            Text("Recording")
        } footer: {
            let note = recording.isReolink
                ? Self.reolinkNote(recording.phase, mode: recording.mode, hasModes: !recording.modes.isEmpty,
                                   card: recording.cardBytes, ai: recording.aiTriggers)
                : Self.recordingNote(recording.phase)
            Text(note.text)
                .foregroundStyle(Theme.noteColor(isError: note.isError))
                .accessibilityIdentifier("recordNote")
        }
    }

    nonisolated static func canToggle(_ phase: RecordingSettings.Phase) -> Bool {
        switch phase {
        case .ready, .failed: true
        default: false
        }
    }

    nonisolated static func recordingNote(_ phase: RecordingSettings.Phase) -> (text: String, isError: Bool) {
        let what = "Records nonstop in short clips and deletes the oldest when the card fills. Changes the camera right away."
        switch phase {
        case .checking: return ("Checking the SD card.", false)
        case .needsWebPassword: return ("Enter the camera's web password above to control recording.", false)
        case .wrongPassword: return ("The camera didn't accept its password. Enter it again above.", true)
        case .noCard: return ("Put a microSD card in the camera to record.", false)
        case .cardTooSmall(let usable, let card):
            let usableText = usable.formatted(.byteCount(style: .file))
            if card >= ThinginoClient.smallestCardBytes * 2 {
                // A big card with a small partition, as firmware flashing leaves it.
                return ("Only \(usableText) of this \(card.formatted(.byteCount(style: .file))) card is set up. Format the card on the camera's web page (this erases it), then try again.", true)
            }
            return ("This card holds \(usableText), too little to record. Use a card of 4 GB or more.", true)
        case .ready(true, true): return ("Recording now. " + what, false)
        case .ready(true, false): return ("Set to record, but the camera isn't recording right now. Turn the switch off and on to try again.", true)
        case .ready(false, _): return (what, false)
        case .failed(let message): return (message, true)
        }
    }

    /// "People and Vehicles", from the AI triggers the camera has.
    nonisolated static func modeName(_ mode: ReolinkClient.RecordMode, ai: [String]) -> String {
        switch mode {
        case .nonstop: return "All the Time"
        case .motion: return "Any Motion"
        case .smart: return smartThings(ai, capitalized: true)
        }
    }

    nonisolated static func smartThings(_ ai: [String], capitalized: Bool) -> String {
        let names = ai.compactMap { ["AI_PEOPLE": "People", "AI_VEHICLE": "Vehicles", "AI_DOG_CAT": "Animals"][$0] }
            .map { capitalized ? $0 : $0.lowercased() }
        guard let last = names.last else { return capitalized ? "People" : "people" }
        return names.count == 1 ? last : names.dropLast().joined(separator: ", ") + " and " + last
    }

    /// "32 GB", the way the card is labeled, rather than "32.01 GB".
    nonisolated static func cardSize(_ bytes: Int64) -> String {
        let gb = Double(bytes) / 1_000_000_000
        return gb >= 1 ? "\(Int(gb.rounded())) GB" : bytes.formatted(.byteCount(style: .file))
    }

    nonisolated static func reolinkNote(_ phase: RecordingSettings.Phase, mode: ReolinkClient.RecordMode?, hasModes: Bool,
                                        card: Int64?, ai: [String]) -> (text: String, isError: Bool) {
        guard case .ready(let on, _) = phase else { return recordingNote(phase) }
        let cardText = card.map { "the \(cardSize($0)) card" } ?? "the card"
        guard on else { return ("Turn on to save clips to \(cardText). Changes the camera right away.", false) }
        let full = " Replaces the oldest clips when the card fills."
        guard hasModes else { return ("Records to \(cardText) when something moves." + full, false) }
        switch mode {
        case .nonstop: return ("Records to \(cardText) all the time." + full, false)
        case .motion: return ("Records to \(cardText) when anything moves." + full, false)
        case .smart: return ("Records to \(cardText) when the camera sees \(smartThings(ai, capitalized: false)), so rain and shadows don't fill it." + full, false)
        case nil: return ("Records to \(cardText) on the schedule set in Reolink's app." + full, false)
        }
    }

    private var typeName: String {
        switch camera.kind {
        case .thingino: "Thingino"
        case .onvif: "ONVIF"
        case .rtsp: "RTSP"
        }
    }

    private func save() async {
        saving = true
        defer { saving = false }
        if !webPassword.isEmpty, let base = camera.webBase() {
            do {
                let key = try await ThinginoClient(base: base).mintAPIKey(password: webPassword)
                CameraSecrets(id: camera.id).apiKey = key
                PlaybackModel.forgetRefusal(camera.id)
                camera.canPan = await ThinginoClient(base: base, apiKey: key).hasMotors()
            } catch ThinginoClient.Failure.wrongPassword {
                webError = "That password didn't work."
                return
            } catch {
                webError = "Couldn't reach the camera's web page."
                return
            }
        }
        if !password.isEmpty {
            CameraSecrets(id: camera.id).password = password
            PlaybackModel.forgetRefusal(camera.id)
        }
        model.store.update(camera)
        model.resetStream(camera)
        dismiss()
    }
}
