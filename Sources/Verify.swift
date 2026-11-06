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
    model.addFiles([file, file, folder])
    try check(model.outgoing.count == 1, "Send queue deduplicates files and skips folders")

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
