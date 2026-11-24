import Foundation
import zlib

// A shared folder, served as an uncompressed ("stored") ZIP archive that is
// built while it streams. Stored entries make the archive length exact before
// any bytes are read, so downloads keep a Content-Length and accurate progress.
// CRCs are computed during streaming and written in data descriptors and the
// central directory. ZIP64 records are used only when the archive needs them.
struct FolderArchive {
    struct Entry {
        let name: Data
        let path: String?
        let size: Int
        let version: FileVersion?
        let mode: UInt32
        let time: UInt16
        let date: UInt16
        let offset: Int
        var isDirectory: Bool { path == nil }
    }

    static let maxEntries = 200_000

    let name: String
    let entries: [Entry]
    let zip64: Bool
    let centralOffset: Int
    let centralSize: Int
    let length: Int
    var fileCount: Int { entries.lazy.filter { !$0.isDirectory }.count }

    init(folder: URL, forceZip64: Bool = false) throws {
        let unreadable = LocalTransferError.message("This folder is no longer readable on the Mac")
        let root = folder.resolvingSymlinksInPath().path
        let rootName = folder.lastPathComponent
        var info = stat()
        guard stat(root, &info) == 0, info.st_mode & S_IFMT == S_IFDIR,
              let walker = FileManager.default.enumerator(atPath: root) else { throw unreadable }
        name = rootName + ".zip"

        typealias Scanned = (name: Data, path: String?, info: stat)
        var scanned: [Scanned] = [(Self.entryName(rootName + "/"), nil, info)]
        // The enumerator does not follow symbolic links. Hidden items such as
        // .DS_Store are left out, along with links, devices, and unreadable files.
        while let relative = walker.nextObject() as? String {
            if (relative as NSString).lastPathComponent.hasPrefix(".") {
                walker.skipDescendants()
                continue
            }
            let path = root + "/" + relative
            guard lstat(path, &info) == 0 else { continue }
            let kind = info.st_mode & S_IFMT
            let isDirectory = kind == S_IFDIR
            guard isDirectory || (kind == S_IFREG && access(path, R_OK) == 0) else { continue }
            let entryName = Self.entryName(rootName + "/" + relative + (isDirectory ? "/" : ""))
            guard entryName.count <= 0xFFFF else { continue }
            scanned.append((entryName, isDirectory ? nil : path, info))
            guard scanned.count <= Self.maxEntries else {
                throw LocalTransferError.message("This folder has more than \(Self.maxEntries) items")
            }
        }

        func layout(zip64: Bool) -> (entries: [Entry], centralOffset: Int, centralSize: Int) {
            var offset = 0
            var centralSize = 0
            let entries = scanned.map { item -> Entry in
                let size = item.path == nil ? 0 : Int(item.info.st_size)
                let kind = item.path == nil ? UInt32(S_IFDIR) | 0o755 : UInt32(S_IFREG) | (UInt32(item.info.st_mode) & 0o777)
                let (time, date) = Self.dosTimestamp(item.info.st_mtimespec.tv_sec)
                let entry = Entry(name: item.name, path: item.path, size: size,
                                  version: item.path == nil ? nil : FileVersion(item.info),
                                  mode: kind, time: time, date: date, offset: offset)
                offset += 30 + item.name.count + (zip64 ? 20 : 0) + size
                if item.path != nil { offset += zip64 ? 24 : 16 }
                centralSize += 46 + item.name.count + (zip64 ? 28 : 0)
                return entry
            }
            return (entries, offset, centralSize)
        }

        var plan = layout(zip64: false)
        let needsZip64 = forceZip64 || plan.entries.count >= 0xFFFF ||
            plan.entries.contains { $0.size >= 0xFFFF_FFFF } ||
            plan.centralOffset + plan.centralSize >= 0xFFFF_FFFF
        if needsZip64 { plan = layout(zip64: true) }
        zip64 = needsZip64
        entries = plan.entries
        centralOffset = plan.centralOffset
        centralSize = plan.centralSize
        length = centralOffset + centralSize + (zip64 ? 56 + 20 : 0) + 22
    }

    private static func entryName(_ path: String) -> Data {
        Data(path.precomposedStringWithCanonicalMapping.utf8)
    }

    private static func dosTimestamp(_ seconds: Int) -> (UInt16, UInt16) {
        var value = time_t(seconds)
        var parts = tm()
        guard localtime_r(&value, &parts) != nil, parts.tm_year >= 80 else { return (0, 1 << 5 | 1) }
        let year = UInt16(min(parts.tm_year - 80, 127))
        let month = UInt16(parts.tm_mon + 1), day = UInt16(parts.tm_mday)
        let hour = UInt16(parts.tm_hour), minute = UInt16(parts.tm_min), second = UInt16(parts.tm_sec / 2)
        let date: UInt16 = year << 9 | month << 5 | day
        let time: UInt16 = hour << 11 | minute << 5 | second
        return (time, date)
    }

    // MARK: Records

    private var versionNeeded: UInt16 { zip64 ? 45 : 20 }

    private func flags(_ entry: Entry) -> UInt16 {
        // Bit 11: UTF-8 names. Bit 3: CRC and sizes follow the data.
        entry.isDirectory ? 0x0800 : 0x0808
    }

    func localHeader(_ entry: Entry) -> Data {
        var out = Data()
        out.le32(0x0403_4b50)
        out.le16(versionNeeded)
        out.le16(flags(entry))
        out.le16(0)
        out.le16(entry.time)
        out.le16(entry.date)
        out.le32(0)
        out.le32(zip64 ? 0xFFFF_FFFF : 0)
        out.le32(zip64 ? 0xFFFF_FFFF : 0)
        out.le16(UInt16(entry.name.count))
        out.le16(zip64 ? 20 : 0)
        out.append(entry.name)
        if zip64 {
            out.le16(0x0001)
            out.le16(16)
            out.le64(0)
            out.le64(0)
        }
        return out
    }

    func dataDescriptor(_ entry: Entry, crc: UInt32) -> Data {
        var out = Data()
        out.le32(0x0807_4b50)
        out.le32(crc)
        if zip64 {
            out.le64(UInt64(entry.size))
            out.le64(UInt64(entry.size))
        } else {
            out.le32(UInt32(entry.size))
            out.le32(UInt32(entry.size))
        }
        return out
    }

    func centralDirectory(crcs: [UInt32]) -> Data {
        var out = Data()
        out.reserveCapacity(centralSize + 98)
        for (index, entry) in entries.enumerated() {
            out.le32(0x0201_4b50)
            out.le16(3 << 8 | versionNeeded)
            out.le16(versionNeeded)
            out.le16(flags(entry))
            out.le16(0)
            out.le16(entry.time)
            out.le16(entry.date)
            out.le32(crcs[index])
            out.le32(zip64 ? 0xFFFF_FFFF : UInt32(entry.size))
            out.le32(zip64 ? 0xFFFF_FFFF : UInt32(entry.size))
            out.le16(UInt16(entry.name.count))
            out.le16(zip64 ? 28 : 0)
            out.le16(0)
            out.le16(0)
            out.le16(0)
            out.le32(entry.mode << 16 | (entry.isDirectory ? 0x10 : 0))
            out.le32(zip64 ? 0xFFFF_FFFF : UInt32(entry.offset))
            out.append(entry.name)
            if zip64 {
                out.le16(0x0001)
                out.le16(24)
                out.le64(UInt64(entry.size))
                out.le64(UInt64(entry.size))
                out.le64(UInt64(entry.offset))
            }
        }
        let count = UInt64(entries.count)
        if zip64 {
            out.le32(0x0606_4b50)
            out.le64(44)
            out.le16(3 << 8 | 45)
            out.le16(45)
            out.le32(0)
            out.le32(0)
            out.le64(count)
            out.le64(count)
            out.le64(UInt64(centralSize))
            out.le64(UInt64(centralOffset))
            out.le32(0x0706_4b50)
            out.le32(0)
            out.le64(UInt64(centralOffset + centralSize))
            out.le32(1)
        }
        out.le32(0x0605_4b50)
        out.le16(0)
        out.le16(0)
        out.le16(zip64 ? 0xFFFF : UInt16(count))
        out.le16(zip64 ? 0xFFFF : UInt16(count))
        out.le32(zip64 ? 0xFFFF_FFFF : UInt32(centralSize))
        out.le32(zip64 ? 0xFFFF_FFFF : UInt32(centralOffset))
        out.le16(0)
        return out
    }
}

// Produces the archive bytes in order. Throws if a file changes or disappears
// after the folder was scanned, because the promised length would be wrong.
final class FolderZipReader {
    private let archive: FolderArchive
    private var crcs: [UInt32]
    private var index = 0
    private var handle: FileHandle?
    private var remaining = 0
    private var crc: uLong = 0
    private var pending = Data()
    private var wroteCentralDirectory = false

    init(_ archive: FolderArchive) {
        self.archive = archive
        crcs = Array(repeating: 0, count: archive.entries.count)
    }

    func read(upTo limit: Int) throws -> Data {
        while pending.count < limit {
            if handle != nil {
                try readFile(upTo: limit - pending.count)
            } else if index < archive.entries.count {
                let entry = archive.entries[index]
                pending.append(archive.localHeader(entry))
                if let path = entry.path { try open(path, entry) } else { index += 1 }
            } else if !wroteCentralDirectory {
                pending.append(archive.centralDirectory(crcs: crcs))
                wroteCentralDirectory = true
            } else {
                break
            }
        }
        let count = min(limit, pending.count)
        let chunk = pending.prefix(count)
        pending.removeFirst(count)
        return Data(chunk)
    }

    private func changed() -> Error {
        try? handle?.close()
        handle = nil
        return LocalTransferError.message("A file in this folder changed during the download")
    }

    private func open(_ path: String, _ entry: FolderArchive.Entry) throws {
        let fd = Darwin.open(path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
        guard fd >= 0 else { throw changed() }
        handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
        guard FileVersion(descriptor: fd) == entry.version else { throw changed() }
        remaining = entry.size
        crc = crc32(0, nil, 0)
    }

    private func readFile(upTo limit: Int) throws {
        guard let handle else { return }
        let entry = archive.entries[index]
        if remaining > 0 {
            guard let data = try handle.read(upToCount: min(remaining, max(limit, 1))), !data.isEmpty,
                  FileVersion(descriptor: handle.fileDescriptor) == entry.version else { throw changed() }
            crc = data.withUnsafeBytes { crc32(crc, $0.bindMemory(to: Bytef.self).baseAddress, uInt($0.count)) }
            remaining -= data.count
            pending.append(data)
        }
        if remaining == 0 {
            try? handle.close()
            self.handle = nil
            crcs[index] = UInt32(crc)
            pending.append(archive.dataDescriptor(entry, crc: UInt32(crc)))
            index += 1
        }
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le32(_ value: UInt32) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
    mutating func le64(_ value: UInt64) { Swift.withUnsafeBytes(of: value.littleEndian) { append(contentsOf: $0) } }
}
