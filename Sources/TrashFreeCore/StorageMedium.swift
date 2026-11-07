import DiskArbitration
import Foundation
import IOKit

/// Whether a volume sits on a spinning disk. Many threads listing folders at once make a
/// disk head seek back and forth, so spinning disks are scanned with fewer threads
/// (they are scanned with 4 threads).
public enum StorageMedium: Equatable {
    case solidState
    case rotational
    case unknown

    /// Threads to scan with: nil for the default, a small number for spinning disks.
    public var scanWorkerCount: Int? { self == .rotational ? 4 : nil }

    /// Reads IOKit's "Device Characteristics" dictionary of the storage device holding the
    /// volume at `url`.
    /// `url` may be any folder; the medium is that of the volume it lives on.
    public static func of(volumeAt url: URL) -> StorageMedium {
        var info = statfs()
        guard statfs(url.path, &info) == 0 else { return .unknown }
        let mountPoint = withUnsafeBytes(of: info.f_mntonname) { String(cString: $0.bindMemory(to: CChar.self).baseAddress!) }
        let volume = URL(fileURLWithPath: mountPoint, isDirectory: true)
        guard let session = DASessionCreate(kCFAllocatorDefault),
              let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, volume as CFURL) else { return .unknown }
        let media = DADiskCopyIOMedia(disk)
        guard media != IO_OBJECT_NULL else { return .unknown }
        defer { IOObjectRelease(media) }
        let characteristics = IORegistryEntrySearchCFProperty(
            media, kIOServicePlane, "Device Characteristics" as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents))
        return from(deviceCharacteristics: characteristics as? [String: Any])
    }

    /// Maps the IOKit dictionary. APFS volumes and disk images sit on virtual devices
    /// without one, so a missing value is `.unknown`, which scans like solid state.
    public static func from(deviceCharacteristics: [String: Any]?) -> StorageMedium {
        switch deviceCharacteristics?["Medium Type"] as? String {
        case "Solid State": return .solidState
        case "Rotational": return .rotational
        default: return .unknown
        }
    }
}
