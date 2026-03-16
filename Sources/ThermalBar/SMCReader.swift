import IOKit
import Foundation

// Reads temperatures from the System Management Controller via IOKit.
// Supports Intel and Apple Silicon (M1–M4) key sets, sp78 and flt encodings.
class SMCReader {
    private var connection: io_connect_t = 0

    // -----------------------------------------------------------------------
    // Flat struct matching the C SMCParamStruct exactly — 80 bytes.
    //
    // Key rule: two explicit padding fields are required so Swift doesn't
    // insert its OWN implicit padding that would shift all subsequent fields:
    //
    //   cpad0  (2 bytes) after vRelease  — aligns pLimitData to 4-byte boundary
    //   cpad1–3 (3 bytes) after dataAttributes — rounds SMCKeyInfoData to 12 bytes
    //   cpad4  (1 byte) after data8     — aligns data32 to 4-byte boundary
    //
    // Verified offset-by-offset below; MemoryLayout<Param>.size must == 80.
    // -----------------------------------------------------------------------
    private struct Param {
        var key: UInt32 = 0              // [0]  4

        // SMCVersion — 6 bytes
        var vMajor:    UInt8  = 0        // [4]
        var vMinor:    UInt8  = 0        // [5]
        var vBuild:    UInt8  = 0        // [6]
        var vReserved: UInt8  = 0        // [7]
        var vRelease:  UInt16 = 0        // [8]

        // Explicit 2-byte pad: C aligns SMCPLimitData (max field UInt32) to offset 12
        var cpad0: UInt16 = 0            // [10]

        // SMCPLimitData — 16 bytes starting at [12]
        var plVersion: UInt16 = 0        // [12]
        var plLength:  UInt16 = 0        // [14]
        var plCPU:     UInt32 = 0        // [16]  ← 4-aligned ✓
        var plGPU:     UInt32 = 0        // [20]
        var plMem:     UInt32 = 0        // [24]

        // SMCKeyInfoData — 12 bytes (9 + 3 pad) starting at [28]
        var dataSize:       UInt32 = 0   // [28]  ← 4-aligned ✓
        var dataType:       UInt32 = 0   // [32]
        var dataAttributes: UInt8  = 0   // [36]
        var cpad1: UInt8 = 0             // [37]  explicit pad to round struct to 12 bytes
        var cpad2: UInt8 = 0             // [38]
        var cpad3: UInt8 = 0             // [39]

        // Control bytes
        var result: UInt8 = 0            // [40]
        var status: UInt8 = 0            // [41]
        var data8:  UInt8 = 0            // [42]  SMC sub-command
        var cpad4:  UInt8 = 0            // [43]  explicit pad to align data32

        var data32: UInt32 = 0           // [44]  ← 4-aligned ✓

        // Payload — 32 bytes at [48]
        var b0:  UInt8 = 0; var b1:  UInt8 = 0; var b2:  UInt8 = 0; var b3:  UInt8 = 0
        var b4:  UInt8 = 0; var b5:  UInt8 = 0; var b6:  UInt8 = 0; var b7:  UInt8 = 0
        var b8:  UInt8 = 0; var b9:  UInt8 = 0; var b10: UInt8 = 0; var b11: UInt8 = 0
        var b12: UInt8 = 0; var b13: UInt8 = 0; var b14: UInt8 = 0; var b15: UInt8 = 0
        var b16: UInt8 = 0; var b17: UInt8 = 0; var b18: UInt8 = 0; var b19: UInt8 = 0
        var b20: UInt8 = 0; var b21: UInt8 = 0; var b22: UInt8 = 0; var b23: UInt8 = 0
        var b24: UInt8 = 0; var b25: UInt8 = 0; var b26: UInt8 = 0; var b27: UInt8 = 0
        var b28: UInt8 = 0; var b29: UInt8 = 0; var b30: UInt8 = 0; var b31: UInt8 = 0
        // Total: 80 bytes

        var byteArray: [UInt8] {
            [b0,  b1,  b2,  b3,  b4,  b5,  b6,  b7,
             b8,  b9,  b10, b11, b12, b13, b14, b15,
             b16, b17, b18, b19, b20, b21, b22, b23,
             b24, b25, b26, b27, b28, b29, b30, b31]
        }
    }

    // MARK: - Lifecycle

    func open() -> Bool {
        assert(MemoryLayout<Param>.size == 80,
               "SMC struct size wrong: \(MemoryLayout<Param>.size) (expected 80)")
        let service = IOServiceGetMatchingService(
            kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return false }
        let r = IOServiceOpen(service, mach_task_self_, 0, &connection)
        IOObjectRelease(service)
        return r == kIOReturnSuccess
    }

    func close() {
        guard connection != 0 else { return }
        IOServiceClose(connection)
        connection = 0
    }

    // MARK: - Low-level

    private func fourCC(_ s: String) -> UInt32 {
        s.utf8.prefix(4).reduce(0) { ($0 << 8) | UInt32($1) }
    }

    private func call(_ p: inout Param) -> Param? {
        var out = Param()
        var size = MemoryLayout<Param>.size
        let r = withUnsafeMutablePointer(to: &p) { i in
            withUnsafeMutablePointer(to: &out) { o in
                IOConnectCallStructMethod(
                    connection, 2,
                    UnsafeRawPointer(i), size,
                    UnsafeMutableRawPointer(o), &size)
            }
        }
        return r == kIOReturnSuccess ? out : nil
    }

    /// Returns (bytes, dataType fourCC) for a key, or nil if unavailable.
    func readKey(_ key: String) -> (bytes: [UInt8], type: UInt32)? {
        var p = Param()
        p.key  = fourCC(key)
        p.data8 = 9           // kSMCGetKeyInfo
        guard let info = call(&p), info.result == 0 else { return nil }

        var p2 = Param()
        p2.key      = fourCC(key)
        p2.dataSize = info.dataSize
        p2.data8    = 5       // kSMCReadKey
        guard let data = call(&p2), data.result == 0 else { return nil }

        let bytes = Array(data.byteArray.prefix(Int(info.dataSize)))
        return (bytes, info.dataType)
    }

    // MARK: - Decoding

    /// SP78: signed fixed-point 7.8 (Apple's standard temperature encoding).
    private func decodeSP78(_ b: [UInt8]) -> Double {
        guard b.count >= 2 else { return 0 }
        return Double(Int16(bitPattern: UInt16(b[0]) << 8 | UInt16(b[1]))) / 256.0
    }

    /// IEEE 754 single-precision float (used by some Apple Silicon sensors).
    private func decodeFlt(_ b: [UInt8]) -> Double {
        guard b.count >= 4 else { return 0 }
        let bits = UInt32(b[0]) << 24 | UInt32(b[1]) << 16 | UInt32(b[2]) << 8 | UInt32(b[3])
        return Double(Float(bitPattern: bits))
    }

    private func decodeTemp(_ b: [UInt8], type: UInt32) -> Double {
        let t = type == fourCC("flt ") ? decodeFlt(b) : decodeSP78(b)
        return (t > 10 && t < 120) ? t : 0
    }

    // MARK: - Public API

    /// CPU die temperature in °C. Tries Apple Silicon M1–M4 keys, then Intel.
    func cpuTemperature() -> Double? {
        // Apple Silicon: M4/M3 → M2 → M1 patterns, then Intel fallback
        let keys = [
            // M4 Pro/Max (Mac16,x) — broader Tp range
            "Tp29", "Tp2D", "Tp2H", "Tp2L", "Tp2P", "Tp2T",
            "Tp19", "Tp1D", "Tp1H", "Tp1L", "Tp1P", "Tp1T",
            // M2 / M3
            "Tp1h", "Tp1t", "Tp1p",
            // M1
            "Tp09", "Tp0T", "Tp05", "Tp01", "Tp0D", "Tp0H", "Tp0L", "Tp0P",
            // Intel
            "TC0D", "TC0P", "TC1C", "TCXC", "TCSA", "TC0c",
        ]
        for key in keys {
            if let r = readKey(key) {
                let t = decodeTemp(r.bytes, type: r.type)
                if t > 0 { return t }
            }
        }
        return nil
    }

    /// GPU die temperature in °C (best-effort).
    func gpuTemperature() -> Double? {
        let keys = ["Tg05", "Tg0D", "Tg0L", "Tg0T", "TGDD", "TG0D"]
        for key in keys {
            if let r = readKey(key) {
                let t = decodeTemp(r.bytes, type: r.type)
                if t > 0 { return t }
            }
        }
        return nil
    }
}
