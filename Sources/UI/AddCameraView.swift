import SwiftUI

/// Adding a camera ends with live video in the sheet, so what you add is proven to work.
struct AddCameraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let finder: CameraFinder

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var picked: FoundCamera?
    @State private var testing = false
    @State private var errorText: String?
    @State private var result: CameraProber.Result?
    @State private var preview: LiveStream?

    private var candidates: [FoundCamera] {
        finder.found.filter { !model.store.contains(host: $0.host) }
    }

    var body: some View {
        NavigationStack {
            Group {
                if let result {
                    previewStep(result)
                } else if let picked {
                    signInStep(picked)
                } else {
                    pickStep
                }
            }
            .navigationTitle(result != nil ? "Looks Good" : picked != nil ? "Sign In" : "Add Camera")
            .inlineNavigationTitle()
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { preview?.stop(); dismiss() }
                }
            }
        }
        .onAppear { finder.start() }
        .onDisappear { preview?.stop() }
    }

    // MARK: Step 1, pick or type

    private var pickStep: some View {
        Form {
            Section {
                ForEach(candidates) { camera in
                    Button { pick(camera) } label: {
                        HStack {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(camera.name).foregroundStyle(.primary)
                                Text(camera.host).font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Image(systemName: "chevron.right").font(.caption.weight(.semibold)).foregroundStyle(.tertiary)
                        }
                    }
                    .accessibilityIdentifier("found-\(camera.host)")
                }
                if finder.isSearching {
                    HStack(spacing: 8) {
                        ProgressView()
                        Text("Looking on your Wi-Fi").foregroundStyle(.secondary)
                    }
                } else if candidates.isEmpty {
                    Text("No new cameras found on this Wi-Fi.").foregroundStyle(.secondary)
                }
            } header: {
                Text("On Your Wi-Fi")
            }
            Section {
                TextField("Address or rtsp:// link", text: $address)
                    .plainTextEntry(url: true)
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("addressField")
                TextField("Username", text: $username)
                    .plainTextEntry()
                    .autocorrectionDisabled()
                    .accessibilityIdentifier("usernameField")
                SecureField("Password", text: $password)
                    .accessibilityIdentifier("passwordField")
                testButton {
                    run(.init(address: address, username: username, password: password))
                }
                .disabled(address.trimmingCharacters(in: .whitespaces).isEmpty || testing)
            } header: {
                Text("Add by Address")
            } footer: {
                Text(errorText ?? "Works with Thingino, ONVIF and RTSP cameras. CamFetti figures out the rest.")
                    .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
            }
        }
    }

    // MARK: Step 2, sign in to a found camera

    private func signInStep(_ camera: FoundCamera) -> some View {
        Form {
            Section {
                LabeledContent("Camera", value: camera.name)
                if !camera.isThingino {
                    TextField("Username", text: $username)
                        .plainTextEntry()
                        .autocorrectionDisabled()
                }
                SecureField(camera.isThingino ? "Web password" : "Password", text: $password)
                testButton { run(input(for: camera)) }
                    .disabled(testing)
            } footer: {
                Text(errorText ?? (camera.isThingino ? "The password you use for the camera's web page." : "The camera's own login."))
                    .foregroundStyle(errorText == nil ? Color.secondary : Color.red)
            }
            Section {
                Button("Back") { picked = nil; errorText = nil; password = "" }
            }
        }
    }

    private func testButton(perform: @escaping () -> Void) -> some View {
        Button(action: perform) {
            HStack {
                Text(testing ? "Connecting" : "Connect").fontWeight(.semibold)
                if testing { Spacer(); ProgressView() }
            }
        }
        .accessibilityIdentifier("connectButton")
    }

    // MARK: Step 3, see it, name it, add it

    private func previewStep(_ result: CameraProber.Result) -> some View {
        Form {
            Section {
                ZStack {
                    Rectangle().fill(Brand.ink)
                    if let preview {
                        VideoSurface(stream: preview, fill: false)
                        if preview.phase != .live { ProgressView().tint(.white) }
                    }
                }
                .aspectRatio(16.0 / 9.0, contentMode: .fit)
                .listRowInsets(EdgeInsets())
                .accessibilityIdentifier("previewVideo")
            }
            Section {
                TextField("Name", text: $name)
                    .accessibilityIdentifier("nameField")
            } footer: {
                if result.camera.kind == .thingino && result.apiKey == nil {
                    Text("Live video works. Add the camera's web password in Details to use day/night and pan.")
                } else if result.password == "thingino" || result.password == "root" {
                    Text("This camera still uses its default password. You can change it on the camera's web page.")
                }
            }
            Section {
                Button {
                    var camera = result.camera
                    let trimmed = name.trimmingCharacters(in: .whitespaces)
                    if !trimmed.isEmpty { camera.name = trimmed }
                    model.store.add(camera, password: result.password, apiKey: result.apiKey)
                    preview?.stop()
                    dismiss()
                } label: {
                    Text("Add Camera").fontWeight(.semibold)
                }
                .accessibilityIdentifier("saveCameraButton")
            }
        }
    }

    // MARK: Logic

    private func pick(_ camera: FoundCamera) {
        picked = camera
        errorText = nil
        username = camera.brand == "Reolink" || camera.brand == "Hikvision" || camera.brand == "Dahua" || camera.brand == "Amcrest" ? "admin" : ""
        password = ""
        // Fresh Thingino cameras use root / root. One quiet try saves typing.
        if camera.isThingino {
            password = "root"
            var attempt = input(for: camera)
            attempt.fallbackToDefaultStream = true
            run(attempt, quiet: true)
        }
    }

    private func input(for camera: FoundCamera) -> CameraProber.Input {
        .init(address: camera.host, username: username, password: password, isThingino: camera.isThingino,
              httpPort: camera.httpPort, streamer: camera.streamer, name: camera.name)
    }

    private func run(_ input: CameraProber.Input, quiet: Bool = false) {
        testing = true
        errorText = nil
        Task {
            defer { testing = false }
            do {
                let found = try await CameraProber().probe(input)
                name = found.camera.name
                let stream = LiveStream(urls: [found.camera.gridURL], username: found.camera.username, password: found.password)
                preview = stream
                stream.start()
                result = found
            } catch let failure as CameraProber.Failure {
                if quiet { password = "" } else { errorText = Self.words(for: failure) }
            } catch {
                errorText = Self.words(for: .unreachable)
            }
        }
    }

    static func words(for failure: CameraProber.Failure) -> String {
        switch failure {
        case .wrongPassword: "That username or password didn't work."
        case .unreachable: "Couldn't reach that camera. Check the address and that you're on the same network."
        case .noStream: "Found the device, but no video stream. Try pasting its full rtsp:// link."
        case .invalidAddress: "That doesn't look like an address."
        }
    }
}
