import AppKit
import SwiftUI
import UniformTypeIdentifiers

@main
enum Launcher {
    @MainActor static func main() {
        if CommandLine.arguments.contains("--verify") {
            do { try verifyRelay(); exit(0) }
            catch { fputs("Verification failed: \(error)\n", stderr); exit(1) }
        }
        RelayApp.main()
    }
}

struct RelayApp: App {
    var body: some Scene {
        Window("Relay", id: "main") {
            ContentView()
                .frame(minWidth: 540, minHeight: 420)
        }
        .defaultSize(width: 640, height: 510)
    }
}

struct ContentView: View {
    @StateObject private var files = TransferModel()
    @StateObject private var local = LocalTransferModel()
    @State private var dropTarget = false
    @State private var useIPLink = true

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(spacing: 10) {
                Image(nsImage: NSApp.applicationIconImage)
                    .resizable().frame(width: 46, height: 46)
                    .accessibilityHidden(true)
                Text("Relay").font(.title.weight(.semibold))
                Spacer()
                Text("Local Wi-Fi").font(.callout).foregroundStyle(.secondary)
            }
            if local.running {
                sessionPanel
            } else {
                setupPanel
            }
            if let status = local.status {
                Text(status).font(.callout).foregroundStyle(.secondary)
                    .textSelection(.enabled)
            }
            Spacer(minLength: 0)
        }
        .padding(24)
        .onDisappear { local.stop() }
    }

    private var setupPanel: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Text("Send files").font(.headline)
                Spacer()
                if !files.outgoing.isEmpty {
                    Button("Clear") { files.clear() }
                }
            }
            HStack(spacing: 12) {
                Label(dropTarget ? "Drop to add" : "Drop files here", systemImage: "tray.and.arrow.down")
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Choose files…") { files.chooseFiles() }
                    .keyboardShortcut("o")
            }
            .padding(14)
            .background(dropTarget ? Color.accentColor.opacity(0.12) : Color.primary.opacity(0.045), in: RoundedRectangle(cornerRadius: 10))
            .onDrop(of: [UTType.fileURL.identifier], isTargeted: $dropTarget) { providers in
                for provider in providers {
                    _ = provider.loadObject(ofClass: NSURL.self) { object, _ in
                        guard let url = object as? URL else { return }
                        Task { @MainActor in
                            guard !local.running else { return }
                            files.addFiles([url])
                        }
                    }
                }
                return !providers.isEmpty
            }
            if !files.outgoing.isEmpty {
                ScrollView {
                    LazyVStack(spacing: 4) {
                        ForEach(files.outgoing) { item in
                            HStack(spacing: 8) {
                                Image(systemName: "doc").foregroundStyle(.secondary)
                                Text(item.name).lineLimit(1).help(item.url.path)
                                Spacer()
                                Text(item.size).foregroundStyle(.secondary)
                                Button { files.remove(item) } label: {
                                    Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Remove \(item.name)")
                            }
                            .font(.callout)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 5)
                        }
                    }
                }
                .frame(maxHeight: 110)
            }
            if let notice = files.notice {
                Text(notice).font(.caption).foregroundStyle(.secondary)
            }
            Divider()
            HStack {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Receive files").font(.headline)
                    Text(local.receiveFolder?.lastPathComponent ?? "Optional")
                        .font(.callout).foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                Spacer()
                Button(local.receiveFolder == nil ? "Choose folder…" : "Change folder…") { local.chooseFolder() }
                    .accessibilityLabel("Choose receiving folder")
            }
            HStack {
                Text("Connect both devices to the same Wi-Fi.")
                    .font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Start sharing") {
                    useIPLink = true
                    local.start(files: files.outgoing)
                }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(files.outgoing.isEmpty && local.receiveFolder == nil)
            }
        }
    }

    @ViewBuilder private var sessionPanel: some View {
        if let url = useIPLink ? local.ipSessionURL : local.sessionURL {
            HStack(spacing: 18) {
                if let qr = local.qrImage(for: url) {
                    Image(nsImage: qr).interpolation(.none).resizable().scaledToFit()
                        .frame(width: 134, height: 134).padding(10)
                        .background(.white, in: RoundedRectangle(cornerRadius: 10))
                        .accessibilityLabel("Scan this QR code with your iPhone camera")
                }
                VStack(alignment: .leading, spacing: 8) {
                    Text("Scan with your iPhone").font(.headline)
                    Text(url.absoluteString).font(.caption.monospaced())
                        .textSelection(.enabled)
                    Button("Copy session link") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(url.absoluteString, forType: .string)
                    }
                    if local.ipSessionURL != local.sessionURL {
                        Button(useIPLink ? "Use Mac name" : "Use IP address") { useIPLink.toggle() }
                            .controlSize(.small)
                        Text("A Mac-name link can keep working when both devices switch Wi-Fi.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            HStack {
                VStack(alignment: .leading, spacing: 3) {
                    let count = local.sharedFiles.count
                    Text(count == 0 ? "Receiving only" : "\(count) \(count == 1 ? "file" : "files") to download")
                    if local.receiveFolder != nil {
                        Text("\(local.receivedCount) received")
                    }
                }
                .font(.callout).foregroundStyle(.secondary)
                if let folder = local.receiveFolder {
                    Button("Open receiving folder") { NSWorkspace.shared.open(folder) }
                }
                Spacer()
                Button("Stop sharing") { local.stop() }.controlSize(.large)
            }
            if !local.activity.isEmpty {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 6) {
                        ForEach(Array(local.activity.enumerated()), id: \.offset) { _, message in
                            Text(message).font(.caption).foregroundStyle(.secondary)
                        }
                    }.frame(maxWidth: .infinity, alignment: .leading)
                }.frame(maxHeight: 70)
            }
        } else {
            HStack {
                ProgressView().controlSize(.small)
                if local.status == nil { Text("Starting sharing…") }
                Spacer()
                Button("Stop sharing") { local.stop() }
            }
        }
    }
}
