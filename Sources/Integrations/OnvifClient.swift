import CryptoKit
import Foundation

/// The small part of ONVIF CamFetti needs: find the streams and move the motors.
struct OnvifClient: Sendable {
    struct Failure: Error, Equatable {
        enum Kind: Sendable { case unauthorized, notOnvif, badResponse }
        let kind: Kind
    }

    struct Profile: Equatable, Sendable {
        let token: String
        let width: Int
        let height: Int
        var pixels: Int { width * height }
    }

    struct Discovered: Equatable, Sendable {
        var name: String?
        var mediaURL: String
        var ptzURL: String?
        var mainProfile: Profile
        var subProfile: Profile?
        var mainStream: String
        var subStream: String?
        var snapshotURL: String?
    }

    /// Ports cameras commonly use for ONVIF. Reolink 8000, Tapo 2020, Hikvision and Dahua 80.
    static let commonPorts = [80, 8000, 2020, 8080, 8899]

    let deviceURL: String
    let username: String
    let password: String
    var session: URLSession = .shared

    func discover() async throws -> Discovered {
        let caps = try await call(deviceURL, #"<GetCapabilities xmlns="http://www.onvif.org/ver10/device/wsdl"><Category>All</Category></GetCapabilities>"#)
        guard let media = caps.first("Media")?.first("XAddr")?.value else { throw Failure(kind: .badResponse) }
        let mediaURL = Self.rebase(media, onto: deviceURL)
        let ptzURL = caps.first("PTZ")?.first("XAddr")?.value.nilIfEmpty.map { Self.rebase($0, onto: deviceURL) }

        let info = try? await call(deviceURL, #"<GetDeviceInformation xmlns="http://www.onvif.org/ver10/device/wsdl"/>"#)
        let name = [info?.first("Manufacturer")?.value, info?.first("Model")?.value]
            .compactMap { $0?.nilIfEmpty }.joined(separator: " ").nilIfEmpty

        let profilesXML = try await call(mediaURL, #"<GetProfiles xmlns="http://www.onvif.org/ver10/media/wsdl"/>"#)
        let picked = Self.pickProfiles(Self.profiles(in: profilesXML))
        guard let main = picked.main else { throw Failure(kind: .badResponse) }

        let mainStream = try await streamURI(mediaURL, token: main.token)
        let subStream = picked.sub == nil ? nil : try? await streamURI(mediaURL, token: picked.sub!.token)
        let snapshot = try? await call(mediaURL, #"<GetSnapshotUri xmlns="http://www.onvif.org/ver10/media/wsdl"><ProfileToken>\#(main.token.xmlEscaped)</ProfileToken></GetSnapshotUri>"#)
        return Discovered(name: name, mediaURL: mediaURL, ptzURL: ptzURL, mainProfile: main, subProfile: picked.sub,
                          mainStream: mainStream, subStream: subStream,
                          snapshotURL: snapshot?.first("Uri")?.value.nilIfEmpty.map { Self.rebase($0, onto: deviceURL) })
    }

    /// Velocity pan and tilt, each -1...1. Send zero to stop.
    func move(ptzURL: String, profile: String, pan: Double, tilt: Double) async throws {
        if pan == 0 && tilt == 0 {
            _ = try await call(ptzURL, #"<Stop xmlns="http://www.onvif.org/ver20/ptz/wsdl"><ProfileToken>\#(profile.xmlEscaped)</ProfileToken><PanTilt>true</PanTilt><Zoom>false</Zoom></Stop>"#)
        } else {
            _ = try await call(ptzURL, #"<ContinuousMove xmlns="http://www.onvif.org/ver20/ptz/wsdl"><ProfileToken>\#(profile.xmlEscaped)</ProfileToken><Velocity><PanTilt xmlns="http://www.onvif.org/ver10/schema" x="\#(pan)" y="\#(tilt)"/></Velocity></ContinuousMove>"#)
        }
    }

    private func streamURI(_ mediaURL: String, token: String) async throws -> String {
        let xml = try await call(mediaURL, #"<GetStreamUri xmlns="http://www.onvif.org/ver10/media/wsdl"><StreamSetup><Stream xmlns="http://www.onvif.org/ver10/schema">RTP-Unicast</Stream><Transport xmlns="http://www.onvif.org/ver10/schema"><Protocol>RTSP</Protocol></Transport></StreamSetup><ProfileToken>\#(token.xmlEscaped)</ProfileToken></GetStreamUri>"#)
        guard let uri = xml.first("Uri")?.value.nilIfEmpty else { throw Failure(kind: .badResponse) }
        return Self.rebase(uri, onto: deviceURL)
    }

    private func call(_ url: String, _ body: String) async throws -> XMLNode {
        guard let target = URL(string: url) else { throw Failure(kind: .notOnvif) }
        var request = URLRequest(url: target, timeoutInterval: 5)
        request.httpMethod = "POST"
        request.setValue("application/soap+xml; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(Self.envelope(body: body, username: username, password: password).utf8)
        let (data, response) = try await session.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        let xml = XMLNode.parse(data)
        if status == 401 || xml?.first("NotAuthorized") != nil { throw Failure(kind: .unauthorized) }
        if xml?.first("Fault") != nil {
            let text = xml?.first("Fault")?.first("Text")?.value.lowercased() ?? ""
            if text.contains("auth") || text.contains("sender not") { throw Failure(kind: .unauthorized) }
            throw Failure(kind: .badResponse)
        }
        guard status == 200, let xml, xml.first("Envelope") != nil else { throw Failure(kind: .notOnvif) }
        return xml
    }

    // MARK: Pure helpers

    static func envelope(body: String, username: String, password: String,
                         nonce: Data? = nil, created: Date = Date()) -> String {
        let security = username.isEmpty ? "" : securityHeader(username: username, password: password, nonce: nonce, created: created)
        return """
        <?xml version="1.0" encoding="UTF-8"?>\
        <s:Envelope xmlns:s="http://www.w3.org/2003/05/soap-envelope" \
        xmlns:wsse="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-secext-1.0.xsd" \
        xmlns:wsu="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-wssecurity-utility-1.0.xsd">\
        <s:Header>\(security)</s:Header><s:Body>\(body)</s:Body></s:Envelope>
        """
    }

    static func passwordDigest(password: String, nonce: Data, created: String) -> String {
        var input = nonce
        input.append(Data(created.utf8))
        input.append(Data(password.utf8))
        return Data(Insecure.SHA1.hash(data: input)).base64EncodedString()
    }

    private static func securityHeader(username: String, password: String, nonce: Data?, created: Date) -> String {
        var bytes = [UInt8](repeating: 0, count: 16)
        if nonce == nil { _ = SecRandomCopyBytes(kSecRandomDefault, bytes.count, &bytes) }
        let nonceData = nonce ?? Data(bytes)
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let stamp = formatter.string(from: created)
        return """
        <wsse:Security><wsse:UsernameToken><wsse:Username>\(username.xmlEscaped)</wsse:Username>\
        <wsse:Password Type="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-username-token-profile-1.0#PasswordDigest">\(passwordDigest(password: password, nonce: nonceData, created: stamp))</wsse:Password>\
        <wsse:Nonce EncodingType="http://docs.oasis-open.org/wss/2004/01/oasis-200401-wss-soap-message-security-1.0#Base64Binary">\(nonceData.base64EncodedString())</wsse:Nonce>\
        <wsu:Created>\(stamp)</wsu:Created></wsse:UsernameToken></wsse:Security>
        """
    }

    static func profiles(in xml: XMLNode) -> [Profile] {
        xml.all("Profiles").compactMap { node in
            guard let token = node.attributes["token"] else { return nil }
            let res = node.first("VideoEncoderConfiguration")?.first("Resolution")
            return Profile(token: token,
                           width: Int(res?.first("Width")?.value ?? "") ?? 0,
                           height: Int(res?.first("Height")?.value ?? "") ?? 0)
        }
    }

    /// Largest profile is main. Smallest different one is the grid stream.
    static func pickProfiles(_ profiles: [Profile]) -> (main: Profile?, sub: Profile?) {
        let sorted = profiles.sorted { $0.pixels > $1.pixels }
        guard let main = sorted.first else { return (nil, nil) }
        let sub = sorted.last.flatMap { $0.token != main.token && $0.pixels < main.pixels ? $0 : nil }
        return (main, sub)
    }

    /// Cameras often report an internal address or the wrong host. Trust the host we reached.
    static func rebase(_ reported: String, onto device: String) -> String {
        guard var r = URLComponents(string: reported), let d = URLComponents(string: device) else { return reported }
        r.host = d.host
        if r.scheme == "http" || r.scheme == "https", r.port == nil || r.port == 80 { r.port = d.port }
        return r.string ?? reported
    }
}

extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
