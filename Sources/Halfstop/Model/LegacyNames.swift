import Foundation

/// The app used to be called Pixon. Moves data saved under the old name to the new one so
/// nothing is lost: settings, the library and presets, the thumbnail cache, and each photo
/// folder's hidden sidecar folder.
enum LegacyNames {
    static let sidecarFolder = ".pixon"
    private static let appFolder = "Pixon"
    private static let defaultsDomains = ["dev.pixon.app", "Pixon"]
    private static let migratedKey = "migratedFromPixon"

    /// Run once at launch, before the library or any settings are read.
    static func migrateAppData() {
        let fm = FileManager.default
        for base in [fm.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0],
                     fm.urls(for: .cachesDirectory, in: .userDomainMask)[0]] {
            moveIfNew(from: base.appendingPathComponent(appFolder, isDirectory: true),
                      to: base.appendingPathComponent("Halfstop", isDirectory: true))
        }

        let defaults = UserDefaults.standard
        guard !defaults.bool(forKey: migratedKey) else { return }
        for domain in defaultsDomains {
            for (key, value) in defaults.persistentDomain(forName: domain) ?? [:] where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: migratedKey)
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var checkedFolders = Set<String>()

    /// Renames `<folder>/.pixon` to the current sidecar folder, once per folder per launch.
    /// If both exist (an old version ran after the rename), the newer folder is kept as is.
    static func migrateSidecars(in folder: URL, to newFolder: URL) {
        lock.lock()
        let isNew = checkedFolders.insert(folder.path).inserted
        lock.unlock()
        guard isNew else { return }
        moveIfNew(from: folder.appendingPathComponent(sidecarFolder, isDirectory: true), to: newFolder)
    }

    private static func moveIfNew(from old: URL, to new: URL) {
        let fm = FileManager.default
        guard fm.fileExists(atPath: old.path), !fm.fileExists(atPath: new.path) else { return }
        try? fm.moveItem(at: old, to: new)
    }
}
