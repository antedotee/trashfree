import DiskArbitration
import Foundation

/// A mounted volume the user can browse in Finder.
public struct Volume: Identifiable, Hashable {
    public enum Kind: Hashable {
        case startup
        case diskImage
        case external
        case network
        case internalDisk
    }

    public let url: URL
    public let name: String
    public let kind: Kind
    public let isEncrypted: Bool
    /// APFS volumes report their container's capacity, which is what the user thinks of
    /// as the disk size.
    public let totalBytes: Int64
    public let freeBytes: Int64
    public let freeIncludingPurgeableBytes: Int64

    public var id: String { url.path }
    public var usedBytes: Int64 { max(totalBytes - freeBytes, 0) }
    public var usedFraction: Double { totalBytes > 0 ? Double(usedBytes) / Double(totalBytes) : 0 }

    public var kindDescription: String {
        let base: String
        switch kind {
        case .startup: base = "startup disk"
        case .diskImage: return "disk image"
        case .external: base = "external disk"
        case .network: return "network volume"
        case .internalDisk: base = "disk"
        }
        return isEncrypted ? "encrypted \(base)" : base
    }

    /// Volumes Finder shows in its sidebar. `skipHiddenVolumes` drops the APFS system
    /// volumes macOS mounts under /System/Volumes (VM, Preboot, Update, xART, iSCPreboot,
    /// Hardware) and autofs mounts, which were flooding the disk list.
    public static func browsable() -> [Volume] {
        let urls = FileManager.default.mountedVolumeURLs(
            includingResourceValuesForKeys: Array(resourceKeys),
            options: [.skipHiddenVolumes]
        ) ?? []
        let session = DASessionCreate(kCFAllocatorDefault)
        let volumes = urls.compactMap { Volume(url: $0, session: session) }
        return volumes.filter { $0.kind == .startup } + volumes.filter { $0.kind != .startup }
    }

    /// The same volume with fresh capacity numbers, e.g. after deleting files.
    public func refreshed() -> Volume? {
        Volume(url: url, session: DASessionCreate(kCFAllocatorDefault))
    }

    private static let resourceKeys: Set<URLResourceKey> = [
        .volumeNameKey,
        .volumeIsBrowsableKey,
        .volumeIsRootFileSystemKey,
        .volumeIsLocalKey,
        .volumeIsInternalKey,
        .volumeIsEjectableKey,
        .volumeIsRemovableKey,
        .volumeTotalCapacityKey,
        .volumeAvailableCapacityKey,
        .volumeAvailableCapacityForImportantUsageKey,
    ]

    private init?(url: URL, session: DASession?) {
        guard let values = try? url.resourceValues(forKeys: Self.resourceKeys),
              values.volumeIsBrowsable ?? true,
              let total = values.volumeTotalCapacity, total > 0
        else { return nil }

        let isRoot = values.volumeIsRootFileSystem ?? (url.path == "/")
        self.url = url
        self.name = values.volumeName ?? (isRoot ? "Macintosh HD" : url.lastPathComponent)
        self.totalBytes = Int64(total)
        self.freeBytes = Int64(values.volumeAvailableCapacity ?? 0)
        self.freeIncludingPurgeableBytes = max(values.volumeAvailableCapacityForImportantUsage ?? 0, freeBytes)

        if isRoot {
            kind = .startup
            // The sealed system snapshot at / is never encrypted; the user's data lives on
            // the Data volume, which Apple silicon encrypts even with FileVault off.
            isEncrypted = Self.isEncrypted(URL(fileURLWithPath: "/System/Volumes/Data"), session: session)
        } else if !(values.volumeIsLocal ?? true) {
            kind = .network
            isEncrypted = false
        } else if Self.isDiskImage(url, session: session) {
            kind = .diskImage
            isEncrypted = Self.isEncrypted(url, session: session)
        } else if values.volumeIsInternal == false || values.volumeIsEjectable == true || values.volumeIsRemovable == true {
            kind = .external
            isEncrypted = Self.isEncrypted(url, session: session)
        } else {
            kind = .internalDisk
            isEncrypted = Self.isEncrypted(url, session: session)
        }
    }

    private static func description(of url: URL, session: DASession?) -> [CFString: Any]? {
        guard let session, let disk = DADiskCreateFromVolumePath(kCFAllocatorDefault, session, url as CFURL) else { return nil }
        return DADiskCopyDescription(disk) as? [CFString: Any]
    }

    private static func isEncrypted(_ url: URL, session: DASession?) -> Bool {
        description(of: url, session: session)?[kDADiskDescriptionMediaEncryptedKey] as? Bool ?? false
    }

    private static func isDiskImage(_ url: URL, session: DASession?) -> Bool {
        guard let description = description(of: url, session: session) else { return false }
        let model = description[kDADiskDescriptionDeviceModelKey] as? String ?? ""
        let transport = description[kDADiskDescriptionDeviceProtocolKey] as? String ?? ""
        return model.contains("Disk Image") || transport == "Virtual Interface"
    }
}
