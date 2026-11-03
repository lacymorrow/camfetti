// Away is a paid service that has not launched. It compiles only with the AWAY flag (Debug builds),
// so App Store builds carry none of it.
#if AWAY
import Foundation
import IOKit.ps

/// What the bridge heartbeat and hello report about this Mac: its name and power state.
enum DeviceInfo {
    struct Power {
        /// Percent, or a negative number when there is no battery to read.
        var battery: Double
        /// ac, battery or unknown.
        var source: String
    }

    static var name: String {
        var size = 0
        sysctlbyname("hw.model", nil, &size, nil, 0)
        var buffer = [CChar](repeating: 0, count: max(size, 1))
        sysctlbyname("hw.model", &buffer, &size, nil, 0)
        return "\(String(cString: buffer)) macOS \(ProcessInfo.processInfo.operatingSystemVersion.majorVersion)"
    }

    static func power() -> Power {
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
    }
}
#endif
