import Foundation
import Testing
@testable import TrashFreeCore

@Suite("StorageMedium")
struct StorageMediumTests {
    @Test("maps IOKit's Medium Type")
    func mapping() {
        #expect(StorageMedium.from(deviceCharacteristics: ["Medium Type": "Solid State"]) == .solidState)
        #expect(StorageMedium.from(deviceCharacteristics: ["Medium Type": "Rotational", "Rotation Rate": 5400]) == .rotational)
        #expect(StorageMedium.from(deviceCharacteristics: ["Product Name": "Disk Image"]) == .unknown)
        #expect(StorageMedium.from(deviceCharacteristics: nil) == .unknown)
    }

    @Test("only spinning disks get fewer threads")
    func workerCount() {
        #expect(StorageMedium.rotational.scanWorkerCount == 4)
        #expect(StorageMedium.solidState.scanWorkerCount == nil)
        #expect(StorageMedium.unknown.scanWorkerCount == nil)
    }

    @Test("the startup disk and folders on it are solid state")
    func startupDisk() {
        // Every Apple silicon Mac boots from internal flash.
        #expect(StorageMedium.of(volumeAt: URL(fileURLWithPath: "/")) == .solidState)
        #expect(StorageMedium.of(volumeAt: FileManager.default.temporaryDirectory) == .solidState)
    }
}
