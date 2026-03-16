import Darwin
import Foundation

/// Tracks CPU utilisation across calls by diffing kernel tick counters.
class CPUMonitor {
    private var prevUser:   UInt64 = 0
    private var prevSystem: UInt64 = 0
    private var prevIdle:   UInt64 = 0
    private var prevNice:   UInt64 = 0

    init() { _ = usage() }  // prime the counters so first real read is meaningful

    /// Returns overall CPU usage in percent (0–100).
    func usage() -> Double {
        var info = host_cpu_load_info_data_t()
        var count = mach_msg_type_number_t(
            MemoryLayout<host_cpu_load_info_data_t>.size / MemoryLayout<integer_t>.size)

        let result = withUnsafeMutablePointer(to: &info) {
            $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
                host_statistics(mach_host_self(), HOST_CPU_LOAD_INFO, $0, &count)
            }
        }
        guard result == KERN_SUCCESS else { return 0 }

        // cpu_ticks indices: 0=USER, 1=SYSTEM, 2=IDLE, 3=NICE
        let user   = UInt64(info.cpu_ticks.0)
        let system = UInt64(info.cpu_ticks.1)
        let idle   = UInt64(info.cpu_ticks.2)
        let nice   = UInt64(info.cpu_ticks.3)

        let dUser   = user   - prevUser
        let dSystem = system - prevSystem
        let dIdle   = idle   - prevIdle
        let dNice   = nice   - prevNice
        let dTotal  = dUser + dSystem + dIdle + dNice

        prevUser   = user
        prevSystem = system
        prevIdle   = idle
        prevNice   = nice

        guard dTotal > 0 else { return 0 }
        return Double(dTotal - dIdle) / Double(dTotal) * 100.0
    }
}
