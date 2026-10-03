import AppKit

let output = URL(fileURLWithPath: CommandLine.arguments[1])
let iconset = output.appendingPathComponent("AppIcon.iconset")
try FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
for size in [16, 32, 128, 256, 512] {
    for scale in [1, 2] {
        let pixels = size * scale
        let image = NSImage(size: NSSize(width: pixels, height: pixels))
        image.lockFocus()
        let factor = CGFloat(pixels) / 512
        let transform = NSAffineTransform()
        transform.scale(by: factor)
        transform.concat()
        let background = NSBezierPath(roundedRect: NSRect(x: 12, y: 12, width: 488, height: 488), xRadius: 108, yRadius: 108)
        NSGradient(starting: NSColor(calibratedRed: 0.10, green: 0.26, blue: 0.23, alpha: 1), ending: NSColor(calibratedRed: 0.29, green: 0.54, blue: 0.44, alpha: 1))!.draw(in: background, angle: 65)
        NSColor(calibratedRed: 0.93, green: 0.80, blue: 0.53, alpha: 1).setFill()
        NSBezierPath(ovalIn: NSRect(x: 318, y: 309, width: 66, height: 66)).fill()
        let mountain = NSBezierPath()
        mountain.move(to: NSPoint(x: 62, y: 128))
        mountain.line(to: NSPoint(x: 206, y: 343))
        mountain.line(to: NSPoint(x: 283, y: 234))
        mountain.line(to: NSPoint(x: 332, y: 291))
        mountain.line(to: NSPoint(x: 453, y: 128))
        mountain.close()
        NSColor(calibratedRed: 0.85, green: 0.92, blue: 0.83, alpha: 1).setFill(); mountain.fill()
        let front = NSBezierPath()
        front.move(to: NSPoint(x: 62, y: 128)); front.line(to: NSPoint(x: 231, y: 222))
        front.line(to: NSPoint(x: 360, y: 128)); front.close()
        NSColor(calibratedRed: 0.55, green: 0.73, blue: 0.61, alpha: 1).setFill(); front.fill()
        image.unlockFocus()
        let bitmap = NSBitmapImageRep(data: image.tiffRepresentation!)!
        let name = "icon_\(size)x\(size)\(scale == 2 ? "@2x" : "").png"
        try bitmap.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
    }
}
let task = Process()
task.executableURL = URL(fileURLWithPath: "/usr/bin/iconutil")
task.arguments = ["-c", "icns", iconset.path, "-o", output.appendingPathComponent("AppIcon.icns").path]
try task.run(); task.waitUntilExit()
guard task.terminationStatus == 0 else { fatalError("Icon conversion failed") }
try FileManager.default.removeItem(at: iconset)
