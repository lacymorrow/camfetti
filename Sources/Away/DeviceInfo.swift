// The bridge role runs on iPhone and Mac only.
#if os(iOS) || os(macOS)
import Foundation
#if os(iOS)
import UIKit
#else
import IOKit.ps
#endif

/// The two things the heartbeat and hello need that differ by platform: the device's name
/// and its power state.
enum DeviceInfo {
    struct Power {
        /// Percent, or a negative number when there is no battery to read.
        var battery: Double
        /// iOS: charging, full, unplugged, unknown. Mac: ac, battery, unknown.
        var source: String
    }

    private static var hardwareModel: String {
        #if os(iOS)
        var info = utsname()
        uname(&info)
        return withUnsafeBytes(of: &info.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
        #else
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return String(cString: buffer)
        #endif
    }

    static var name: String {
        #if os(iOS)
        "\(hardwareModel) iOS \(UIDevice.current.systemVersion)"
        #else
        "\(hardwareModel) macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
        #endif
    }

    static func startMonitoring() {
        #if os(iOS)
        UIDevice.current.isBatteryMonitoringEnabled = true
        #endif
    }

    static func power() -> Power {
        #if os(iOS)
        let device = UIDevice.current
        let source: String = switch device.batteryState {
        case .charging: "charging"
        case .full: "full"
        case .unplugged: "unplugged"
        default: "unknown"
        }
        return Power(battery: (Double(device.batteryLevel) * 100).rounded(), source: source)
        #else
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue() else { return Power(battery: -100, source: "unknown") }
        let providing = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() as String?
        let source = switch providing {
        case kIOPMACPowerKey: "ac"
        case kIOPMBatteryPowerKey: "battery"
        default: "unknown"
        }
        var level = -100.0
        if let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] {
            for item in list {
                guard let d = IOPSGetPowerSourceDescription(info, item)?.takeUnretainedValue() as? [String: Any],
                      let now = (d[kIOPSCurrentCapacityKey] as? NSNumber)?.doubleValue,
                      let max = (d[kIOPSMaxCapacityKey] as? NSNumber)?.doubleValue, max > 0
                else { continue }
                level = (now / max * 100).rounded()
            }
        }
        return Power(battery: level, source: source)
        #endif
    }
}
#endif
