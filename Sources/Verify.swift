import AppKit
import Vision

enum VerificationError: Error { case failed(String) }

@MainActor
func verifyRelay() throws {
    func check(_ condition: Bool, _ message: String) throws {
        guard condition else { throw VerificationError.failed(message) }
        print("PASS: \(message)")
    }
    let fm = FileManager.default
    let folder = fm.temporaryDirectory.appendingPathComponent("Relay-verify-\(UUID().uuidString)")
    try fm.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? fm.removeItem(at: folder) }
    let file = folder.appendingPathComponent("example.txt")
    try "example".write(to: file, atomically: true, encoding: .utf8)
    let model = TransferModel()
    model.addFiles([file, file, folder, folder])
    try check(model.outgoing.count == 2 && !model.outgoing[0].isFolder && model.outgoing[1].isFolder,
              "Send queue deduplicates items and accepts folders")

    let shared = folder.appendingPathComponent("Shared Ünïcode")
    let nested = shared.appendingPathComponent("nested/deeper")
    try fm.createDirectory(at: nested, withIntermediateDirectories: true)
    try fm.createDirectory(at: shared.appendingPathComponent("empty"), withIntermediateDirectories: true)
    let contents: [String: Data] = [
        "top.txt": Data("top level".utf8),
        "empty.bin": Data(),
        "nested/deeper/random.bin": Data((0..<700_003).map { UInt8(truncatingIfNeeded: $0 &* 2654435761 >> 13) }),
        "nested/café.txt": Data("accents".utf8),
    ]
    for (path, data) in contents { try data.write(to: shared.appendingPathComponent(path)) }
    try Data("secret".utf8).write(to: shared.appendingPathComponent(".hidden"))
    try fm.createSymbolicLink(atPath: shared.appendingPathComponent("link").path, withDestinationPath: file.path)

    func run(_ tool: String, _ arguments: [String]) throws -> Int32 {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        process.waitUntilExit()
        return process.terminationStatus
    }
    for forceZip64 in [false, true] {
        let label = forceZip64 ? "ZIP64 folder archive" : "Folder archive"
        let archive = try FolderArchive(folder: shared, forceZip64: forceZip64)
        let reader = FolderZipReader(archive)
        var zip = Data()
        while true {
            let chunk = try reader.read(upTo: 65_521)
            if chunk.isEmpty { break }
            zip.append(chunk)
        }
        try check(zip.count == archive.length && archive.fileCount == contents.count, "\(label) streams exactly its advertised length")
        let zipURL = folder.appendingPathComponent(forceZip64 ? "zip64.zip" : "plain.zip")
        try zip.write(to: zipURL)
        try check(try run("/usr/bin/unzip", ["-tq", zipURL.path]) == 0, "\(label) passes CRC checks")
        let output = folder.appendingPathComponent(forceZip64 ? "out64" : "out")
        try check(try run("/usr/bin/ditto", ["-x", "-k", zipURL.path, output.path]) == 0, "\(label) extracts with ditto")
        let root = output.appendingPathComponent(shared.lastPathComponent)
        let matches = try contents.allSatisfy { path, data in try Data(contentsOf: root.appendingPathComponent(path)) == data }
        try check(matches && fm.fileExists(atPath: root.appendingPathComponent("empty").path), "\(label) restores files, names, and empty folders")
        try check(!fm.fileExists(atPath: root.appendingPathComponent(".hidden").path) &&
                  !fm.fileExists(atPath: root.appendingPathComponent("link").path), "\(label) leaves out hidden files and links")
    }

    let local = LocalTransferModel()
    let qrURL = URL(string: "http://192.168.1.2:54321/s/" + String(repeating: "ab", count: 32) + "/")!
    guard let image = local.qrImage(for: qrURL)?.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        throw VerificationError.failed("Could not create the session QR code")
    }
    let barcode = VNDetectBarcodesRequest()
    barcode.symbologies = [.qr]
    try VNImageRequestHandler(cgImage: image).perform([barcode])
    try check(barcode.results?.first?.payloadStringValue == qrURL.absoluteString, "The QR code decodes to the exact private session URL")
}
