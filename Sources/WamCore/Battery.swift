import Foundation
import IOKit.ps

/// The internal battery, if this Mac has one.
public struct BatterySample: Sendable, Equatable {
    /// 0 to 100.
    public var percent: Int
    public var isCharging: Bool
    /// Plugged in, whether or not it is charging.
    public var onAC: Bool
    /// Minutes until empty (on battery) or until full (charging). Nil while macOS is still working it out.
    public var minutesRemaining: Int?

    public init(percent: Int, isCharging: Bool, onAC: Bool, minutesRemaining: Int? = nil) {
        self.percent = percent
        self.isCharging = isCharging
        self.onAC = onAC
        self.minutesRemaining = minutesRemaining
    }

    public var fraction: Double { Double(min(100, max(0, percent))) / 100 }

    /// 0 fine, 1 low, 2 nearly empty. Only counts while running on battery.
    public var severity: Int {
        if onAC { return 0 }
        if percent <= 10 { return 2 }
        return percent <= 20 ? 1 : 0
    }

    public var stateLabel: String {
        if isCharging { return "Charging" }
        return onAC ? "Plugged in" : "On battery"
    }

    /// "2:15 until empty", "0:40 until full", or nil when there is no estimate.
    public var remainingLabel: String? {
        guard let minutes = minutesRemaining, minutes > 0, !(onAC && !isCharging) else { return nil }
        return String(format: "%d:%02d until %@", minutes / 60, minutes % 60, isCharging ? "full" : "empty")
    }
}

public enum BatterySampler {
    /// Nil on Macs without a battery.
    public static func sample() -> BatterySample? {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let sources = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef] else { return nil }
        for source in sources {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  description[kIOPSIsPresentKey] as? Bool ?? true,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let maximum = description[kIOPSMaxCapacityKey] as? Int, maximum > 0 else { continue }

            let isCharging = description[kIOPSIsChargingKey] as? Bool ?? false
            let onAC = description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue
            let minutes = description[isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            return BatterySample(
                percent: Int((Double(current) / Double(maximum) * 100).rounded()),
                isCharging: isCharging,
                onAC: onAC,
                minutesRemaining: (minutes ?? -1) > 0 ? minutes : nil
            )
        }
        return nil
    }
}
