import AppKit
import CoreImage
import CoreWLAN
import Network
import SwiftUI
import SystemConfiguration

enum LocalTransferError: LocalizedError {
    case message(String)
    var errorDescription: String? { if case .message(let message) = self { return message }; return nil }
}

enum TransferActivity {
    case received(String)
    case served(String)

    var message: String {
        switch self {
        case .received(let name): return "Received \(name)"
        case .served(let name): return "Served \(name) to browser"
        }
    }
}

@MainActor
final class LocalTransferModel: ObservableObject {
    @Published var sessionURL: URL?
    @Published var ipSessionURL: URL?
    @Published var running = false
    @Published var status: String?
    @Published var receiveFolder: URL?
    @Published var activity: [String] = []
    @Published var sharedFiles: [FileItem] = []
    @Published private(set) var receivedCount = 0
    private var server: LocalHTTPServer?
    private var hasFolderScope = false
    private var networkTimer: Timer?
    private static let qrContext = CIContext()

    func chooseFolder() {
        guard !running else { return }
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.directoryURL = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
        panel.message = "Relay saves uploads here and keeps existing files."
        panel.prompt = "Receive files here"
        if panel.runModal() == .OK, let folder = panel.url {
            if hasFolderScope, let previous = receiveFolder { previous.stopAccessingSecurityScopedResource() }
            receiveFolder = folder
            hasFolderScope = folder.startAccessingSecurityScopedResource()
        }
    }

    func start(files: [FileItem]) {
        guard !running else { return }
        do {
            guard let ip = Self.wifiAddress() else {
                throw LocalTransferError.message("No Wi-Fi IPv4 address found. Connect this Mac and the other device to the same Wi-Fi.")
            }
            guard let pageURL = Bundle.main.url(forResource: "local", withExtension: "html"),
                  let page = try? Data(contentsOf: pageURL) else {
                throw LocalTransferError.message("The transfer page is missing. Rebuild the app.")
            }
            let activeServer = LocalHTTPServer(address: ip, hostname: Self.localHostname(), files: files.map(\.url), receiveFolder: receiveFolder, page: page)
            server = activeServer
            sharedFiles = files
            running = true
            status = nil
            activity = []
            receivedCount = 0
            activeServer.onReady = { [weak self, weak activeServer] url, ipURL in
                DispatchQueue.main.async {
                    guard let self, let activeServer, self.server === activeServer else { return }
                    self.sessionURL = url
                    self.ipSessionURL = ipURL
                    self.status = nil
                }
            }
            activeServer.onActivity = { [weak self, weak activeServer] event in
                DispatchQueue.main.async {
                    guard let self, let activeServer, self.server === activeServer else { return }
                    if case .received = event { self.receivedCount += 1 }
                    self.activity.insert(event.message, at: 0)
                    self.activity = Array(self.activity.prefix(30))
                }
            }
            activeServer.onUnavailable = { [weak self, weak activeServer] message in
                DispatchQueue.main.async {
                    guard let self, let activeServer, self.server === activeServer else { return }
                    self.sessionURL = nil
                    self.ipSessionURL = nil
                    self.status = message
                }
            }
            activeServer.start()
            networkTimer = Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    self?.server?.updateNetwork(address: Self.wifiAddress(), hostname: Self.localHostname())
                }
            }
        } catch { status = error.localizedDescription }
    }

    func stop() {
        networkTimer?.invalidate()
        networkTimer = nil
        server?.stop()
        server = nil
        running = false
        sessionURL = nil
        ipSessionURL = nil
        sharedFiles = []
        status = nil
    }

    func qrImage(for url: URL) -> NSImage? {
        guard let filter = CIFilter(name: "CIQRCodeGenerator") else { return nil }
        filter.setValue(Data(url.absoluteString.utf8), forKey: "inputMessage")
        filter.setValue("M", forKey: "inputCorrectionLevel")
        guard let output = filter.outputImage?.transformed(by: CGAffineTransform(scaleX: 6, y: 6)),
              let cg = Self.qrContext.createCGImage(output, from: output.extent) else { return nil }
        return NSImage(cgImage: cg, size: NSSize(width: output.extent.width, height: output.extent.height))
    }

    private static func localHostname() -> String? {
        guard let name = SCDynamicStoreCopyLocalHostName(nil) else { return nil }
        return (name as String).lowercased() + ".local"
    }

    private static func wifiAddress() -> String? {
        guard let wifiInterface = CWWiFiClient.shared().interface()?.interfaceName else { return nil }
        var interfaces: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&interfaces) == 0, let first = interfaces else { return nil }
        defer { freeifaddrs(interfaces) }
        var node: UnsafeMutablePointer<ifaddrs>? = first
        while let current = node {
            defer { node = current.pointee.ifa_next }
            guard let address = current.pointee.ifa_addr,
                  address.pointee.sa_family == UInt8(AF_INET),
                  String(cString: current.pointee.ifa_name) == wifiInterface,
                  (current.pointee.ifa_flags & UInt32(IFF_UP)) != 0 else { continue }
            var host = [CChar](repeating: 0, count: Int(NI_MAXHOST))
            if getnameinfo(address, socklen_t(address.pointee.sa_len), &host, socklen_t(host.count), nil, 0, NI_NUMERICHOST) == 0 {
                let ip = String(cString: host)
                if !ip.hasPrefix("127."), !ip.hasPrefix("169.254.") { return ip }
            }
        }
        return nil
    }
}

// A session-scoped HTTP server, bound to the Mac's Wi-Fi address only.
// All connection state and file I/O run on one serial queue.
final class LocalHTTPServer {
    let queue = DispatchQueue(label: "local.relay.http")
    let prefix = "/s/" + UUID().uuidString.replacingOccurrences(of: "-", with: "") + UUID().uuidString.replacingOccurrences(of: "-", with: "")
    let files: [String: URL]
    fileprivate let versions: [String: FileVersion]
    let receiveFolder: URL?
    private let page: Data
    private lazy var initialPage: Data = {
        guard let html = String(data: page, encoding: .utf8),
              let data = try? manifest() else { return page }
        let json = String(decoding: data, as: UTF8.self).replacingOccurrences(of: "<", with: "\\u003c")
        let script = "<script id=\"session-data\" type=\"application/json\">\(json)</script>"
        return Data(html.replacingOccurrences(of: "<!-- relay:session-data -->", with: script).utf8)
    }()
    var onReady: ((URL, URL) -> Void)?
    var onActivity: ((TransferActivity) -> Void)?
    var onUnavailable: ((String) -> Void)?
    private var connections: [UUID: HTTPConnection] = [:]
    private var stopped = false
    private var listener: NWListener?
    private var listenerReady = false
    private var address: String?
    private var hostname: String?
    private var port: NWEndpoint.Port = .any
    fileprivate var uploads: [UUID: UploadRecord] = [:]
    private var cleanupTimer: DispatchSourceTimer?

    init(address: String, hostname: String? = nil, files: [URL], receiveFolder: URL?, page: Data) {
        self.address = address
        self.hostname = hostname
        let shared = Dictionary(uniqueKeysWithValues: files.map { (UUID().uuidString, $0) })
        self.files = shared
        versions = shared.compactMapValues { FileVersion(path: $0.path) }
        self.receiveFolder = receiveFolder
        self.page = page
    }

    func acceptsHost(_ host: String) -> Bool {
        let hosts = [address, hostname].compactMap { $0 }
        return hosts.contains { "\($0):\(port.rawValue)" == host.lowercased() }
    }

    func start() {
        queue.async { [self] in
            bind()
            let timer = DispatchSource.makeTimerSource(queue: queue)
            timer.schedule(deadline: .now() + 60, repeating: 60)
            timer.setEventHandler { [weak self] in self?.expireUploads() }
            cleanupTimer = timer
            timer.resume()
        }
    }

    func updateNetwork(address: String?, hostname: String?) {
        queue.async { [self] in
            guard !stopped else { return }
            let hostnameChanged = self.hostname != hostname
            self.hostname = hostname
            if self.address == address, listener != nil || address == nil {
                if hostnameChanged { publishLinks() }
                return
            }
            closeNetwork()
            self.address = address
            onUnavailable?(address == nil ? "Waiting for Wi-Fi…" : "Reconnecting on Wi-Fi…")
            bind()
        }
    }

    private func bind() {
        guard let address, !stopped else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.allowLocalEndpointReuse = true
            parameters.requiredLocalEndpoint = .hostPort(host: NWEndpoint.Host(address), port: port)
            let next = try NWListener(using: parameters)
            listener = next
            next.stateUpdateHandler = { [weak self, weak next] state in
                guard let self, let next, self.listener === next else { return }
                switch state {
                case .ready:
                    if let port = next.port { self.port = port }
                    self.listenerReady = true
                    self.publishLinks()
                case .failed(let error):
                    self.closeNetwork()
                    if error == .posix(.EADDRINUSE) { self.port = .any }
                    self.onUnavailable?("Waiting to reconnect: \(error.localizedDescription)")
                case .waiting:
                    self.listenerReady = false
                    self.onUnavailable?("Waiting for Wi-Fi…")
                default: break
                }
            }
            next.newConnectionHandler = { [weak self, weak next] connection in
                guard let self, let next, self.listener === next, self.connections.count < 12 else {
                    connection.cancel()
                    return
                }
                let client = HTTPConnection(connection: connection, server: self)
                self.connections[client.id] = client
                client.onFinish = { [weak self, weak client] in
                    if let id = client?.id { self?.connections[id] = nil }
                }
                client.start()
            }
            next.start(queue: queue)
        } catch {
            listener = nil
            if let error = error as? NWError, error == .posix(.EADDRINUSE) { port = .any }
            onUnavailable?("Waiting to reconnect: \(error.localizedDescription)")
        }
    }

    private func publishLinks() {
        guard listenerReady, let address,
              let ipURL = URL(string: "http://\(address):\(port.rawValue)\(prefix)/") else { return }
        let namedURL = hostname.flatMap { URL(string: "http://\($0):\(port.rawValue)\(prefix)/") }
        onReady?(namedURL ?? ipURL, ipURL)
    }

    private func closeNetwork() {
        listenerReady = false
        listener?.cancel()
        listener = nil
        for client in Array(connections.values) { client.close() }
    }

    func stop() {
        queue.async { [self] in
            stopped = true
            cleanupTimer?.cancel()
            cleanupTimer = nil
            closeNetwork()
            for upload in uploads.values { upload.removeTemporaryFile() }
            uploads.removeAll()
        }
    }

    fileprivate func expireUploads() {
        let stale = uploads.filter {
            $0.value.savedAs == nil && !$0.value.active && $0.value.lastUsed.duration(to: .now) > .seconds(1800)
        }
        for (id, upload) in stale {
            upload.removeTemporaryFile()
            uploads.removeValue(forKey: id)
        }
    }

    func manifest() throws -> Data {
        let items: [[String: Any]] = files.sorted { $0.value.lastPathComponent < $1.value.lastPathComponent }.map { key, url in
            let size = versions[key]?.size ?? 0
            return ["id": key, "name": url.lastPathComponent, "size": size]
        }
        return try JSONSerialization.data(withJSONObject: ["files": items, "canUpload": receiveFolder != nil])
    }

    func sessionPage() -> Data { initialPage }
}

private struct FileVersion: Equatable {
    let size: Int
    let tag: String

    init?(path: String) {
        var info = stat()
        guard lstat(path, &info) == 0 else { return nil }
        self.init(info)
    }

    init?(descriptor: Int32) {
        var info = stat()
        guard fstat(descriptor, &info) == 0 else { return nil }
        self.init(info)
    }

    private init?(_ info: stat) {
        guard info.st_mode & S_IFMT == S_IFREG else { return nil }
        size = Int(info.st_size)
        let modified = info.st_mtimespec
        let changed = info.st_ctimespec
        tag = "\"\(info.st_dev)-\(info.st_ino)-\(size)-\(modified.tv_sec)-\(modified.tv_nsec)-\(changed.tv_sec)-\(changed.tv_nsec)\""
    }
}

private final class UploadRecord {
    let name: String
    let total: Int
    var temporaryFile: URL?
    var offset = 0
    var active = false
    var savedAs: String?
    var lastUsed = ContinuousClock.now

    init(name: String, total: Int) {
        self.name = name
        self.total = total
    }

    var progress: [String: Any] {
        if let savedAs { return ["offset": offset, "savedAs": savedAs] }
        return ["offset": offset, "busy": active]
    }

    func removeTemporaryFile() {
        if let temporaryFile { try? FileManager.default.removeItem(at: temporaryFile) }
        temporaryFile = nil
    }
}

private final class HTTPConnection {
    let id = UUID()
    let connection: NWConnection
    unowned let server: LocalHTTPServer
    var onFinish: (() -> Void)?
    private var headerBuffer = Data()
    private var readingHeaders = true
    private var uploadHandle: FileHandle?
    private var upload: UploadRecord?
    private var resumable = false
    private var expectedBytes = 0
    private var receivedBytes = 0
    private var downloadHandle: FileHandle?
    private var downloadRemaining = 0
    private var downloadName = ""
    private var downloadVersion: FileVersion?
    private var powerActivity: NSObjectProtocol?
    private var timeout: DispatchSourceTimer?
    private var finished = false
    private var responding = false

    init(connection: NWConnection, server: LocalHTTPServer) {
        self.connection = connection
        self.server = server
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .failed, .cancelled: self?.close()
            default: break
            }
        }
        connection.start(queue: server.queue)
        let timer = DispatchSource.makeTimerSource(queue: server.queue)
        timer.setEventHandler { [weak self] in self?.close() }
        timeout = timer
        timer.schedule(deadline: .now() + 10)
        timer.resume()
        receive()
    }

    private func touch() {
        timeout?.schedule(deadline: .now() + (uploadHandle == nil ? 120 : 30))
    }

    func close() {
        guard !finished else { return }
        finished = true
        timeout?.cancel()
        timeout = nil
        if let upload {
            if resumable {
                try? uploadHandle?.truncate(atOffset: UInt64(upload.offset))
                upload.active = false
                upload.lastUsed = .now
            } else {
                upload.removeTemporaryFile()
            }
        }
        try? uploadHandle?.close()
        try? downloadHandle?.close()
        uploadHandle = nil
        downloadHandle = nil
        if let powerActivity { ProcessInfo.processInfo.endActivity(powerActivity) }
        powerActivity = nil
        connection.cancel()
        onFinish?()
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, complete, error in
            guard let self, !self.finished else { return }
            if !self.readingHeaders { self.touch() }
            if let data, !data.isEmpty {
                if self.uploadHandle != nil { self.consumeUpload(data) }
                else {
                    self.headerBuffer.append(data)
                    if let end = self.headerBuffer.range(of: Data("\r\n\r\n".utf8)) {
                        guard end.lowerBound <= 32768 else { self.reply(431, "Headers too large"); return }
                        let header = self.headerBuffer.subdata(in: 0..<end.lowerBound)
                        let body = self.headerBuffer.subdata(in: end.upperBound..<self.headerBuffer.count)
                        self.headerBuffer = Data()
                        self.readingHeaders = false
                        self.touch()
                        self.handle(header: header, body: body)
                    } else if self.headerBuffer.count > 32768 { self.reply(431, "Headers too large"); return }
                }
            }
            if self.responding || self.finished { return }
            if error != nil || complete { self.close(); return }
            self.receive()
        }
    }

    private func handle(header: Data, body: Data) {
        guard let text = String(data: header, encoding: .utf8) else { reply(400, "Invalid headers"); return }
        let lines = text.components(separatedBy: "\r\n")
        let request = lines[0].split(separator: " ")
        guard request.count == 3, let components = URLComponents(string: String(request[1])), components.host == nil else { reply(400, "Invalid request"); return }
        let method = String(request[0])
        let path = components.path
        guard path == server.prefix + "/" || path.hasPrefix(server.prefix + "/") else { reply(404, "Session not found"); return }
        var headers: [String: String] = [:]
        for line in lines.dropFirst() {
            guard let colon = line.firstIndex(of: ":") else { reply(400, "Invalid header"); return }
            let key = line[..<colon].lowercased()
            guard headers[key] == nil else { reply(400, "Duplicate header"); return }
            headers[key] = line[line.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        }
        guard let host = headers["host"], server.acceptsHost(host) else { reply(403, "Unexpected host"); return }
        guard headers["transfer-encoding"] == nil else { reply(400, "Chunked requests are not supported"); return }
        if method == "GET", path == server.prefix + "/" {
            reply(200, data: server.sessionPage(), type: "text/html; charset=utf-8")
        } else if method == "GET", path == server.prefix + "/api" {
            do { reply(200, data: try server.manifest(), type: "application/json") }
            catch { reply(500, "Could not list files") }
        } else if (method == "GET" || method == "HEAD"), path.hasPrefix(server.prefix + "/files/") {
            let key = String(path.dropFirst((server.prefix + "/files/").count))
            guard let file = server.files[key] else { reply(404, "File not found"); return }
            guard let version = server.versions[key] else { reply(404, "This file is no longer readable on the Mac"); return }
            download(file, version: version, range: headers["range"], ifRange: headers["if-range"], headOnly: method == "HEAD")
        } else if method == "GET", path == server.prefix + "/upload" {
            guard headers["x-relay-upload"] == "1", let rawID = components.queryItems?.first(where: { $0.name == "id" })?.value,
                  let id = UUID(uuidString: rawID) else { reply(400, "Invalid upload ID"); return }
            let current = server.uploads[id]
            current?.lastUsed = .now
            replyProgress(current?.progress ?? ["offset": 0])
        } else if method == "POST", path == server.prefix + "/upload" {
            guard headers["origin"]?.lowercased() == "http://\(host.lowercased())", headers["x-relay-upload"] == "1" else {
                reply(403, "Upload must come from the session page")
                return
            }
            startUpload(query: components.queryItems ?? [], lengthHeader: headers["content-length"], body: body)
        } else { reply(405, "Method or route not supported") }
    }

    private func startUpload(query: [URLQueryItem], lengthHeader: String?, body: Data) {
        guard let folder = server.receiveFolder else { reply(403, "Choose a receiving folder on the Mac first"); return }
        let maxFileSize = 20 * 1024 * 1024 * 1024
        guard let lengthHeader, let length = Int(lengthHeader), length >= 0, length <= maxFileSize else {
            reply(413, "Upload limit is 20 GiB per file")
            return
        }
        guard let name = query.first(where: { $0.name == "name" })?.value,
              !name.isEmpty, !name.hasPrefix("."), !name.contains("/"), !name.contains("\\"),
              !name.unicodeScalars.contains(where: { $0.value < 32 || $0.value == 127 }), name.utf8.count <= 220 else {
            reply(400, "Unsupported filename")
            return
        }
        var id: UUID?
        var total = length
        var offset = 0
        if let idField = query.first(where: { $0.name == "id" }) {
            guard let rawID = idField.value, let uploadID = UUID(uuidString: rawID),
                  let rawTotal = query.first(where: { $0.name == "total" })?.value, let fileSize = Int(rawTotal),
                  let rawOffset = query.first(where: { $0.name == "offset" })?.value, let start = Int(rawOffset),
                  fileSize >= 0, fileSize <= maxFileSize, start >= 0, start <= fileSize,
                  length <= min(8 * 1024 * 1024, fileSize - start), length > 0 || fileSize == 0 else {
                reply(400, "Invalid upload range")
                return
            }
            id = uploadID
            total = fileSize
            offset = start
        }

        server.expireUploads()
        let record: UploadRecord
        if let id, let existing = server.uploads[id] {
            guard name == existing.name, total == existing.total else { reply(400, "Upload details changed"); return }
            existing.lastUsed = .now
            if existing.active || existing.savedAs != nil || existing.offset != offset {
                replyProgress(existing.progress)
                return
            }
            record = existing
        } else {
            guard offset == 0 else { replyProgress(["offset": 0]); return }
            if id != nil, server.uploads.count >= 4096 || server.uploads.values.filter({ $0.savedAs == nil }).count >= 16 {
                reply(429, "Too many saved uploads. Try again later or start a new session.")
                return
            }
            if let free = try? folder.resourceValues(forKeys: [.volumeAvailableCapacityKey]).volumeAvailableCapacity,
               total > free {
                reply(507, "Not enough free space on the Mac")
                return
            }
            record = UploadRecord(name: name, total: total)
        }

        do {
            if let temp = record.temporaryFile {
                let fd = Darwin.open(temp.path, O_WRONLY | O_NONBLOCK | O_NOFOLLOW)
                guard fd >= 0 else {
                    if errno == ENOENT, let id {
                        server.uploads.removeValue(forKey: id)
                        replyProgress(["offset": 0])
                        return
                    }
                    throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
                }
                let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
                guard let version = FileVersion(descriptor: fd), version.size >= offset else {
                    try? handle.close()
                    record.removeTemporaryFile()
                    if let id { server.uploads.removeValue(forKey: id) }
                    replyProgress(["offset": 0])
                    return
                }
                try handle.truncate(atOffset: UInt64(offset))
                try handle.seek(toOffset: UInt64(offset))
                uploadHandle = handle
            } else {
                let temp = folder.appendingPathComponent(".relay-\(UUID().uuidString).part")
                let fd = Darwin.open(temp.path, O_WRONLY | O_CREAT | O_EXCL, S_IRUSR | S_IWUSR)
                guard fd >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
                record.temporaryFile = temp
                uploadHandle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            }
            record.active = true
            if let id { server.uploads[id] = record }
            upload = record
            resumable = id != nil
            expectedBytes = length
            touch()
            beginPowerActivity()
            consumeUpload(body)
        } catch { replyUploadError(error) }
    }

    private func consumeUpload(_ data: Data) {
        guard let upload, let handle = uploadHandle, let folder = server.receiveFolder else { return }
        guard data.count <= expectedBytes - receivedBytes else { reply(400, "Body exceeds declared size"); return }
        do {
            try handle.write(contentsOf: data)
            receivedBytes += data.count
            guard receivedBytes == expectedBytes else { return }

            let nextOffset = upload.offset + receivedBytes
            if nextOffset == upload.total, let temp = upload.temporaryFile {
                let name = try finishUpload(temp, in: folder, named: upload.name)
                upload.temporaryFile = nil
                upload.savedAs = name
                server.onActivity?(.received(name))
            }
            upload.offset = nextOffset
            upload.active = false
            upload.lastUsed = .now
            try? handle.close()
            uploadHandle = nil
            self.upload = nil
            replyProgress(upload.progress)
        } catch { replyUploadError(error) }
    }

    private func finishUpload(_ temp: URL, in folder: URL, named name: String) throws -> String {
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        for suffix in 0..<10_000 {
            let candidate = suffix == 0 ? name : "\(base) (\(suffix))" + (ext.isEmpty ? "" : ".\(ext)")
            let target = folder.appendingPathComponent(candidate)
            do {
                try FileManager.default.moveItem(at: temp, to: target)
                return candidate
            } catch let error as CocoaError where error.code == .fileWriteFileExists {
                continue
            }
        }
        throw LocalTransferError.message("Could not find a free filename")
    }

    private func replyProgress(_ progress: [String: Any]) {
        do { reply(200, data: try JSONSerialization.data(withJSONObject: progress), type: "application/json") }
        catch { reply(500, "Could not report upload progress") }
    }

    private func replyUploadError(_ error: Error) {
        let nsError = error as NSError
        if (nsError.domain == NSPOSIXErrorDomain && nsError.code == Int(ENOSPC)) ||
            (nsError.domain == NSCocoaErrorDomain && nsError.code == CocoaError.fileWriteOutOfSpace.rawValue) {
            reply(507, "Not enough free space on the Mac")
        } else {
            reply(500, "Could not save the upload. Check free disk space and folder access.")
        }
    }

    private func beginPowerActivity() {
        powerActivity = ProcessInfo.processInfo.beginActivity(options: .idleSystemSleepDisabled, reason: "Transferring files with Relay")
    }

    private func download(_ url: URL, version: FileVersion, range: String?, ifRange: String?, headOnly: Bool) {
        do {
            let fd = Darwin.open(url.path, O_RDONLY | O_NONBLOCK | O_NOFOLLOW)
            guard fd >= 0 else { reply(404, "This file is no longer readable on the Mac"); return }
            let handle = FileHandle(fileDescriptor: fd, closeOnDealloc: true)
            downloadHandle = handle
            guard FileVersion(descriptor: fd) == version else {
                reply(409, "This file changed. Stop sharing and select it again on the Mac.")
                return
            }
            downloadVersion = version
            let size = version.size
            var start = 0
            var end = size - 1
            var partial = false
            if let range, !headOnly, ifRange == nil || ifRange == version.tag {
                guard range.hasPrefix("bytes="), !range.contains(",") else { rejectRange(size: size); return }
                let bounds = range.dropFirst(6).split(separator: "-", omittingEmptySubsequences: false)
                guard bounds.count == 2, size > 0 else { rejectRange(size: size); return }
                if bounds[0].isEmpty {
                    guard let suffix = Int(bounds[1]), suffix > 0 else { rejectRange(size: size); return }
                    start = max(0, size - suffix)
                } else {
                    guard let first = Int(bounds[0]), first >= 0 else { rejectRange(size: size); return }
                    start = first
                    if !bounds[1].isEmpty {
                        guard let last = Int(bounds[1]) else { rejectRange(size: size); return }
                        end = min(last, size - 1)
                    }
                }
                guard start < size, end >= start else { rejectRange(size: size); return }
                partial = true
            }
            try handle.seek(toOffset: UInt64(start))
            let length = max(0, end - start + 1)
            let filename = url.lastPathComponent.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? "file"
            var extra = "Content-Disposition: attachment; filename=\"download\"; filename*=UTF-8''\(filename)\r\nAccept-Ranges: bytes\r\n"
            extra += "ETag: \(version.tag)\r\n"
            if partial { extra += "Content-Range: bytes \(start)-\(end)/\(size)\r\n" }
            responding = true
            downloadRemaining = length
            downloadName = url.lastPathComponent
            if !headOnly { beginPowerActivity() }
            let header = responseHeader(code: partial ? 206 : 200, count: length, type: "application/octet-stream", extra: extra)
            connection.send(content: Data(header.utf8), completion: .contentProcessed { [weak self] error in
                guard let self else { return }
                if error != nil || headOnly { self.close() } else { self.sendNextChunk() }
            })
        } catch { reply(404, "This file is no longer readable on the Mac") }
    }

    private func sendNextChunk() {
        guard !finished else { return }
        guard downloadRemaining > 0 else {
            server.onActivity?(.served(downloadName))
            close()
            return
        }
        do {
            guard let handle = downloadHandle,
                  let data = try handle.read(upToCount: min(262144, downloadRemaining)), !data.isEmpty,
                  FileVersion(descriptor: handle.fileDescriptor) == downloadVersion else { close(); return }
            downloadRemaining -= data.count
            touch()
            connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if error != nil { self?.close() } else { self?.sendNextChunk() }
            })
        } catch { close() }
    }

    private func rejectRange(size: Int) {
        reply(416, data: Data("Invalid range".utf8), type: "text/plain; charset=utf-8", extra: "Content-Range: bytes */\(size)\r\n")
    }

    private func responseHeader(code: Int, count: Int, type: String, extra: String = "") -> String {
        let reason = [200: "OK", 206: "Partial Content", 400: "Bad Request", 403: "Forbidden", 404: "Not Found", 405: "Method Not Allowed", 409: "Conflict", 429: "Too Many Requests", 507: "Insufficient Storage", 413: "Content Too Large", 416: "Range Not Satisfiable", 431: "Headers Too Large", 500: "Internal Server Error"][code] ?? "Error"
        return "HTTP/1.1 \(code) \(reason)\r\nContent-Length: \(count)\r\nContent-Type: \(type)\r\nConnection: close\r\nCache-Control: no-store\r\nReferrer-Policy: no-referrer\r\nX-Content-Type-Options: nosniff\r\nContent-Security-Policy: default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'\r\n\(extra)\r\n"
    }

    private func reply(_ code: Int, _ text: String) { reply(code, data: Data(text.utf8), type: "text/plain; charset=utf-8") }

    private func reply(_ code: Int, data: Data, type: String, extra: String = "") {
        guard !responding, !finished else { return }
        responding = true
        var message = Data(responseHeader(code: code, count: data.count, type: type, extra: extra).utf8)
        message.append(data)
        connection.send(content: message, completion: .contentProcessed { [weak self] _ in self?.close() })
    }
}
