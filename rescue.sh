#!/bin/bash
# 紧急救援：重置 SMC 风扇控制，恢复系统自动模式
# 必须 root 运行。sudo bash rescue.sh
set -euo pipefail

cd "$(dirname "$0")"

# 1. 停掉旧守护进程并删除 plist
echo "==> 停止守护进程"
launchctl bootout system/com.ifan.helper 2>/dev/null || true
rm -f /Library/LaunchDaemons/com.ifan.helper.plist

# 2. 编译临时 SMC 解锁工具（通过 swift 直接运行）
echo "==> 编译 SMC 解锁探针"
cat > /tmp/ifan_unlock.swift <<'SWIFT'
import IOKit
import Foundation

// Simplified SMC write — just enough to reset Ftst + fan modes.
typealias SMCBytes = (UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,
                       UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8,UInt8)

struct SMCVersion { var major:CUnsignedChar=0; var minor:CUnsignedChar=0; var build:CUnsignedChar=0; var reserved:CUnsignedChar=0; var release:CUnsignedShort=0 }
struct SMCPLimitData { var version:UInt16=0; var length:UInt16=0; var cpuPLimit:UInt32=0; var gpuPLimit:UInt32=0; var memPLimit:UInt32=0 }
struct SMCKeyInfoData { var dataSize:UInt32=0; var dataType:UInt32=0; var dataAttributes:UInt8=0 }
struct SMCParamStruct { var key:UInt32=0; var vers=SMCVersion(); var pLimitData=SMCPLimitData(); var keyInfo=SMCKeyInfoData(); var padding:UInt16=0; var result:UInt8=0; var status:UInt8=0; var data8:UInt8=0; var data32:UInt32=0; var bytes:SMCBytes=(0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0,0) }

func f32(_ s:String)->UInt32 { var r:UInt32=0; for ch in s.utf8 { r=(r<<8)+UInt32(ch) }; return r }
func readKeyInfo(_ conn:io_connect_t, _ key:String)->(UInt32,UInt32) {
    var input=SMCParamStruct()
    input.key=f32(key)
    input.data8=9 // kGetKeyInfo
    var out=SMCParamStruct()
    let inSz=MemoryLayout<SMCParamStruct>.stride
    var outSz=MemoryLayout<SMCParamStruct>.stride
    IOConnectCallStructMethod(conn,2,&input,inSz,&out,&outSz)
    return (out.keyInfo.dataSize, out.keyInfo.dataType)
}
func keyExists(_ conn:io_connect_t, _ key:String)->Bool { readKeyInfo(conn,key).0>0 }
func writeU8(_ conn:io_connect_t, _ key:String, _ val:UInt8)->UInt8 {
    var input=SMCParamStruct()
    input.key=f32(key)
    input.keyInfo.dataSize=1
    input.data8=6 // kWrite
    input.bytes.0=val
    var out=SMCParamStruct()
    let inSz=MemoryLayout<SMCParamStruct>.stride
    var outSz=MemoryLayout<SMCParamStruct>.stride
    IOConnectCallStructMethod(conn,2,&input,inSz,&out,&outSz)
    return out.result
}
func readU8(_ conn:io_connect_t, _ key:String)->UInt8? {
    guard readKeyInfo(conn,key).0>0 else { return nil }
    var input=SMCParamStruct()
    input.key=f32(key)
    input.keyInfo.dataSize=1
    input.data8=5
    var out=SMCParamStruct()
    let inSz=MemoryLayout<SMCParamStruct>.stride
    var outSz=MemoryLayout<SMCParamStruct>.stride
    IOConnectCallStructMethod(conn,2,&input,inSz,&out,&outSz)
    return out.bytes.0
}

let s=IOServiceGetMatchingService(kIOMainPortDefault,IOServiceMatching("AppleSMC"))
guard s != 0 else { print("AppleSMC not found (internal error)"); exit(1) }
var conn:io_connect_t=0
guard IOServiceOpen(s,mach_task_self_,0,&conn)==KERN_SUCCESS else { print("Cannot open AppleSMC"); exit(1) }
IOObjectRelease(s)

// --- reset -------------------------------------------------------
print("=== SMC Fan Rescue ===")
print("FNum =",readU8(conn,"FNum").map{String($0)} ?? "?")

for fan in 0..<2 {
    let mdKeys = keyExists(conn,"F\(fan)Md") ? ["F\(fan)Md"] : ["F\(fan)md"]
    for mk in mdKeys {
        let before = readU8(conn,mk).map{String($0)} ?? "?"
        let r = writeU8(conn,mk,0)
        let after = readU8(conn,mk).map{String($0)} ?? "?"
        print("\(mk): \(before) -> [write result=0x\(String(r,radix:16))] -> \(after)")
    }
}

if keyExists(conn,"Ftst") {
    let before = readU8(conn,"Ftst").map{String($0)} ?? "?"
    let r = writeU8(conn,"Ftst",0)
    let after = readU8(conn,"Ftst").map{String($0)} ?? "?"
    print("Ftst: \(before) -> [write result=0x\(String(r,radix:16))] -> \(after)")
} else {
    print("Ftst key not present on this hardware")
}

print("=== Rescue complete. Fans should now obey system thermal management. ===")
IOServiceClose(conn)
SWIFT

cd /tmp
swift ifan_unlock.swift
echo ""
echo "==> 风扇已恢复系统自动控制，请确认转速是否正常"