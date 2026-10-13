import Foundation
import IOKit

/// Link negotiation is a property of the entire device/cable/port path, not a benchmark.
enum USBLinkDiagnostics {
    static let testBytes = 16 * 1024 * 1024
    static func speedMbps(properties: [[String: Any]]) -> UInt32 {
        let devices = properties.filter { ($0["USB Product Name"] as? String) == "HDC Device" }
        guard devices.count == 1, let speed = devices[0]["UsbLinkSpeed"] as? NSNumber,
              speed.doubleValue > 0, speed.doubleValue <= 100_000_000_000 else { return 0 }
        return UInt32(speed.uint64Value / 1_000_000)
    }
    static func negotiatedMbps() -> UInt32 {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOUSBHostDevice"), &iterator) == KERN_SUCCESS else { return 0 }
        defer { IOObjectRelease(iterator) }
        var devices = [[String: Any]]()
        while true {
            let entry = IOIteratorNext(iterator)
            if entry == 0 { break }
            defer { IOObjectRelease(entry) }
            var properties: Unmanaged<CFMutableDictionary>?
            if IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0) == KERN_SUCCESS,
               let values = properties?.takeRetainedValue() as? [String: Any] { devices.append(values) }
        }
        return speedMbps(properties: devices)
    }
    static func testPacket() -> Data {
        var packet = Data(capacity: testBytes + 5)
        packet.append(21)
        var size = UInt32(testBytes).bigEndian
        withUnsafeBytes(of: &size) { packet.append(contentsOf: $0) }
        let block = Data((0..<65536).map { UInt8(truncatingIfNeeded: $0 * 73 + 19) })
        for _ in 0..<(testBytes / block.count) { packet.append(block) }
        return packet
    }
}
