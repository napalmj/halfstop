import Foundation

/// What an import would bring in, worked out before anything is changed.
struct ImportScan: Sendable {
    var folder: URL
    var includeSubfolders: Bool
    /// All photo files found (relative paths).
    var files: [String]
    /// Files the library already references at this exact location.
    var alreadyInLibrary: Set<String>
    /// Files whose content matches a photo already in the library (or an earlier file in this scan).
    var duplicates: Set<String>
    /// Fingerprints of scanned files, by relative path.
    var fingerprints: [String: String]
    /// Folder lies inside a folder already imported with subfolders.
    var coveredBy: String?

    func newFiles(skipDuplicates: Bool) -> [String] {
        files.filter { !alreadyInLibrary.contains($0) && !(skipDuplicates && duplicates.contains($0)) }
    }
}

struct ImportOptions {
    var skipDuplicates = true
    var preset: Preset?
    var rename: RenamePattern?
    var customName = ""
    var collection: UUID?
}

struct ImportResult {
    var imported = 0
    var skipped = 0
    var renamed = 0
    var errors: [String] = []
}

extension LibraryStore {
    /// Looks at a folder and reports what importing it would do. Runs off the main thread.
    func scanForImport(_ folder: URL, includeSubfolders: Bool) async -> ImportScan {
        let root = LibraryFiles.canonical(folder)
        let libraryURLs = Set(photos.map { LibraryFiles.canonical($0.url) })
        let libraryPhotos = photos.map { ($0.ref.key, $0.url) }
        let knownPrints = catalog.fingerprints
        let covering = catalog.folders.first { f in
            f.includeSubfolders && (root == f.path || root.hasPrefix(f.path + "/"))
        }?.name

        let (scan, computed) = await Task.detached(priority: .userInitiated) { () -> (ImportScan, [String: String]) in
            // Make sure every library photo has a fingerprint to compare against.
            var prints = knownPrints
            var computed: [String: String] = [:]
            for (key, url) in libraryPhotos where prints[key] == nil {
                if let fp = LibraryFiles.fingerprint(url) { prints[key] = fp; computed[key] = fp }
            }
            let libraryValues = Set(prints.values)
            let files = LibraryFiles.enumerate(URL(fileURLWithPath: root), recursive: includeSubfolders)
            var already = Set<String>(), dups = Set<String>(), seen = Set<String>()
            var fps: [String: String] = [:]
            for rel in files {
                let url = URL(fileURLWithPath: root).appendingPathComponent(rel)
                if libraryURLs.contains(url.path) { already.insert(rel); continue }
                guard let fp = LibraryFiles.fingerprint(url) else { continue }
                fps[rel] = fp
                if libraryValues.contains(fp) || seen.contains(fp) { dups.insert(rel) }
                seen.insert(fp)
            }
            let scan = ImportScan(folder: URL(fileURLWithPath: root), includeSubfolders: includeSubfolders, files: files,
                                  alreadyInLibrary: already, duplicates: dups, fingerprints: fps, coveredBy: nil)
            return (scan, computed)
        }.value
        catalog.fingerprints.merge(computed) { _, new in new }
        var result = scan
        result.coveredBy = covering
        return result
    }

    /// Adds the scanned folder to the library: excludes duplicates, renames files, applies a preset,
    /// files the photos into a collection, and records it as the last import.
    func performImport(_ scan: ImportScan, options: ImportOptions) async -> ImportResult {
        flushSaves()
        var result = ImportResult()
        let root = LibraryFiles.canonical(scan.folder)
        var newFiles = scan.newFiles(skipDuplicates: options.skipDuplicates)
        result.skipped = scan.files.count - newFiles.count

        // Reuse the catalog entry when this exact folder was imported before.
        let folderID: UUID
        if let i = catalog.folders.firstIndex(where: { $0.path == root }) {
            folderID = catalog.folders[i].id
            catalog.folders[i].includeSubfolders = catalog.folders[i].includeSubfolders || scan.includeSubfolders
            if options.skipDuplicates { catalog.folders[i].excluded.formUnion(scan.duplicates) }
            // Previously excluded files the user now wants back.
            catalog.folders[i].excluded.subtract(newFiles)
        } else {
            var f = CatalogFolder(path: root, includeSubfolders: scan.includeSubfolders)
            if options.skipDuplicates { f.excluded = scan.duplicates }
            folderID = f.id
            catalog.folders.append(f)
        }

        // Rename on disk (photo + sidecar), off the main thread.
        var renames: [RenameRecord] = []
        if let pattern = options.rename, !newFiles.isEmpty {
            let files = newFiles
            let customName = options.customName
            let (done, errors) = await Task.detached(priority: .userInitiated) { () -> ([RenameRecord], [String]) in
                let dated = files.map { (path: $0, date: LibraryFiles.captureDate(URL(fileURLWithPath: root).appendingPathComponent($0))) }
                let plan = RenamePattern.plan(dated, pattern: pattern, customName: customName)
                return LibraryStore.applyRenames(plan, in: root)
            }.value
            renames = done
            result.errors += errors
            let map = Dictionary(done.map { ($0.from, $0.to) }, uniquingKeysWith: { a, _ in a })
            newFiles = newFiles.map { map[$0] ?? $0 }
        }
        result.renamed = renames.count
        let renamedFrom = Dictionary(renames.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })

        // Fingerprints under the final names.
        let refs = newFiles.map { PhotoRef(folder: folderID, path: $0) }
        for ref in refs {
            if let fp = scan.fingerprints[renamedFrom[ref.path] ?? ref.path] { catalog.fingerprints[ref.key] = fp }
        }

        // Preset: written straight into the sidecars before the photos load.
        if let preset = options.preset {
            let urls = newFiles.map { URL(fileURLWithPath: root).appendingPathComponent($0) }
            await Task.detached(priority: .userInitiated) {
                let decoder = JSONDecoder()
                for url in urls {
                    var sidecar = (try? Data(contentsOf: LibraryStore.sidecarURL(for: url))).flatMap { try? decoder.decode(Sidecar.self, from: $0) } ?? Sidecar()
                    sidecar.adjustments = preset.adjustments.asPreset(onto: sidecar.adjustments)
                    LibraryStore.writeSidecar(sidecar, for: url)
                }
            }.value
        }

        if let id = options.collection, let i = catalog.collections.firstIndex(where: { $0.id == id }) {
            let existing = Set(catalog.collections[i].members)
            catalog.collections[i].members += refs.filter { !existing.contains($0) }
        }
        catalog.lastImport = ImportRecord(folder: folderID, refs: refs, renames: renames)
        result.imported = refs.count
        saveCatalog()

        await withCheckedContinuation { cont in
            reload { cont.resume() }
        }
        source = .lastImport
        mode = .library
        return result
    }

    /// Moves files (and their sidecars) to new names. Never overwrites; returns what actually moved.
    nonisolated static func applyRenames(_ plan: [String: String], in root: String) -> ([RenameRecord], [String]) {
        let fm = FileManager.default
        var done: [RenameRecord] = []
        var errors: [String] = []
        // Two phases through temporary names so swaps (a→b, b→a) can't collide.
        var staged: [(tmp: URL, from: String, to: String)] = []
        for (from, to) in plan.sorted(by: { $0.key < $1.key }) where from != to {
            let src = URL(fileURLWithPath: root).appendingPathComponent(from)
            let tmp = src.deletingLastPathComponent().appendingPathComponent(".pixon-rename-\(UUID().uuidString)")
            do {
                try fm.moveItem(at: src, to: tmp)
                staged.append((tmp, from, to))
            } catch {
                errors.append("\(from): \(error.localizedDescription)")
            }
        }
        for item in staged {
            var to = item.to
            var dest = URL(fileURLWithPath: root).appendingPathComponent(to)
            var n = 2
            while fm.fileExists(atPath: dest.path) {
                let base = (item.to as NSString).deletingPathExtension, ext = (item.to as NSString).pathExtension
                to = "\(base)-\(n)" + (ext.isEmpty ? "" : ".\(ext)")
                dest = URL(fileURLWithPath: root).appendingPathComponent(to)
                n += 1
            }
            do {
                try fm.moveItem(at: item.tmp, to: dest)
                let oldSidecar = sidecarURL(for: URL(fileURLWithPath: root).appendingPathComponent(item.from))
                if fm.fileExists(atPath: oldSidecar.path) {
                    try? fm.moveItem(at: oldSidecar, to: sidecarURL(for: dest))
                }
                done.append(RenameRecord(from: item.from, to: to))
            } catch {
                // Put it back where it was.
                try? fm.moveItem(at: item.tmp, to: URL(fileURLWithPath: root).appendingPathComponent(item.from))
                errors.append("\(item.from): \(error.localizedDescription)")
            }
        }
        return (done, errors)
    }

    var canRevertLastImportNames: Bool { !(catalog.lastImport?.renames.isEmpty ?? true) }

    /// Puts the last import's files back under their original names.
    func revertLastImportNames() async {
        guard var record = catalog.lastImport, !record.renames.isEmpty,
              let folder = catalog.folder(record.folder) else { return }
        flushSaves()
        let plan = Dictionary(record.renames.map { ($0.to, $0.from) }, uniquingKeysWith: { a, _ in a })
        let root = folder.path
        let (done, _) = await Task.detached { LibraryStore.applyRenames(plan, in: root) }.value
        for r in done {
            catalog.rename(PhotoRef(folder: record.folder, path: r.from), to: PhotoRef(folder: record.folder, path: r.to))
        }
        record = catalog.lastImport ?? record
        let reverted = Set(done.map(\.to))
        record.renames.removeAll { reverted.contains($0.from) }
        catalog.lastImport = record
        saveCatalog()
        photos = photos.filter { $0.ref.folder != record.folder }
        await withCheckedContinuation { cont in reload { cont.resume() } }
    }
}
