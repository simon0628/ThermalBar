import IOKit
import Foundation

/// Reads GPU utilisation from IOAccelerator PerformanceStatistics.
/// Uses IOKit registry (no entitlements needed, no private framework).
class GPUMonitor {
    func usage() -> Double? {
        var iter: io_iterator_t = 0
        guard IOServiceGetMatchingServices(
            kIOMainPortDefault,
            IOServiceMatching("IOAccelerator"),
            &iter) == kIOReturnSuccess
        else { return nil }
        defer { IOObjectRelease(iter) }

        var best: Double? = nil
        var service = IOIteratorNext(iter)
        while service != 0 {
            defer {
                IOObjectRelease(service)
                service = IOIteratorNext(iter)
            }
            var props: Unmanaged<CFMutableDictionary>?
            guard IORegistryEntryCreateCFProperties(
                service, &props, kCFAllocatorDefault, 0) == kIOReturnSuccess,
                  let dict = props?.takeRetainedValue() as? [String: Any],
                  let perf = dict["PerformanceStatistics"] as? [String: Any]
            else { continue }

            // Key names vary by GPU vendor / macOS version
            for key in ["Device Utilization %", "GPU Activity(%)", "Utilization(Device) %"] {
                let val: Double? = (perf[key] as? Double) ?? (perf[key] as? Int).map(Double.init)
                if let v = val { best = max(best ?? 0, v) }
            }
        }
        return best
    }
}
