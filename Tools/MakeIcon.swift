import AppKit

let iconset = URL(fileURLWithPath: CommandLine.arguments[1], isDirectory: true)
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)

func renderIcon(pixels: Int) throws -> Data {
    let context = CGContext(
        data: nil, width: pixels, height: pixels,
        bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    )!
    let scale = CGFloat(pixels) / 1024
    context.translateBy(x: 0, y: CGFloat(pixels))
    context.scaleBy(x: scale, y: -scale)

    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    context.setFillColor(red: 0.12, green: 0.31, blue: 0.84, alpha: 1)
    context.addPath(CGPath(roundedRect: tile, cornerWidth: 190, cornerHeight: 190, transform: nil))
    context.fillPath()

    context.setStrokeColor(red: 0.97, green: 0.99, blue: 1, alpha: 1)
    context.setLineWidth(64)
    context.setLineCap(.round)
    context.setLineJoin(.round)
    context.move(to: CGPoint(x: 312, y: 408))
    context.addLine(to: CGPoint(x: 708, y: 408))
    context.move(to: CGPoint(x: 604, y: 304))
    context.addLine(to: CGPoint(x: 708, y: 408))
    context.addLine(to: CGPoint(x: 604, y: 512))
    context.strokePath()

    context.setStrokeColor(red: 0.69, green: 0.91, blue: 1, alpha: 1)
    context.move(to: CGPoint(x: 712, y: 616))
    context.addLine(to: CGPoint(x: 316, y: 616))
    context.move(to: CGPoint(x: 420, y: 512))
    context.addLine(to: CGPoint(x: 316, y: 616))
    context.addLine(to: CGPoint(x: 420, y: 720))
    context.strokePath()

    let bitmap = NSBitmapImageRep(cgImage: context.makeImage()!)
    return bitmap.representation(using: .png, properties: [:])!
}

for size in [16, 32, 128, 256, 512] {
    try renderIcon(pixels: size).write(to: iconset.appendingPathComponent("icon_\(size)x\(size).png"))
    try renderIcon(pixels: size * 2).write(to: iconset.appendingPathComponent("icon_\(size)x\(size)@2x.png"))
}
