import Foundation

/// Known RTSP paths by brand, for cameras that do not answer ONVIF.
struct BrandTemplate: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let defaultUser: String
    let mainPath: String
    let subPath: String?
    var port: Int = 554

    func url(host: String, path: String) -> String {
        "rtsp://\(Camera.bracket(host)):\(port)/\(path)"
    }

    static let all: [BrandTemplate] = [
        .init(id: "reolink", name: "Reolink", defaultUser: "admin", mainPath: "h264Preview_01_main", subPath: "h264Preview_01_sub"),
        .init(id: "hikvision", name: "Hikvision", defaultUser: "admin", mainPath: "Streaming/Channels/101", subPath: "Streaming/Channels/102"),
        .init(id: "dahua", name: "Dahua", defaultUser: "admin", mainPath: "cam/realmonitor?channel=1&subtype=0", subPath: "cam/realmonitor?channel=1&subtype=1"),
        .init(id: "amcrest", name: "Amcrest", defaultUser: "admin", mainPath: "cam/realmonitor?channel=1&subtype=0", subPath: "cam/realmonitor?channel=1&subtype=1"),
        .init(id: "tapo", name: "TP-Link Tapo", defaultUser: "", mainPath: "stream1", subPath: "stream2"),
        .init(id: "unifi", name: "UniFi Protect", defaultUser: "", mainPath: "", subPath: nil, port: 7447),
        .init(id: "wyze-bridge", name: "Wyze Bridge", defaultUser: "", mainPath: "cam", subPath: "cam-sub", port: 8554),
        .init(id: "go2rtc", name: "go2rtc or Frigate", defaultUser: "", mainPath: "cam", subPath: nil, port: 8554),
    ]

    /// Paths worth trying, in order, on an unknown camera.
    static var probeOrder: [BrandTemplate] {
        all.filter { !$0.mainPath.isEmpty && $0.port == 554 && $0.id != "amcrest" }
    }
}
