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

    private var needsWebPassword: Bool {
        camera.kind == .thingino && CameraSecrets(id: camera.id).apiKey == nil
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
                            .foregroundStyle(webError == nil ? Color.secondary : Color.red)
                    }
                }
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
                camera.canPan = await ThinginoClient(base: base, apiKey: key).hasMotors()
            } catch ThinginoClient.Failure.wrongPassword {
                webError = "That password didn't work."
                return
            } catch {
                webError = "Couldn't reach the camera's web page."
                return
            }
        }
        if !password.isEmpty { CameraSecrets(id: camera.id).password = password }
        model.store.update(camera)
        model.resetStream(camera)
        dismiss()
    }
}
