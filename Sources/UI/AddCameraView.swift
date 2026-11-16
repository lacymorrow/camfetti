import SwiftUI

/// Adding a camera ends with live video in the sheet, so what you add is proven to work.
struct AddCameraView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let finder: CameraFinder
    var start: AddStart = .pick

    @State private var address = ""
    @State private var username = ""
    @State private var password = ""
    @State private var name = ""
    @State private var picked: FoundCamera?
    @State private var testing = false
    @State private var errorText: String?
    @State private var result: CameraProber.Result?
    @State private var preview: LiveStream?
    @State private var showsAddress = false

    private var candidates: [FoundCamera] {
        finder.found.filter { !model.store.contains(host: $0.host) }
    }

    /// Cameras still to add come first; ones already in the app follow, checked.
    private var listed: [FoundCamera] {
        candidates + finder.found.filter { model.store.contains(host: $0.host) }
    }

    /// The typing form opens on its own when there's nothing to tap instead.
    private var addressOpen: Bool {
        showsAddress || finder.isBlocked || (candidates.isEmpty && !finder.isSearching)
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
        .onAppear {
            finder.start()
            switch start {
            case .pick: break
            case .address: showsAddress = true
            case .camera(let camera): pick(camera)
            }
        }
        .onDisappear { preview?.stop() }
    }

    // MARK: Step 1, pick or type

    private var pickStep: some View {
        Form {
            if finder.isBlocked {
                Section { LocalNetworkNote() }
            } else {
                Section {
                    ForEach(listed) { camera in
                        FoundCameraRow(camera: camera, others: finder.found,
                                       addedAs: model.store.camera(host: camera.host)?.name) { pick(camera) }
                    }
                    if finder.isSearching {
                        HStack(spacing: Theme.Space.sm) {
                            ProgressView()
                            Text("Looking on your Wi-Fi").foregroundStyle(Theme.secondaryText)
                        }
                    } else if finder.found.isEmpty {
                        Text("No cameras found on this Wi-Fi.").foregroundStyle(Theme.secondaryText)
                    }
                } header: {
                    Text("On Your Wi-Fi")
                } footer: {
                    if !finder.isSearching {
                        HStack {
                            #if !os(tvOS)
                            FindHelpLink()
                            #endif
                            Spacer()
                            Button("Search Again") { finder.searchAgain() }
                                .font(Theme.footnoteFont)
                                .accessibilityIdentifier("searchAgainButton")
                        }
                    }
                }
            }
            if addressOpen {
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
                        .foregroundStyle(Theme.noteColor(isError: errorText != nil))
                }
            } else {
                Section {
                    Button("Add by Address") { showsAddress = true }
                        .accessibilityIdentifier("showAddressButton")
                }
            }
        }
    }

    // MARK: Step 2, sign in to a found camera

    private func signInStep(_ camera: FoundCamera) -> some View {
        Form {
            Section {
                LabeledContent("Camera") {
                    VStack(alignment: .trailing, spacing: Theme.Space.xxs) {
                        Text(camera.title)
                        Text(camera.host).font(Theme.captionFont).foregroundStyle(Theme.secondaryText)
                    }
                }
                if !camera.isThingino {
                    TextField("Username", text: $username)
                        .plainTextEntry()
                        .autocorrectionDisabled()
                }
                SecureField(camera.isThingino ? "Web password" : "Password", text: $password)
                testButton { run(input(for: camera)) }
                    .disabled(testing)
            } footer: {
                Text(errorText ?? Self.loginHint(for: camera))
                    .foregroundStyle(Theme.noteColor(isError: errorText != nil))
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
                    Rectangle().fill(Theme.tileBackground)
                    if let preview {
                        VideoSurface(stream: preview, fill: false)
                        if preview.phase != .live { ProgressView().tint(Theme.onVideo) }
                    }
                }
                .aspectRatio(Theme.tileAspect, contentMode: .fit)
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
                    if let brand = picked?.brand, !password.isEmpty {
                        model.lastLogin[brand] = (username, password)
                    }
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
        let known = camera.brand.flatMap { model.lastLogin[$0] }
        if let known, !camera.isThingino {
            username = known.username
            password = known.password
        }
        // Fresh Thingino cameras use root / root, and a second one usually shares the first one's
        // password. One quiet try saves typing; a miss just leaves the field empty.
        if camera.isThingino {
            password = known?.password ?? "root"
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

    /// Where this camera's password comes from, in the words its owner would recognize.
    static func loginHint(for camera: FoundCamera) -> String {
        if camera.isThingino { return "The password you use for the camera's web page." }
        if let brand = camera.brand { return "The login you set up in the \(brand) app or on the camera's web page." }
        return "The username and password you set up for this camera."
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
