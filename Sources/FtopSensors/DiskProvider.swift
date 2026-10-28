import Foundation
import FtopCore
import IOKit

/// The startup disk: capacity from the file system, read and write rates from the
/// block storage drivers' byte counters. Both are public interfaces; no admin rights.
final class DiskProvider {
    private var previous: (read: UInt64, written: UInt64, time: TimeInterval)?
    private var capacity: (total: UInt64, available: UInt64)?
    private var capacityAge = 0

    func sample(now: TimeInterval) -> Reading<DiskSample> {
        // Free space moves slowly and asking for it can take a few milliseconds; read it every fifth sample.
        if capacity == nil || capacityAge % 5 == 0 { capacity = Self.readCapacity() ?? capacity }
        capacityAge += 1
        guard let capacity else { return .unavailable("the startup volume reports no capacity") }

        let read: Reading<Double>
        let write: Reading<Double>
        if let totals = Self.readTotals() {
            if let previous, let down = Metrics.rate(previous: previous.read, current: totals.read, seconds: now - previous.time),
                let up = Metrics.rate(previous: previous.written, current: totals.written, seconds: now - previous.time)
            {
                read = .value(down)
                write = .value(up)
            } else {
                let reason = previous == nil ? "waiting for a second sample" : "counters reset"
                read = .unavailable(reason)
                write = .unavailable(reason)
            }
            previous = (totals.read, totals.written, now)
        } else {
            read = .unavailable("no block storage driver reports statistics")
            write = read
        }
        return .value(DiskSample(totalBytes: capacity.total, availableBytes: capacity.available, readBytesPerSecond: read, writeBytesPerSecond: write))
    }

    /// The startup volume's container: its size, and the space new files can have, as Finder counts it.
    private static func readCapacity() -> (total: UInt64, available: UInt64)? {
        let keys: Set<URLResourceKey> = [.volumeTotalCapacityKey, .volumeAvailableCapacityForImportantUsageKey, .volumeAvailableCapacityKey]
        // A new URL each time: resource values are cached on the URL instance.
        guard let values = try? URL(fileURLWithPath: "/").resourceValues(forKeys: keys), let total = values.volumeTotalCapacity, total > 0
        else { return nil }
        let available = values.volumeAvailableCapacityForImportantUsage.map { Int($0) } ?? values.volumeAvailableCapacity ?? 0
        return (UInt64(total), UInt64(min(max(0, available), total)))
    }

    /// Bytes read and written since boot, summed over the onboard drives. Disk images
    /// are left out: what they read is already counted on the drive that holds them.
    /// Without any drive marked onboard, every drive that is not a disk image counts.
    private static func readTotals() -> (read: UInt64, written: UInt64)? {
        var iterator: io_iterator_t = 0
        guard IOServiceGetMatchingServices(kIOMainPortDefault, IOServiceMatching("IOBlockStorageDriver"), &iterator) == KERN_SUCCESS else {
            return nil
        }
        defer { IOObjectRelease(iterator) }
        var onboard: (read: UInt64, written: UInt64, count: Int) = (0, 0, 0)
        var elsewhere: (read: UInt64, written: UInt64, count: Int) = (0, 0, 0)
        while true {
            let driver = IOIteratorNext(iterator)
            if driver == 0 { break }
            defer { IOObjectRelease(driver) }
            guard
                let statistics = IORegistryEntryCreateCFProperty(driver, "Statistics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
                    as? [String: Any]
            else { continue }
            let read = (statistics["Bytes (Read)"] as? NSNumber)?.uint64Value ?? 0
            let written = (statistics["Bytes (Write)"] as? NSNumber)?.uint64Value ?? 0
            switch location(of: driver) {
            case "Internal":
                onboard = (onboard.read &+ read, onboard.written &+ written, onboard.count + 1)
            case "File", "Virtual Interface":
                continue
            default:
                elsewhere = (elsewhere.read &+ read, elsewhere.written &+ written, elsewhere.count + 1)
            }
        }
        if onboard.count > 0 { return (onboard.read, onboard.written) }
        if elsewhere.count > 0 { return (elsewhere.read, elsewhere.written) }
        return nil
    }

    /// Where the device under a driver is attached: "Internal", "External", "File" for a disk image.
    private static func location(of driver: io_registry_entry_t) -> String? {
        var device: io_registry_entry_t = 0
        guard IORegistryEntryGetParentEntry(driver, kIOServicePlane, &device) == KERN_SUCCESS else { return nil }
        defer { IOObjectRelease(device) }
        let characteristics =
            IORegistryEntryCreateCFProperty(device, "Protocol Characteristics" as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue()
            as? [String: Any]
        return characteristics?["Physical Interconnect Location"] as? String
    }
}
