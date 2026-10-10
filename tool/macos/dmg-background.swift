// Draws the DMG window background make-dmg.sh ships. Design units are the
// window's points, 600x400; the two PNGs it writes (1x at 72dpi, 2x at 144)
// are merged into one TIFF per screen scale, which Finder reads the layout's
// background from. make-dmg.sh runs this and the tiffutil merge into its
// staging volume on every styled build; to iterate on the look by hand:
//   swift tool/macos/dmg-background.swift /tmp/dmg-1x.png /tmp/dmg-2x.png
//   tiffutil -cathidpicheck /tmp/dmg-1x.png /tmp/dmg-2x.png \
//       -out /tmp/dmg-background.tiff
// (A single 2x PNG at 72dpi is what Finder drew unscaled and cropped once —
// hence the layered TIFF rather than one image. qlmanage's SVG thumbnails are
// not used either: they mis-center text.)
import CoreGraphics
import CoreText
import Foundation
import ImageIO
import UniformTypeIdentifiers

let w = CGFloat(600), h = CGFloat(400)

func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(
        red: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
        blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

// y below is from the top down: the context's origin is bottom-left, so the
// baseline y converts to `h - y` in CG space.
func render(_ scale: CGFloat) -> CGImage {
    let ctx = CGContext(
        data: nil, width: Int(w * scale), height: Int(h * scale), bitsPerComponent: 8,
        bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.scaleBy(x: scale, y: scale)

    // cookie.svg's bgGrad stops exactly — the app icon's square is the named
    // source for the palette, and typing it twice with one color "corrected"
    // is how icon and installer window drift apart.
    ctx.drawLinearGradient(
        CGGradient(
            colorsSpace: ctx.colorSpace!,
            colors: [rgb(0x6366F1), rgb(0x4F46E5), rgb(0x3B35C9)] as CFArray,
            locations: [0, 0.55, 1])!,
        start: CGPoint(x: 0, y: h), end: CGPoint(x: w, y: 0), options: [])
    ctx.drawRadialGradient(
        CGGradient(
            colorsSpace: ctx.colorSpace!,
            colors: [rgb(0xFFFFFF, 0.10), rgb(0xFFFFFF, 0)] as CFArray, locations: [0, 1])!,
        startCenter: CGPoint(x: w / 2, y: h), startRadius: 0,
        endCenter: CGPoint(x: w / 2, y: h), endRadius: 360, options: [])

    func drawLine(_ text: String, fontName: String, size: CGFloat, color: CGColor, y: CGFloat) {
        let font = CTFontCreateWithName(fontName as CFString, size, nil)
        let attributes = [
            kCTFontAttributeName: font,
            kCTForegroundColorAttributeName: color,
        ] as [NSAttributedString.Key: Any]
        let line = CTLineCreateWithAttributedString(
            NSAttributedString(string: text, attributes: attributes))
        // The return value is the width; the pointer params take the metrics.
        let lineWidth = CTLineGetTypographicBounds(line, nil, nil, nil)
        ctx.textPosition = CGPoint(x: (w - lineWidth) / 2, y: h - y)
        CTLineDraw(line, ctx)
    }

    drawLine("Entoli", fontName: "HelveticaNeue-Bold", size: 46, color: rgb(0xFFFFFF), y: 98)
    drawLine(
        "A coding agent on your machine", fontName: "HelveticaNeue", size: 19,
        color: rgb(0xFFFFFF, 0.72), y: 129)

    // Between the icon glyphs: make-dmg.sh centers them on 30% and 70% of
    // the window width, straddling the row line this arrow paints 65% down —
    // the same named fractions both files carry. Top-down here too, and the
    // same `h - y` conversion the texts get, CG's y being bottom-up; without
    // it the arrow paints 24pt below the icons, the drift a Finder DMG shows.
    let row = h * 0.65
    ctx.setStrokeColor(rgb(0xFFFFFF, 0.5))
    ctx.setLineWidth(6)
    ctx.setLineCap(.round)
    ctx.setLineJoin(.round)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: 250, y: h - row))
    ctx.addLine(to: CGPoint(x: 336, y: h - row))
    ctx.move(to: CGPoint(x: 322, y: h - (row - 14)))
    ctx.addLine(to: CGPoint(x: 350, y: h - row))
    ctx.addLine(to: CGPoint(x: 322, y: h - (row + 14)))
    ctx.strokePath()

    drawLine(
        "Drag Entoli into Applications to install", fontName: "HelveticaNeue", size: 17,
        color: rgb(0xFFFFFF, 0.62), y: 374)

    return ctx.makeImage()!
}

func write(_ image: CGImage, _ path: String, _ dpi: Int) {
    let destination = CGImageDestinationCreateWithURL(
        URL(fileURLWithPath: path) as CFURL, UTType.png.identifier as CFString, 1, nil)!
    CGImageDestinationAddImage(
        destination, image,
        [kCGImagePropertyDPIWidth: dpi, kCGImagePropertyDPIHeight: dpi]
            as [CFString: Any] as CFDictionary)
    CGImageDestinationFinalize(destination)
}

let out1x = CommandLine.arguments.count > 1 ? CommandLine.arguments[1] : "dmg-background-1x.png"
let out2x = CommandLine.arguments.count > 2 ? CommandLine.arguments[2] : "dmg-background-2x.png"
write(render(1), out1x, 72)
write(render(2), out2x, 144)
