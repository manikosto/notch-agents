// Рендерит иконку приложения: 👾 на чёрной скруглённой плашке.
// Запуск: swift scripts/make-icon.swift <output.png>
import AppKit

let out = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "icon-1024.png"
let side: CGFloat = 1024

let image = NSImage(size: NSSize(width: side, height: side))
image.lockFocus()

let inset: CGFloat = 100
let plate = NSBezierPath(roundedRect: NSRect(x: inset, y: inset,
                                             width: side - inset * 2, height: side - inset * 2),
                         xRadius: 185, yRadius: 185)
NSColor.black.setFill()
plate.fill()

let glyph = NSAttributedString(string: "👾", attributes: [.font: NSFont.systemFont(ofSize: 560)])
let gSize = glyph.size()
glyph.draw(at: NSPoint(x: (side - gSize.width) / 2, y: (side - gSize.height) / 2))

image.unlockFocus()

guard let tiff = image.tiffRepresentation,
      let rep = NSBitmapImageRep(data: tiff),
      let png = rep.representation(using: .png, properties: [:]) else {
    fatalError("failed to render icon")
}
try! png.write(to: URL(fileURLWithPath: out))
print("icon written: \(out)")
