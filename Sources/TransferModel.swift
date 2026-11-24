import AppKit
import SwiftUI

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    let isFolder: Bool
    var detail: String
    var name: String { url.lastPathComponent }

    init(url: URL, isFolder: Bool) {
        self.url = url
        self.isFolder = isFolder
        if isFolder {
            detail = "Counting…"
        } else {
            let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            detail = ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
        }
    }
}

@MainActor
final class TransferModel: ObservableObject {
    @Published private(set) var outgoing: [FileItem] = []
    @Published private(set) var notice: String?

    func addFiles(_ urls: [URL]) {
        var skipped = false
        for url in urls {
            guard url.isFileURL,
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isDirectoryKey, .isReadableKey]),
                  values.isRegularFile == true || values.isDirectory == true, values.isReadable == true else {
                skipped = true
                continue
            }
            guard !outgoing.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) else { continue }
            let item = FileItem(url: url, isFolder: values.isDirectory == true)
            outgoing.append(item)
            if item.isFolder { measureFolder(item) }
        }
        notice = skipped ? "Unreadable items were skipped." : nil
    }

    private func measureFolder(_ item: FileItem) {
        let url = item.url
        Task.detached(priority: .utility) { [weak self] in
            let detail: String
            do {
                let archive = try FolderArchive(folder: url)
                let count = archive.fileCount
                let size = ByteCountFormatter.string(fromByteCount: Int64(archive.length), countStyle: .file)
                detail = "\(count) \(count == 1 ? "file" : "files") · \(size) .zip"
            } catch {
                detail = "Unreadable folder"
            }
            await self?.setDetail(detail, for: item.id)
        }
    }

    private func setDetail(_ detail: String, for id: UUID) {
        guard let index = outgoing.firstIndex(where: { $0.id == id }) else { return }
        outgoing[index].detail = detail
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.prompt = "Add files"
        if let window = NSApp.keyWindow {
            panel.beginSheetModal(for: window) { [weak self] response in
                if response == .OK { self?.addFiles(panel.urls) }
            }
        } else if panel.runModal() == .OK {
            addFiles(panel.urls)
        }
    }

    func remove(_ item: FileItem) {
        outgoing.removeAll { $0.id == item.id }
        notice = nil
    }

    func clear() {
        outgoing = []
        notice = nil
    }
}
