import IOKit
import Foundation
import Darwin

// Reads CPU/GPU temperatures on Apple Silicon via IOHIDEventSystem.
//
// Technique sourced from exelban/Stats (reader.m + bridge.h):
//   https://github.com/exelban/stats/blob/master/Modules/Sensors/reader.m
//
// Flow:
//   1. IOHIDEventSystemClientCreate(kCFAllocatorDefault)
//   2. IOHIDEventSystemClientSetMatching(client, {PrimaryUsagePage:0xFF00, PrimaryUsage:0x0005})
//   3. IOHIDEventSystemClientCopyServices(client)  → CFArray of IOHIDServiceClientRef
//   4. for each service:
//        IOHIDServiceClientCopyProperty(svc, "Product")  → sensor name string
//        IOHIDServiceClientCopyEvent(svc, 15, 0, 0)      → IOHIDEventRef
//        IOHIDEventGetFloatValue(event, 15 << 16)        → °C
//
// Sensor names on M-series — found via ioreg -r -c AppleARMPMUTempSensor:
//   "PMU tdie1"…"PMU tdie14"   → CPU die (e.g. 14 cores on M4 Pro: 4E + 10P)
//   "PMU tdev1"…"PMU tdev8"    → package / SoC
//   "PMU2 tdie*"                → second die (Max/Ultra chips)

class IOHIDThermalReader {

    // ── C function pointer types, matching Stats/bridge.h exactly ────────────
    private typealias CreateFn    = @convention(c) (OpaquePointer?) -> OpaquePointer?
    private typealias SetMatchFn  = @convention(c) (OpaquePointer, OpaquePointer) -> Int32
    private typealias ServicesFn  = @convention(c) (OpaquePointer) -> OpaquePointer?   // CFArray+1
    private typealias PropFn      = @convention(c) (OpaquePointer, OpaquePointer) -> OpaquePointer?  // CFTypeRef+1
    private typealias CopyEventFn = @convention(c) (OpaquePointer, Int64, Int32, Int64) -> OpaquePointer?  // IOHIDEventRef+1
    private typealias FloatFn     = @convention(c) (OpaquePointer, Int32) -> Double

    private var fnCreate:   CreateFn?
    private var fnSetMatch: SetMatchFn?
    private var fnServices: ServicesFn?
    private var fnProp:     PropFn?
    private var fnEvent:    CopyEventFn?
    private var fnFloat:    FloatFn?
    private var client:     OpaquePointer?

    // kIOHIDEventTypeTemperature  = 15
    // IOHIDEventFieldBase(type)   = type << 16  →  15 << 16 = 0x000F_0000
    private let kTempType:  Int64 = 15
    private let kTempField: Int32 = 15 << 16   // = 0x000F_0000

    // ── Lifecycle ─────────────────────────────────────────────────────────────

    func setup() -> Bool {
        let fw = "/System/Library/Frameworks/IOKit.framework/IOKit"
        guard let handle = dlopen(fw, RTLD_NOW | RTLD_GLOBAL) else { return false }

        guard let p1 = dlsym(handle, "IOHIDEventSystemClientCreate"),
              let p2 = dlsym(handle, "IOHIDEventSystemClientSetMatching"),
              let p3 = dlsym(handle, "IOHIDEventSystemClientCopyServices"),
              let p4 = dlsym(handle, "IOHIDServiceClientCopyProperty"),
              let p5 = dlsym(handle, "IOHIDServiceClientCopyEvent"),
              let p6 = dlsym(handle, "IOHIDEventGetFloatValue")
        else { return false }

        fnCreate   = unsafeBitCast(p1, to: CreateFn.self)
        fnSetMatch = unsafeBitCast(p2, to: SetMatchFn.self)
        fnServices = unsafeBitCast(p3, to: ServicesFn.self)
        fnProp     = unsafeBitCast(p4, to: PropFn.self)
        fnEvent    = unsafeBitCast(p5, to: CopyEventFn.self)
        fnFloat    = unsafeBitCast(p6, to: FloatFn.self)

        guard let c = fnCreate?(nil) else { return false }
        client = c

        // Match only temperature sensors: page=0xFF00, usage=0x0005
        // Use Int32 values to match the int32_t types the kernel expects
        let matchDict: NSDictionary = [
            "PrimaryUsagePage": NSNumber(value: Int32(0xFF00)),
            "PrimaryUsage":     NSNumber(value: Int32(0x0005))
        ]
        let matchPtr = OpaquePointer(
            Unmanaged.passUnretained(matchDict as CFDictionary as AnyObject).toOpaque())
        _ = fnSetMatch?(c, matchPtr)
        return true
    }

    func close() {
        if let c = client {
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(c)).release()
            client = nil
        }
    }

    // ── Public API ────────────────────────────────────────────────────────────

    /// Max CPU die temperature in °C across all "tdie" sensors.
    func cpuTemperature() -> Double? {
        readMax { $0.contains("tdie") || $0.contains("pACC") || $0.contains("eACC") }
    }

    // ── Internal ──────────────────────────────────────────────────────────────

    private func readMax(matching filter: (String) -> Bool) -> Double? {
        guard let c = client else { return nil }
        guard let rawArr = fnServices?(c) else { return nil }

        // CopyServices returns +1
        let cfArr = Unmanaged<CFArray>
            .fromOpaque(UnsafeRawPointer(rawArr))
            .takeRetainedValue()
        let count = CFArrayGetCount(cfArr)
        guard count > 0 else { return nil }

        let productKey = "Product" as CFString
        let keyPtr = OpaquePointer(
            Unmanaged.passUnretained(productKey as AnyObject).toOpaque())

        var best: Double? = nil

        for i in 0..<count {
            guard let rawSvc = CFArrayGetValueAtIndex(cfArr, i) else { continue }
            let svc = OpaquePointer(rawSvc)

            // CopyProperty returns +1 — take ownership then let ARC release
            guard let rawProp = fnProp?(svc, keyPtr) else { continue }
            let name = Unmanaged<CFString>
                .fromOpaque(UnsafeRawPointer(rawProp))
                .takeRetainedValue() as String
            guard filter(name) else { continue }

            // CopyEvent returns +1 — release manually after reading
            guard let rawEvt = fnEvent?(svc, kTempType, 0, 0) else { continue }
            let temp = fnFloat?(rawEvt, kTempField) ?? 0
            Unmanaged<AnyObject>.fromOpaque(UnsafeRawPointer(rawEvt)).release()

            if temp > 10 && temp < 120 {
                best = max(best ?? 0, temp)
            }
        }

        return best
    }
}
