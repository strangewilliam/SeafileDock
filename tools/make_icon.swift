import AppKit
import CoreGraphics

let base: CGFloat = 1024

func scaled(_ v: CGFloat, _ size: Int) -> CGFloat { v * CGFloat(size) / base }

func makeCGImage(_ size: Int) -> CGImage {
    let cs = CGColorSpaceCreateDeviceRGB()
    let ctx = CGContext(data: nil, width: size, height: size,
                        bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!

    // 背景透明
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))

    // 圆角矩形底板（经典 macOS app icon 圆角比例）
    let pad = scaled(56, size)
    let rect = CGRect(x: pad, y: pad, width: CGFloat(size) - 2*pad, height: CGFloat(size) - 2*pad)
    let radius = scaled(214, size)
    let bgPath = CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)

    // 蓝色渐变（上浅下深）
    let top = CGColor(colorSpace: cs, components: [0.36, 0.66, 1.0, 1.0])!
    let bottom = CGColor(colorSpace: cs, components: [0.06, 0.32, 0.85, 1.0])!
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [top, bottom] as CFArray, locations: [0, 1])!,
                           start: CGPoint(x: 0, y: CGFloat(size)),
                           end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    // 顶部柔和高光，增加立体感
    ctx.saveGState()
    ctx.addPath(bgPath)
    ctx.clip()
    let hi1 = CGColor(colorSpace: cs, components: [1, 1, 1, 0.20])!
    let hi2 = CGColor(colorSpace: cs, components: [1, 1, 1, 0.0])!
    ctx.drawLinearGradient(CGGradient(colorsSpace: cs, colors: [hi1, hi2] as CFArray, locations: [0, 0.55])!,
                           start: CGPoint(x: 0, y: CGFloat(size)),
                           end: CGPoint(x: 0, y: 0), options: [])
    ctx.restoreGState()

    let white = CGColor(colorSpace: cs, components: [1, 1, 1, 1])!
    ctx.setFillColor(white)

    // 云朵：三个圆叠加 + 底部圆角矩形
    let cy = scaled(585, size)
    let r1 = scaled(112, size), r2 = scaled(146, size), r3 = scaled(122, size)
    ctx.fillEllipse(in: CGRect(x: scaled(300, size)-r1, y: cy-r1, width: 2*r1, height: 2*r1))
    ctx.fillEllipse(in: CGRect(x: scaled(512, size)-r2, y: cy+scaled(40, size)-r2, width: 2*r2, height: 2*r2))
    ctx.fillEllipse(in: CGRect(x: scaled(724, size)-r3, y: cy-r3, width: 2*r3, height: 2*r3))
    let body = CGRect(x: scaled(300, size), y: cy-scaled(96, size),
                      width: scaled(424, size), height: scaled(150, size))
    ctx.fill(body)

    // 中间上下双箭头（同步/上传下载）
    let arrowColor = CGColor(colorSpace: cs, components: [1.0, 1.0, 1.0, 0.95])!
    ctx.setFillColor(arrowColor)
    // 上箭头
    let upStem = CGRect(x: scaled(492, size), y: scaled(300, size),
                        width: scaled(40, size), height: scaled(118, size))
    ctx.fill(upStem)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: scaled(512, size), y: scaled(452, size)))
    ctx.addLine(to: CGPoint(x: scaled(440, size), y: scaled(378, size)))
    ctx.addLine(to: CGPoint(x: scaled(584, size), y: scaled(378, size)))
    ctx.closePath()
    ctx.fillPath()
    // 下箭头
    let downStem = CGRect(x: scaled(492, size), y: scaled(158, size),
                          width: scaled(40, size), height: scaled(118, size))
    ctx.fill(downStem)
    ctx.beginPath()
    ctx.move(to: CGPoint(x: scaled(512, size), y: scaled(122, size)))
    ctx.addLine(to: CGPoint(x: scaled(440, size), y: scaled(196, size)))
    ctx.addLine(to: CGPoint(x: scaled(584, size), y: scaled(196, size)))
    ctx.closePath()
    ctx.fillPath()

    return ctx.makeImage()!
}

func savePNG(_ image: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: image)
    let data = rep.representation(using: .png, properties: [:])!
    try! data.write(to: URL(fileURLWithPath: path))
}

let outDir = CommandLine.arguments[1]
let fm = FileManager.default
try! fm.createDirectory(atPath: outDir, withIntermediateDirectories: true)

let specs: [(String, Int)] = [
    ("icon_16x16.png", 16), ("icon_16x16@2x.png", 32),
    ("icon_32x32.png", 32), ("icon_32x32@2x.png", 64),
    ("icon_128x128.png", 128), ("icon_128x128@2x.png", 256),
    ("icon_256x256.png", 256), ("icon_256x256@2x.png", 512),
    ("icon_512x512.png", 512), ("icon_512x512@2x.png", 1024),
]
for (name, size) in specs {
    savePNG(makeCGImage(size), outDir + "/" + name)
}
print("生成 \(specs.count) 个尺寸到 \(outDir)")
