import AppKit
import Foundation

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
let output = root.appendingPathComponent("Resources/icons", isDirectory: true)
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)

let symbols: [(String, String)] = [
    ("gauge.with.dots.needle.67percent", "status"),
    ("clock", "history"),
    ("link", "connections"),
    ("gearshape", "settings"),
    ("chevron.right", "disclosure"),
    ("arrow.clockwise", "refresh")
]

for (symbolName, fileName) in symbols {
    guard let base = NSImage(systemSymbolName: symbolName, accessibilityDescription: nil),
          let symbol = base.withSymbolConfiguration(.init(pointSize: 26, weight: .regular).applying(.init(paletteColors: [.white]))) else {
        fputs("missing SF Symbol: \(symbolName)\n", stderr)
        exit(2)
    }

    let canvas = NSImage(size: NSSize(width: 64, height: 64))
    canvas.lockFocus()
    NSColor.clear.setFill()
    NSRect(x: 0, y: 0, width: 64, height: 64).fill()
    let size = symbol.size
    let scale = min(46 / size.width, 46 / size.height)
    let target = NSRect(
        x: (64 - size.width * scale) / 2,
        y: (64 - size.height * scale) / 2,
        width: size.width * scale,
        height: size.height * scale
    )
    symbol.draw(in: target)
    canvas.unlockFocus()

    guard let tiff = canvas.tiffRepresentation,
          let bitmap = NSBitmapImageRep(data: tiff),
          let png = bitmap.representation(using: .png, properties: [:]) else {
        fputs("failed to encode SF Symbol: \(symbolName)\n", stderr)
        exit(3)
    }
    try png.write(to: output.appendingPathComponent("\(fileName).png"))
}
