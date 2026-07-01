import Foundation
import IOKit

/// Low-level access to AppleSMC via IOKit.
/// Reading sensors works without root; writing fan keys requires root privileges.
final class SMC {

    // MARK: - SMC param struct (layout verified to match AppleSMC user client)

    typealias SMCBytes = (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8,
                          UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8)

    private struct SMCVersion {
        var major: CUnsignedChar = 0
        var minor: CUnsignedChar = 0
        var build: CUnsignedChar = 0
        var reserved: CUnsignedChar = 0
        var release: CUnsignedShort = 0
    }
    private struct SMCPLimitData {
        var version: UInt16 = 0
        var length: UInt16 = 0
        var cpuPLimit: UInt32 = 0
        var gpuPLimit: UInt32 = 0
        var memPLimit: UInt32 = 0
    }
    private struct SMCKeyInfoData {
        var dataSize: UInt32 = 0
        var dataType: UInt32 = 0
        var dataAttributes: UInt8 = 0
    }
    private struct SMCParamStruct {
        var key: UInt32 = 0
        var vers = SMCVersion()
        var pLimitData = SMCPLimitData()
        var keyInfo = SMCKeyInfoData()
        var padding: UInt16 = 0
        var result: UInt8 = 0
        var status: UInt8 = 0
        var data8: UInt8 = 0
        var data32: UInt32 = 0
        var bytes: SMCBytes = (0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,
                               0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0)
    }

    private enum Cmd {
        static let read: UInt8 = 5
        static let write: UInt8 = 6
        static let keyFromIndex: UInt8 = 8
        static let keyInfo: UInt8 = 9
    }

    // MARK: - Connection

    private var conn: io_connect_t = 0

    init?() {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSMC"))
        guard service != 0 else { return nil }
        let result = IOServiceOpen(service, mach_task_self_, 0, &conn)
        IOObjectRelease(service)
        guard result == kIOReturnSuccess else { return nil }
    }

    deinit {
        if conn != 0 { IOServiceClose(conn) }
    }

    // MARK: - FourCharCode helpers

    static func fourCharToUInt32(_ s: String) -> UInt32 {
        var r: UInt32 = 0
        for ch in s.utf8 { r = (r << 8) + UInt32(ch) }
        return r
    }
    static func uint32ToFourChar(_ v: UInt32) -> String {
        let bytes = [UInt8((v >> 24) & 0xff), UInt8((v >> 16) & 0xff),
                     UInt8((v >> 8) & 0xff), UInt8(v & 0xff)]
        return String(bytes: bytes, encoding: .ascii) ?? "????"
    }

    // MARK: - Core call

    private func call(_ input: inout SMCParamStruct) -> (out: SMCParamStruct, kr: kern_return_t) {
        var output = SMCParamStruct()
        let inSize = MemoryLayout<SMCParamStruct>.stride
        var outSize = MemoryLayout<SMCParamStruct>.stride
        let kr = IOConnectCallStructMethod(conn, 2, &input, inSize, &output, &outSize)
        return (output, kr)
    }

    func keyInfo(_ key: String) -> (size: UInt32, type: String) {
        var input = SMCParamStruct()
        input.key = SMC.fourCharToUInt32(key)
        input.data8 = Cmd.keyInfo
        let out = call(&input).out
        return (out.keyInfo.dataSize, SMC.uint32ToFourChar(out.keyInfo.dataType).trimmingCharacters(in: .whitespaces))
    }

    private func readRaw(_ key: String, size: UInt32) -> [UInt8] {
        var input = SMCParamStruct()
        input.key = SMC.fourCharToUInt32(key)
        input.keyInfo.dataSize = size
        input.data8 = Cmd.read
        let out = call(&input).out
        let b = out.bytes
        let all = [b.0,b.1,b.2,b.3,b.4,b.5,b.6,b.7,b.8,b.9,b.10,b.11,b.12,b.13,b.14,b.15,
                   b.16,b.17,b.18,b.19,b.20,b.21,b.22,b.23,b.24,b.25,b.26,b.27,b.28,b.29,b.30,b.31]
        return Array(all.prefix(Int(min(size, 32))))
    }

    // MARK: - Public read API

    /// Reads a key as Double, decoding common numeric SMC types.
    func readValue(_ key: String) -> Double? {
        let info = keyInfo(key)
        guard info.size > 0 else { return nil }
        let bytes = readRaw(key, size: info.size)
        guard bytes.count >= Int(info.size) else { return nil }
        switch info.type {
        case "flt":
            guard bytes.count >= 4 else { return nil }
            let bits = UInt32(bytes[0]) | (UInt32(bytes[1]) << 8) | (UInt32(bytes[2]) << 16) | (UInt32(bytes[3]) << 24)
            return Double(Float(bitPattern: bits))
        case "sp78":
            guard bytes.count >= 2 else { return nil }
            let raw = Int16(bitPattern: (UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
            return Double(raw) / 256.0
        case "fpe2":
            guard bytes.count >= 2 else { return nil }
            let raw = (UInt16(bytes[0]) << 8) | UInt16(bytes[1])
            return Double(raw) / 4.0
        case "ui8":
            return Double(bytes[0])
        case "ui16":
            guard bytes.count >= 2 else { return nil }
            return Double((UInt16(bytes[0]) << 8) | UInt16(bytes[1]))
        case "ui32":
            guard bytes.count >= 4 else { return nil }
            return Double((UInt32(bytes[0]) << 24) | (UInt32(bytes[1]) << 16) | (UInt32(bytes[2]) << 8) | UInt32(bytes[3]))
        default:
            return nil
        }
    }

    /// Reads a key as an ASCII string (typically type "ch8*").
    func readString(_ key: String) -> String? {
        let info = keyInfo(key)
        guard info.size > 0 else { return nil }
        let bytes = readRaw(key, size: info.size)
        let filtered = bytes.prefix(while: { $0 != 0 })
        return String(bytes: filtered, encoding: .ascii)?.trimmingCharacters(in: .whitespaces)
    }

    /// Enumerates every SMC key name on the system.
    func allKeyNames() -> [String] {
        guard let count = readValue("#KEY"), count > 0 else { return [] }
        let total = UInt32(count)
        var names: [String] = []
        names.reserveCapacity(Int(total))
        for i in 0..<total {
            var input = SMCParamStruct()
            input.data8 = Cmd.keyFromIndex
            input.data32 = i
            let out = call(&input).out
            names.append(SMC.uint32ToFourChar(out.key))
        }
        return names
    }

    /// True if the SMC has a key with this name.
    func keyExists(_ key: String) -> Bool {
        keyInfo(key).size > 0
    }

    // MARK: - Public write API (requires root)

    /// Outcome of an SMC write, carrying both the IOKit transport result and
    /// the firmware-level result byte so callers can distinguish:
    /// - `kr == kIOReturnNotPrivileged (0xe00002c2)` → code-signing / entitlement wall
    /// - `result == 0x82 (kSMCBadCommand)` → firmware rejected the command (locked)
    struct WriteOutcome {
        let kr: kern_return_t
        let result: UInt8
        var ok: Bool { kr == KERN_SUCCESS && result == 0 }
        var description: String {
            String(format: "kr=0x%08x result=0x%02x", UInt32(bitPattern: kr), result)
        }
    }

    /// Writes a Float (`flt`) value to a key.
    @discardableResult
    func writeFloat(_ key: String, _ value: Float) -> WriteOutcome {
        let bits = value.bitPattern
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = UInt8(bits & 0xff)
        bytes[1] = UInt8((bits >> 8) & 0xff)
        bytes[2] = UInt8((bits >> 16) & 0xff)
        bytes[3] = UInt8((bits >> 24) & 0xff)
        return write(key, size: 4, bytes: bytes)
    }

    /// Writes a UInt8 (`ui8`) value to a key.
    @discardableResult
    func writeUInt8(_ key: String, _ value: UInt8) -> WriteOutcome {
        var bytes = [UInt8](repeating: 0, count: 32)
        bytes[0] = value
        return write(key, size: 1, bytes: bytes)
    }

    private func write(_ key: String, size: UInt32, bytes: [UInt8]) -> WriteOutcome {
        var input = SMCParamStruct()
        input.key = SMC.fourCharToUInt32(key)
        input.keyInfo.dataSize = size
        input.data8 = Cmd.write
        withUnsafeMutableBytes(of: &input.bytes) { ptr in
            for i in 0..<Int(min(size, 32)) { ptr[i] = bytes[i] }
        }
        let (out, kr) = call(&input)
        return WriteOutcome(kr: kr, result: out.result)
    }
}
