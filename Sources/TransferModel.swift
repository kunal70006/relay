import AppKit
import SwiftUI

struct FileItem: Identifiable {
    let id = UUID()
    let url: URL
    var name: String { url.lastPathComponent }
    var size: String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
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
                  let values = try? url.resourceValues(forKeys: [.isRegularFileKey, .isReadableKey]),
                  values.isRegularFile == true, values.isReadable == true else {
                skipped = true
                continue
            }
            if !outgoing.contains(where: { $0.url.standardizedFileURL == url.standardizedFileURL }) {
                outgoing.append(FileItem(url: url))
            }
        }
        notice = skipped ? "Folders and unreadable files were skipped." : nil
    }

    func chooseFiles() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
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
