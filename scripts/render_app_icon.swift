import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

// Render the pinned WOOW Android vector without redrawing its brand geometry.
// Run from the repository root: swift scripts/render_app_icon.swift
enum IconError: Error { case invalidSource, invalidPath, cannotRender }
final class IconSource: NSObject, XMLParserDelegate {
    var width = 0.0; var height = 0.0
    var transform = CGAffineTransform.identity
    var paths: [(String, String)] = []
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?,
                qualifiedName: String?, attributes: [String: String]) {
        if element == "vector" {
            width = Double(attributes["android:viewportWidth"] ?? "") ?? 0
            height = Double(attributes["android:viewportHeight"] ?? "") ?? 0
        } else if element == "group" {
            transform = CGAffineTransform(translationX: Double(attributes["android:translateX"] ?? "") ?? 0,
                                          y: Double(attributes["android:translateY"] ?? "") ?? 0)
                .scaledBy(x: Double(attributes["android:scaleX"] ?? "") ?? 1,
                          y: Double(attributes["android:scaleY"] ?? "") ?? 1)
        } else if element == "path", let data = attributes["android:pathData"], let color = attributes["android:fillColor"] {
            paths.append((data, color))
        }
    }
}
func path(_ text: String) throws -> CGPath {
    let expression = try NSRegularExpression(pattern: "[A-Za-z]|[-+]?(?:[0-9]*[.])?[0-9]+(?:[eE][-+]?[0-9]+)?")
    let source = text as NSString
    let tokens = expression.matches(in: text, range: NSRange(location: 0, length: source.length)).map { source.substring(with: $0.range) }
    var index = 0
    func point() throws -> CGPoint {
        guard index + 1 < tokens.count, let x = Double(tokens[index]), let y = Double(tokens[index + 1]) else { throw IconError.invalidPath }
        index += 2; return CGPoint(x: x, y: y)
    }
    let result = CGMutablePath()
    while index < tokens.count {
        let command = tokens[index]; index += 1
        switch command {
        case "M": result.move(to: try point())
        case "L": result.addLine(to: try point())
        case "C":
            let a = try point(), b = try point(), end = try point()
            result.addCurve(to: end, control1: a, control2: b)
        case "Z": result.closeSubpath()
        default: throw IconError.invalidPath
        }
    }
    return result
}
let sourceURL = URL(fileURLWithPath: "Configuration/Brand/woow_launcher_foreground.xml")
let delegate = IconSource()
guard let parser = XMLParser(contentsOf: sourceURL) else { throw IconError.invalidSource }
parser.delegate = delegate
guard parser.parse(), delegate.width == 108, delegate.height == 108, delegate.paths.count == 10 else { throw IconError.invalidSource }
let size = 1024
let colorSpace = CGColorSpace(name: CGColorSpace.sRGB)!
guard let context = CGContext(data: nil, width: size, height: size, bitsPerComponent: 8, bytesPerRow: size * 4,
    space: colorSpace, bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue) else { throw IconError.cannotRender }
context.setFillColor(CGColor(colorSpace: colorSpace, components: [33/255.0, 33/255.0, 33/255.0, 1])!)
context.fill(CGRect(x: 0, y: 0, width: size, height: size))
context.translateBy(x: 0, y: CGFloat(size)); context.scaleBy(x: CGFloat(size)/108, y: -CGFloat(size)/108)
context.concatenate(delegate.transform)
for (data, color) in delegate.paths {
    guard color == "#FF6183FC" else { throw IconError.invalidSource }
    context.setFillColor(CGColor(colorSpace: colorSpace, components: [97/255.0, 131/255.0, 252/255.0, 1])!)
    context.addPath(try path(data)); context.fillPath()
}
let output = URL(fileURLWithPath: "Sources/App/Assets.xcassets/AppIcon.appiconset/AppIcon.png")
guard let image = context.makeImage(), let destination = CGImageDestinationCreateWithURL(output as CFURL, UTType.png.identifier as CFString, 1, nil) else { throw IconError.cannotRender }
CGImageDestinationAddImage(destination, image, nil)
guard CGImageDestinationFinalize(destination), let decoded = CGImageSourceCreateWithURL(output as CFURL, nil),
      let properties = CGImageSourceCopyPropertiesAtIndex(decoded, 0, nil) as? [CFString: Any],
      properties[kCGImagePropertyPixelWidth] as? Int == size, properties[kCGImagePropertyPixelHeight] as? Int == size,
      properties[kCGImagePropertyHasAlpha] as? Bool != true else { throw IconError.cannotRender }
print("Rendered 1024x1024 opaque WOOW icon from 10 pinned vector paths.")
