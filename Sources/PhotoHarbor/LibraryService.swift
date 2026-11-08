import Foundation
import CryptoKit
import CoreLocation
import MapKit
import Darwin

struct LibraryService {
    static let manager = FileManager.default
    static func scanFiles(_ root: URL, extensions: Set<String>, includeIdentity: Bool = true,
                          deletionKeys: Set<String>? = nil, fallbackStems: Set<String> = []) throws -> [PhotoFile] {
        let root = canonicalURL(root)
        var relevantDirectories: Set<String> = []
        if let deletionKeys, fallbackStems.isEmpty {
            for key in deletionKeys {
                var directory = (key as NSString).deletingLastPathComponent
                while !directory.isEmpty {
                    relevantDirectories.insert(directory)
                    directory = (directory as NSString).deletingLastPathComponent
                }
            }
        }
        var keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        let rootVolume = includeIdentity ? (try? root.resourceValues(forKeys: [.volumeIdentifierKey]).volumeIdentifier) : nil
        let rootDevice = rootVolume != nil ? (try? manager.attributesOfItem(atPath: root.path)[.systemNumber] as? NSNumber) : nil
        if rootDevice != nil { keys.formUnion([.fileIdentifierKey, .creationDateKey, .volumeIdentifierKey]) }
        var useEnumeratedIdentity: Bool?
        var failure: Error?
        guard let iterator = manager.enumerator(at: root, includingPropertiesForKeys: Array(keys), options: [.skipsHiddenFiles], errorHandler: { _, error in failure = error; return false }) else { throw LibraryError.message("无法读取目录：\(root.path)") }
        var files: [PhotoFile] = []
        for case let enumeratedURL as URL in iterator {
            try Task.checkCancellation()
            let url = enumeratedURL
            let values = try url.resourceValues(forKeys: keys)
            if values.isSymbolicLink == true { iterator.skipDescendants(); continue }
            let relative = String(url.path.dropFirst(root.path.count + 1))
            if let deletionKeys {
                if values.isDirectory == true, fallbackStems.isEmpty,
                   !relevantDirectories.contains(relative.lowercased()) {
                    iterator.skipDescendants()
                }
                let relativeStem = (relative as NSString).deletingPathExtension.lowercased()
                let stem = (relativeStem as NSString).lastPathComponent
                guard deletionKeys.contains(relativeStem) || fallbackStems.contains(stem) else { continue }
            }
            guard values.isRegularFile == true, extensions.contains(url.pathExtension.lowercased()) else { continue }
            var identity = ""
            if includeIdentity {
                let enumerated: String?
                if let rootDevice, let rootVolume, let volume = values.volumeIdentifier, rootVolume.isEqual(volume),
                   let inode = values.fileIdentifier, inode != 0, let created = values.creationDate {
                    enumerated = "\(rootDevice):\(inode):\(created)"
                } else {
                    enumerated = nil
                }
                if useEnumeratedIdentity == true, let enumerated {
                    identity = enumerated
                } else {
                    let attributes = try manager.attributesOfItem(atPath: url.path)
                    identity = "\(attributes[.systemNumber] ?? ""):\(attributes[.systemFileNumber] ?? ""):\(attributes[.creationDate] ?? "")"
                    if useEnumeratedIdentity == nil, let enumerated {
                        useEnumeratedIdentity = enumerated == identity
                    }
                }
            }
            files.append(PhotoFile(url: url, relative: relative, bytes: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast, identity: identity))
        }
        if let failure { throw failure }
        return files.sorted { $0.relative.localizedStandardCompare($1.relative) == .orderedAscending }
    }
    static func scan(_ roots: Roots) throws -> [Photo] {
        try roots.validate()
        return pair(jpg: try roots.jpgURL.map { try scanFiles($0, extensions: ["jpg", "jpeg"]) } ?? [], raw: try roots.rawURL.map { try scanFiles($0, extensions: ["arw"]) } ?? [])
    }
    static func scanForBrowsing(_ roots: Roots, parallelFormats: Bool) async throws -> [Photo] {
        guard parallelFormats, !roots.jpg.isEmpty, !roots.raw.isEmpty else { return try scan(roots) }
        try roots.validate()
        async let jpg = roots.jpgURL.map { try scanFiles($0, extensions: ["jpg", "jpeg"]) } ?? []
        async let raw = roots.rawURL.map { try scanFiles($0, extensions: ["arw"]) } ?? []
        return try await pair(jpg: jpg, raw: raw)
    }
    static func discoverAlbumFolders(_ roots: Roots) throws -> [OpenAlbum] {
        try roots.validate()
        func children(_ root: URL?, extensions: Set<String>) throws -> ([String: URL], Bool) {
            guard let root else { return ([:], false) }
            let keys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]
            var folders: [String: URL] = [:]
            var hasLoosePhotos = false
            for entry in try manager.contentsOfDirectory(at: root, includingPropertiesForKeys: Array(keys), options: .skipsHiddenFiles) {
                let values = try entry.resourceValues(forKeys: keys)
                guard values.isSymbolicLink != true else { continue }
                if values.isDirectory == true {
                    folders[entry.lastPathComponent] = entry
                } else if values.isRegularFile == true, extensions.contains(entry.pathExtension.lowercased()) {
                    hasLoosePhotos = true
                }
            }
            return (folders, hasLoosePhotos)
        }
        let (jpg, looseJPG) = try children(roots.jpgURL, extensions: ["jpg", "jpeg"])
        let (raw, looseRAW) = try children(roots.rawURL, extensions: ["arw"])
        let names = Set(jpg.keys).union(raw.keys).sorted { $0.localizedStandardCompare($1) == .orderedAscending }
        guard !names.isEmpty else { return [OpenAlbum(roots: roots)] }
        guard !looseJPG, !looseRAW else {
            throw LibraryError.message("所选目录同时包含直属照片和子目录。请关闭「按子目录打开相册」以浏览全部照片，或单独选择要打开的子目录。")
        }
        return names.map { name in
            OpenAlbum(roots: Roots(jpg: jpg[name]?.path ?? "", raw: raw[name]?.path ?? ""), title: name)
        }
    }
    static func pair(jpg: [PhotoFile], raw: [PhotoFile]) -> [Photo] {
        let jRelative = Dictionary(grouping: jpg, by: \.relativeStem)
        let rRelative = Dictionary(grouping: raw, by: \.relativeStem)
        var consumed = Set<URL>(); var output: [Photo] = []
        for key in jRelative.keys.sorted() {
            if let j = jRelative[key], j.count == 1, let r = rRelative[key], r.count == 1 {
                output.append(Photo(files: j + r)); (j + r).forEach { consumed.insert($0.url) }
            }
        }
        let remaining = (jpg + raw).filter { !consumed.contains($0.url) }
        let grouped = Dictionary(grouping: remaining, by: \.stem)
        for key in grouped.keys.sorted() {
            let group = grouped[key]!
            let j = group.filter { !$0.isRAW }; let r = group.filter(\.isRAW)
            if j.count == 1 && r.count == 1 { output.append(Photo(files: j + r)) }
            else { output += group.map { Photo(files: [$0], ambiguous: group.count > 1) } }
        }
        return output.sorted { $0.files[0].relative.localizedStandardCompare($1.files[0].relative) == .orderedAscending }
    }
    enum ImportConflictChoice: String, CaseIterable, Sendable {
        case skip = "跳过"
        case keepBoth = "保留两者"
        case replace = "替换已有文件"
    }

    static func importPlan(source: URL, roots: Roots, location: String, resolvedPlaces: [String: String] = [:], allowExisting: Bool = false) throws -> [ImportItem] {
        let request = try validateImportRequest(sources: [source], roots: roots, location: location)
        var input = try makeImportInput(request, scans: request.sources.map(scanImportSource))
        let formatter = Metadata.captureDateFormatter()
        for photo in input.photos {
            input.metadata[photo.preview] = readImportMetadata(photo, needsLocation: input.place.isEmpty, formatter: formatter)
        }
        try Task.checkCancellation()
        var destinations = ImportDestinationIndex()
        return try buildImportPlan(input, resolvedPlaces: resolvedPlaces, allowExisting: allowExisting, index: &destinations)
    }

    private struct ImportInput: Sendable {
        let roots: Roots
        let place: String
        let photos: [Photo]
        var metadata: [URL: [Metadata]] = [:]
        let multipleSources: Bool
    }

    private struct ImportRequest: Sendable {
        let roots: Roots
        let place: String
        let sources: [URL]
    }

    private struct ImportScan: Sendable {
        let photos: [Photo]
        let issues: [String]
    }

    private static func validateImportRequest(sources: [URL], roots: Roots, location: String) throws -> ImportRequest {
        let roots = Roots.importDestinations(jpg: roots.jpg, raw: roots.raw)
        try roots.validate(allowMissing: true)
        let sources = sources.map(canonicalURL)
        guard !sources.isEmpty else { throw LibraryError.message("请选择来源文件夹。") }
        let destinationRoots = roots.urls
        var pathIssues: [String] = []
        for (index, source) in sources.enumerated() {
            for earlier in sources.prefix(index) where pathsOverlap(earlier, source) {
                pathIssues.append("来源文件夹重复或互相包含：\n  \(earlier.path)\n  \(source.path)")
            }
            for root in destinationRoots where pathsOverlap(root, source) {
                pathIssues.append("来源与存放位置相同或互相包含：\n  来源：\(source.path)\n  目标：\(root.path)")
            }
        }
        if !pathIssues.isEmpty {
            throw LibraryError.message("发现 \(pathIssues.count) 处路径冲突。请调整来源或存放位置后重新预览。\n\n" + pathIssues.joined(separator: "\n\n"))
        }
        let place = location.trimmingCharacters(in: .whitespacesAndNewlines)
        guard place != ".", place != "..", !place.contains("/"), !place.contains(":"), !place.contains("\n") else { throw LibraryError.message("地点不能包含斜杠、冒号或换行。") }
        return ImportRequest(roots: roots, place: place, sources: sources)
    }

    private static func scanImportSource(_ source: URL) throws -> ImportScan {
        do {
            let files = try scanFiles(source, extensions: ["jpg", "jpeg", "arw"], includeIdentity: false)
            let paired = pair(jpg: files.filter { !$0.isRAW }, raw: files.filter(\.isRAW))
            let ambiguous = Dictionary(grouping: paired.filter(\.ambiguous).flatMap(\.files), by: \.stem)
            let issues = ambiguous.keys.sorted().compactMap { stem -> String? in
                guard let files = ambiguous[stem], let first = files.first else { return nil }
                let name = first.url.deletingPathExtension().lastPathComponent
                let rawCount = files.filter(\.isRAW).count
                let paths = files.map { "  " + $0.url.path }.sorted().joined(separator: "\n")
                return "\(name) 无法唯一配对（\(files.count - rawCount) 个 JPG、\(rawCount) 个 ARW）\n来源：\(source.path)\n\(paths)"
            }
            return ImportScan(photos: paired, issues: issues)
        } catch {
            try Task.checkCancellation()
            return ImportScan(photos: [], issues: ["无法读取来源：\(source.path)\n  \(error.localizedDescription)"])
        }
    }

    private static func makeImportInput(_ request: ImportRequest, scans: [ImportScan]) throws -> ImportInput {
        let issues = scans.flatMap(\.issues)
        if !issues.isEmpty {
            let details = issues.enumerated().map { "\($0.offset + 1). \($0.element)" }.joined(separator: "\n\n")
            throw LibraryError.message("发现 \(issues.count) 组来源问题，尚未复制任何文件。请检查无法读取的目录，并分开导入或重命名无法配对的文件，再重新预览。\n\n" + details)
        }
        let photos = scans.flatMap(\.photos)
        if request.roots.jpg.isEmpty, photos.contains(where: { $0.files.contains { !$0.isRAW } }) {
            throw LibraryError.message("来源包含 JPG 文件，请设置对应的导入位置。")
        }
        if request.roots.raw.isEmpty, photos.contains(where: { $0.files.contains(where: \.isRAW) }) {
            throw LibraryError.message("来源包含 RAW 文件，请设置对应的导入位置。")
        }
        return ImportInput(roots: request.roots, place: request.place, photos: photos, multipleSources: request.sources.count > 1)
    }

    private static func readImportMetadata(_ photo: Photo, needsLocation: Bool, formatter: DateFormatter) -> [Metadata] {
        var result: [Metadata] = []
        for file in photo.files.sorted(by: { !$0.isRAW && $1.isRAW }) {
            let metadata = Metadata.read(file.url, importFormatter: formatter)
            result.append(metadata)
            if result.contains(where: { $0.date != nil }),
               !needsLocation || result.contains(where: { !$0.place.isEmpty }) {
                break
            }
        }
        return result
    }

    private struct ImportDestinationIndex {
        private enum Listing {
            case names(exact: Set<String>, folded: Set<String>)
            case unavailable
        }
        private var listings: [URL: Listing] = [:]

        mutating func contains(_ url: URL) -> Bool {
            let parent = url.deletingLastPathComponent()
            if listings[parent] == nil {
                do {
                    let names = try manager.contentsOfDirectory(atPath: parent.path)
                    listings[parent] = .names(exact: Set(names), folded: Set(names.map { $0.precomposedStringWithCanonicalMapping.lowercased() }))
                } catch let error as NSError {
                    if error.domain == NSCocoaErrorDomain && [NSFileNoSuchFileError, NSFileReadNoSuchFileError].contains(error.code) {
                        listings[parent] = .names(exact: [], folded: [])
                    } else {
                        listings[parent] = .unavailable
                    }
                }
            }
            if case .names(let exact, let folded) = listings[parent] {
                let name = url.lastPathComponent
                if exact.contains(name) { return true }
                if !folded.contains(name.precomposedStringWithCanonicalMapping.lowercased()) { return false }
            }
            // Case variants need a direct check on case-sensitive volumes.
            return importDestinationExists(url)
        }
    }

    private static func pathsOverlap(_ lhs: URL, _ rhs: URL) -> Bool {
        lhs.pathComponents.starts(with: rhs.pathComponents) || rhs.pathComponents.starts(with: lhs.pathComponents)
    }

    private static func buildImportPlan(_ input: ImportInput, resolvedPlaces: [String: String], allowExisting: Bool, index: inout ImportDestinationIndex) throws -> [ImportItem] {
        try Task.checkCancellation()
        let jpgRoot = input.roots.jpgURL
        let rawRoot = input.roots.rawURL
        let place = input.place
        let day = DateFormatter(); day.locale = Locale(identifier: "en_US_POSIX"); day.dateFormat = "yyyyMMdd"
        var plan: [ImportItem] = []; var destinations = Set<String>()
        for photo in input.photos {
            try Task.checkCancellation()
            let metadata = input.metadata[photo.preview] ?? []
            let captureDate = metadata.compactMap(\.date).first
            let date = captureDate ?? photo.files.first(where: { !$0.isRAW })?.modified ?? photo.files[0].modified
            let detected = metadata.map(\.place).first(where: { !$0.isEmpty }) ?? resolvedPlaces[photo.preview.path] ?? "未知"
            let folderPlace = place.isEmpty ? safePlace(detected) : place
            let folderName = "\(day.string(from: date))_\(folderPlace)"
            for file in photo.files {
                guard let root = file.isRAW ? rawRoot : jpgRoot else { throw LibraryError.message("来源包含\(file.isRAW ? "RAW" : "JPG") 文件，请设置对应的导入位置。") }
                let dest = root.appendingPathComponent(folderName, isDirectory: true).appendingPathComponent(file.url.lastPathComponent, isDirectory: false)
                let conflict = index.contains(dest)
                guard destinations.insert(dest.path.lowercased()).inserted || input.multipleSources, allowExisting || !conflict else { throw LibraryError.message("目标文件重名，未执行导入：\(dest.path)") }
                plan.append(ImportItem(source: file.url, destination: dest, bytes: file.bytes, fallbackDate: captureDate == nil, pairID: photo.preview.path, conflicts: conflict,
                                       conflictVersion: conflict ? try? importFileVersion(dest, replacing: true) : nil))
            }
        }
        return input.multipleSources ? try uniqueBatchDestinations(plan, index: &index) : plan
    }
    static func safePlace(_ value: String) -> String {
        let cleaned = value.components(separatedBy: CharacterSet(charactersIn: "/:\\").union(.controlCharacters)).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
        return cleaned.isEmpty || cleaned == "." || cleaned == ".." ? "未知" : String(cleaned.prefix(80))
    }
    static func importPlanResolvingPlaces(sources: [URL], roots: Roots, location: String, lookupGPS: Bool = true) async throws -> [ImportItem] {
        try Task.checkCancellation()
        let request = try validateImportRequest(sources: sources, roots: roots, location: location)
        let scans = try await withThrowingTaskGroup(of: (Int, ImportScan).self) { group in
            var ordered = Array<ImportScan?>(repeating: nil, count: request.sources.count)
            for index in 0..<min(3, request.sources.count) {
                group.addTask {
                    try Task.checkCancellation()
                    return (index, try scanImportSource(request.sources[index]))
                }
            }
            var next = min(3, request.sources.count)
            while let (index, scan) = try await group.next() {
                try Task.checkCancellation()
                ordered[index] = scan
                if next < request.sources.count {
                    let index = next
                    next += 1
                    group.addTask {
                        try Task.checkCancellation()
                        return (index, try scanImportSource(request.sources[index]))
                    }
                }
            }
            return ordered.compactMap { $0 }
        }
        var input = try makeImportInput(request, scans: scans)
        let photos = input.photos
        let needsLocation = input.place.isEmpty
        let workerCount = min(4, photos.count)
        input.metadata = try await withThrowingTaskGroup(of: [URL: [Metadata]].self) { group in
            for worker in 0..<workerCount {
                group.addTask {
                    var result: [URL: [Metadata]] = [:]
                    let formatter = Metadata.captureDateFormatter()
                    for index in stride(from: worker, to: photos.count, by: workerCount) {
                        try Task.checkCancellation()
                        let photo = photos[index]
                        result[photo.preview] = readImportMetadata(photo, needsLocation: needsLocation, formatter: formatter)
                    }
                    return result
                }
            }
            var result: [URL: [Metadata]] = [:]
            for try await metadata in group {
                result.merge(metadata) { current, _ in current }
            }
            return result
        }
        var destinations = ImportDestinationIndex()
        if !input.place.isEmpty || !lookupGPS {
            return try buildImportPlan(input, resolvedPlaces: [:], allowExisting: true, index: &destinations)
        }
        var places: [String: String] = [:], cache: [String: String] = [:]
        var lookupUnavailable = false
        for photo in input.photos {
            try Task.checkCancellation()
            let metadata = input.metadata[photo.preview] ?? []
            guard !metadata.contains(where: { !$0.place.isEmpty }),
                  let gps = metadata.first(where: { $0.latitude != nil && $0.longitude != nil }),
                  let lat = gps.latitude, let lon = gps.longitude,
                  CLLocationCoordinate2DIsValid(CLLocationCoordinate2D(latitude: lat, longitude: lon)) else { continue }
            let key = String(format: "%.2f,%.2f", lat, lon)
            if let cached = cache[key] { places[photo.preview.path] = cached; continue }
            if lookupUnavailable { continue }
            do {
                let name = try await reversePlace(CLLocation(latitude: lat, longitude: lon))
                cache[key] = name.isEmpty ? "未知" : name
                places[photo.preview.path] = cache[key]
            } catch {
                try Task.checkCancellation()
                lookupUnavailable = true
            }
        }
        return try buildImportPlan(input, resolvedPlaces: places, allowExisting: true, index: &destinations)
    }
    @MainActor private static func reversePlace(_ location: CLLocation) async throws -> String {
        let locale = Locale(identifier: "zh_CN")
        if #available(macOS 26.0, *), let request = MKReverseGeocodingRequest(location: location) {
            request.preferredLocale = locale
            return try await withGeocodeTimeout(cancel: { request.cancel() }) {
                try await request.mapItems.first?.addressRepresentations?.cityName ?? ""
            }
        }
        let geocoder = CLGeocoder()
        return try await withGeocodeTimeout(cancel: { geocoder.cancelGeocode() }) {
            let mark = try await geocoder.reverseGeocodeLocation(location, preferredLocale: locale).first
            return [mark?.locality ?? mark?.administrativeArea, mark?.subLocality].compactMap { $0 }.joined()
        }
    }

    @MainActor private static func withGeocodeTimeout(cancel: @escaping @MainActor @Sendable () -> Void,
                                                      lookup: () async throws -> String) async throws -> String {
        let timeout = Task {
            try await Task.sleep(nanoseconds: 8_000_000_000)
            cancel()
        }
        defer { timeout.cancel() }
        return try await withTaskCancellationHandler {
            try Task.checkCancellation()
            return try await lookup()
        } onCancel: {
            Task { @MainActor in cancel() }
        }
    }

    static func digest(_ url: URL, chunkSize: Int = 1024 * 1024) throws -> SHA256.Digest {
        let handle = try FileHandle(forReadingFrom: url); defer { try? handle.close() }
        var hash = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty { hash.update(data: chunk) }
        return hash.finalize()
    }
    private static func importDestinationExists(_ url: URL) -> Bool {
        manager.fileExists(atPath: url.path) || (try? manager.destinationOfSymbolicLink(atPath: url.path)) != nil
    }

    private static func importFileVersion(_ url: URL, replacing: Bool = false) throws -> String {
        var info = stat()
        guard canonicalURL(url).path == url.path, lstat(url.path, &info) == 0,
              info.st_mode & S_IFMT == S_IFREG,
              !replacing || (info.st_ino != 0 && (info.st_ctimespec.tv_sec != 0 || info.st_ctimespec.tv_nsec != 0)) else {
            throw LibraryError.message("无法核验导入文件的版本，请检查文件和存储设备。")
        }
        let modified = info.st_mtimespec, changed = info.st_ctimespec
        return "\(info.st_dev):\(info.st_ino):\(info.st_size):\(modified.tv_sec):\(modified.tv_nsec):\(changed.tv_sec):\(changed.tv_nsec)"
    }

    // Album name and stem form the pairing key even when the two formats live in different roots.
    private static func importStem(_ item: ImportItem) -> String {
        let url = item.destination
        return (url.deletingLastPathComponent().lastPathComponent + "/" + url.deletingPathExtension().lastPathComponent).lowercased()
    }

    private static func uniqueBatchDestinations(_ plan: [ImportItem], index: inout ImportDestinationIndex) throws -> [ImportItem] {
        let groups = Dictionary(grouping: plan) { $0.pairID ?? $0.id }
        var reserved = Set(plan.map(importStem))
        var visited = Set<String>()
        var used = Set<String>()
        var result: [ImportItem] = []
        for item in plan {
            try Task.checkCancellation()
            let key = item.pairID ?? item.id
            guard visited.insert(key).inserted, let group = groups[key] else { continue }
            let stems = Set(group.map(importStem))
            if used.isDisjoint(with: stems) {
                used.formUnion(stems)
                result += group
            } else {
                result += renamedImportGroup(group, reserved: &reserved, index: &index)
            }
        }
        return result
    }

    private static func renamedImportGroup(_ group: [ImportItem], reserved: inout Set<String>, index: inout ImportDestinationIndex) -> [ImportItem] {
        var suffix = 2
        while true {
            let renamed = group.map { item in
                var item = item
                let parent = item.destination.deletingLastPathComponent()
                let stem = item.destination.deletingPathExtension().lastPathComponent
                item.destination = parent.appendingPathComponent("\(stem) (\(suffix))").appendingPathExtension(item.destination.pathExtension)
                item.conflicts = false
                item.conflictVersion = nil
                return item
            }
            if renamed.allSatisfy({ !reserved.contains(importStem($0)) && !index.contains($0.destination) }) {
                reserved.formUnion(renamed.map(importStem))
                return renamed
            }
            suffix += 1
        }
    }

    static func resolveImportConflicts(_ plan: [ImportItem], choice: ImportConflictChoice) throws -> [ImportItem] {
        let groups = Dictionary(grouping: plan) { $0.pairID ?? $0.id }
        var reserved = Set(plan.map(importStem))
        var visited = Set<String>()
        var resolved: [ImportItem] = []
        var index = ImportDestinationIndex()
        for item in plan {
            let key = item.pairID ?? item.id
            guard visited.insert(key).inserted, let group = groups[key] else { continue }
            guard group.contains(where: \.conflicts) else { resolved += group; continue }
            switch choice {
            case .skip:
                continue
            case .replace:
                resolved += try group.map { item in
                    var item = item
                    if item.conflicts {
                        guard let version = item.conflictVersion, try importFileVersion(item.destination, replacing: true) == version else {
                            throw LibraryError.message("目标已变化或不能替换，请重新预览导入计划。")
                        }
                        item.replacement = version
                    }
                    return item
                }
            case .keepBoth:
                resolved += renamedImportGroup(group, reserved: &reserved, index: &index)
            }
        }
        return resolved
    }

    private static let importChunkSize = 4 * 1024 * 1024

    static func streamPhotoCopy(_ source: URL, to temporary: URL) throws -> SHA256.Digest {
        let sourceFD = Darwin.open(source.path, O_RDONLY | O_NOFOLLOW)
        guard sourceFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let input = FileHandle(fileDescriptor: sourceFD, closeOnDealloc: true)
        defer { try? input.close() }

        let destinationFD = Darwin.open(temporary.path, O_WRONLY | O_CREAT | O_EXCL, 0o600)
        guard destinationFD >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let output = FileHandle(fileDescriptor: destinationFD, closeOnDealloc: true)
        defer { try? output.close() }

        var hash = SHA256()
        while let chunk = try input.read(upToCount: importChunkSize), !chunk.isEmpty {
            try Task.checkCancellation()
            hash.update(data: chunk)
            try output.write(contentsOf: chunk)
        }
        // Preserve dates, permissions and extended attributes without recopying the data.
        guard fcopyfile(sourceFD, destinationFD, nil, copyfile_flags_t(COPYFILE_METADATA)) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
        try output.close()
        return hash.finalize()
    }

    struct PreparedImport: Sendable {
        let item: ImportItem
        let temporary: URL
        let sourceVersion: String

        func discard() { try? FileManager.default.removeItem(at: temporary) }
    }

    static func prepareVerifiedImport(_ item: ImportItem) throws -> PreparedImport {
        try Task.checkCancellation()
        let parent = item.destination.deletingLastPathComponent()
        guard canonicalURL(item.source).path == item.source.path, canonicalURL(parent).path == parent.path,
              item.source != item.destination else { throw LibraryError.message("来源或目标路径已变化，停止导入。") }
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        guard canonicalURL(parent).path == parent.path else { throw LibraryError.message("目标包含符号链接，停止导入。") }
        let temporary = parent.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: false)
        let sourceVersion = try importFileVersion(item.source)
        let prepared = PreparedImport(item: item, temporary: temporary, sourceVersion: sourceVersion)
        do {
            let expectedDigest = try streamPhotoCopy(item.source, to: temporary)
            try Task.checkCancellation()
            guard try digest(temporary, chunkSize: importChunkSize) == expectedDigest else {
                throw LibraryError.message("文件校验失败：\(item.source.lastPathComponent)")
            }
            try Task.checkCancellation()
            return prepared
        } catch {
            prepared.discard()
            throw error
        }
    }

    static func publishVerifiedImport(_ prepared: PreparedImport) throws {
        defer { prepared.discard() }
        let item = prepared.item
        let parent = item.destination.deletingLastPathComponent()
        guard try importFileVersion(item.source) == prepared.sourceVersion,
              canonicalURL(parent).path == parent.path else {
            throw LibraryError.message("来源或目标路径已变化，停止导入：\(item.source.lastPathComponent)")
        }
        if let expected = item.replacement {
            guard try importFileVersion(item.destination, replacing: true) == expected else {
                throw LibraryError.message("目标已变化，未替换：\(item.destination.lastPathComponent)")
            }
            _ = try manager.replaceItemAt(item.destination, withItemAt: prepared.temporary)
        } else {
            try manager.moveItem(at: prepared.temporary, to: item.destination)
        }
    }

    static func copyVerified(_ item: ImportItem) throws {
        try publishVerifiedImport(prepareVerifiedImport(item))
    }
    static func validateDeletion(_ photos: [Photo], roots: Roots) throws {
        try roots.validate()
        var exactKeys: Set<String> = []
        var fallbackStems: Set<String> = []
        for photo in photos {
            guard !photo.ambiguous, let first = photo.files.first else {
                throw LibraryError.message("照片配对存在歧义，请重新扫描后检查。")
            }
            if photo.paired, photo.files.allSatisfy({ $0.relativeStem == first.relativeStem }) {
                exactKeys.insert(first.relativeStem)
            } else {
                fallbackStems.insert(first.stem)
            }
        }
        // Exact pairs take precedence over matches elsewhere. Fallback pairing
        // needs every candidate with the same stem, including exact pairs.
        let jpg = try roots.jpgURL.map {
            try scanFiles($0, extensions: ["jpg", "jpeg"], deletionKeys: exactKeys, fallbackStems: fallbackStems)
        } ?? []
        let raw = try roots.rawURL.map {
            try scanFiles($0, extensions: ["arw"], deletionKeys: exactKeys, fallbackStems: fallbackStems)
        } ?? []
        let fresh = pair(jpg: jpg, raw: raw)
        let byID = Dictionary(uniqueKeysWithValues: fresh.map { ($0.id, $0) })
        for photo in photos {
            guard !photo.ambiguous, let current = byID[photo.id], !current.ambiguous, Set(current.files) == Set(photo.files) else { throw LibraryError.message("文件或配对关系已变化：\(photo.name)。请重新扫描后检查。") }
            for file in photo.files {
                guard canonicalURL(file.url).path == file.url.path else { throw LibraryError.message("文件路径已变为符号链接，停止删除。") }
            }
        }
    }
    static func validateFileIdentity(_ file: PhotoFile) throws {
        let a=try FileManager.default.attributesOfItem(atPath:file.url.path)
        let identity="\(a[.systemNumber] ?? ""):\(a[.systemFileNumber] ?? ""):\(a[.creationDate] ?? "")"
        guard a[.type] as? FileAttributeType == .typeRegular,identity==file.identity,(a[.size] as? NSNumber)?.int64Value==file.bytes,a[.modificationDate] as? Date==file.modified else{throw LibraryError.message("照片已变化，请重新扫描后再设置标记。")}
    }
    static func validateRemoval(_ file: PhotoFile) throws {
        guard canonicalURL(file.url).path == file.url.path else { throw LibraryError.message("照片路径包含符号链接。") }
        try validateFileIdentity(file)
    }
    static func deletePermanently(_ file: PhotoFile) throws {
        try validateRemoval(file)
        guard unlink(file.url.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }
    static func restore(_ record: TrashRecord, roots: Roots? = nil) throws {
        guard !manager.fileExists(atPath: record.original.path) else { throw LibraryError.message("恢复目标已存在，未覆盖：\(record.original.path)") }
        let parent = record.original.deletingLastPathComponent()
        if !manager.fileExists(atPath: parent.path) {
            try roots?.validate()
            try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        }
        try manager.moveItem(at: record.trashed, to: record.original)
    }
}
