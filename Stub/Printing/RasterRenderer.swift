import CoreGraphics
import Foundation
import UIKit

/// 将屏幕收据布局转换为 P1 所需的 384 点宽、1 bit 黑白位图。
/// P1 不接收图片文件；所有字体、分隔线和勾选框都必须先在手机上栅格化。
enum RasterRenderer {
    static let width = P1Protocol.widthDots

    @MainActor
    static func render(document: ReceiptDocument) -> Data {
        // 先按屏幕预览的顺序绘制完整收据，再统一转换为热敏点阵，
        // 这样打印内容与用户编辑时看到的布局保持一致。
        let sections = document.sections.sorted { $0.order < $1.order }
        let height = max(180, 150 + sections.reduce(0) { $0 + 72 + ($1.items.count * 44) })
        let format = UIGraphicsImageRendererFormat()
        format.scale = 1
        format.opaque = true
        let renderer = UIGraphicsImageRenderer(size: CGSize(width: width, height: height), format: format)
        let image = renderer.image { context in
            UIColor.white.setFill()
            context.fill(CGRect(x: 0, y: 0, width: width, height: height))

            let margin: CGFloat = 20
            var y: CGFloat = 16
            draw(document.brand, at: CGPoint(x: margin, y: y), size: 34, weight: .black, centered: true)
            y += 38
            draw(document.subtitle, at: CGPoint(x: margin, y: y), size: 16, weight: .light, centered: true, tracking: 3)
            y += 36
            draw(ReceiptDocument.todayText(), at: CGPoint(x: margin, y: y), size: 28, weight: .bold)
            y += 39
            draw(document.slogan, in: CGRect(x: margin, y: y, width: CGFloat(width) - 2 * margin, height: 26), size: 15, weight: .semibold, inverted: true)
            y += 39

            for section in sections {
                let lineY = y
                UIColor.black.withAlphaComponent(0.16).setStroke()
                let path = UIBezierPath()
                path.move(to: CGPoint(x: margin, y: lineY))
                path.addLine(to: CGPoint(x: CGFloat(width) - margin, y: lineY))
                path.lineWidth = 1
                path.stroke()
                y += 16
                draw(section.title, at: CGPoint(x: margin, y: y), size: 25, weight: .black)
                draw(section.subtitle, in: CGRect(x: CGFloat(width) - 145, y: y + 4, width: 125, height: 24), size: 13, weight: .bold, alignment: .right)
                y += 34

                for item in section.items.sorted(by: { $0.order < $1.order }) {
                    draw("○", at: CGPoint(x: margin, y: y), size: 25, weight: .regular)
                    draw(item.text, in: CGRect(x: margin + 32, y: y, width: CGFloat(width) - margin * 2 - 105, height: 32), size: 19, weight: .regular)
                    draw(item.detail, in: CGRect(x: CGFloat(width) - margin - 78, y: y + 3, width: 78, height: 26), size: 14, weight: .regular, alignment: .right)
                    y += 44
                }
            }

            UIColor.black.withAlphaComponent(0.22).setStroke()
            let footer = UIBezierPath()
            footer.move(to: CGPoint(x: margin, y: CGFloat(height) - 45))
            footer.addLine(to: CGPoint(x: CGFloat(width) - margin, y: CGFloat(height) - 45))
            footer.lineWidth = 1
            footer.stroke()
            draw(
                "Printed with Stub.",
                in: CGRect(x: margin, y: CGFloat(height) - 38, width: CGFloat(width) - margin * 2, height: 24),
                size: 14,
                weight: .bold,
                alignment: .center
            )
        }

        return pack(image: image, width: width, height: height)
    }

    private static func draw(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        weight: UIFont.Weight,
        centered: Bool = false,
        tracking: CGFloat = 0,
        inverted: Bool = false
    ) {
        let attributes = attributes(size: size, weight: weight, tracking: tracking, color: inverted ? .white : .black)
        let string = NSString(string: text)
        let textSize = string.size(withAttributes: attributes)
        let x = centered ? (CGFloat(width) - textSize.width) / 2 : point.x
        if inverted {
            UIColor.black.setFill()
            UIBezierPath(rect: CGRect(x: 0, y: point.y, width: CGFloat(width), height: 24)).fill()
        }
        string.draw(at: CGPoint(x: x, y: point.y), withAttributes: attributes)
    }

    private static func draw(
        _ text: String,
        in rect: CGRect,
        size: CGFloat,
        weight: UIFont.Weight,
        alignment: NSTextAlignment = .left,
        inverted: Bool = false
    ) {
        if inverted {
            UIColor.black.setFill()
            UIBezierPath(rect: rect).fill()
        }
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = alignment
        let attributes = attributes(size: size, weight: weight, tracking: 0, color: inverted ? .white : .black, paragraph: paragraph)
        NSString(string: text).draw(in: rect, withAttributes: attributes)
    }

    private static func attributes(size: CGFloat, weight: UIFont.Weight, tracking: CGFloat, color: UIColor, paragraph: NSParagraphStyle? = nil) -> [NSAttributedString.Key: Any] {
        var values: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
        ]
        if tracking != 0 { values[.kern] = tracking }
        if let paragraph { values[.paragraphStyle] = paragraph }
        return values
    }

    private static func pack(image: UIImage, width: Int, height: Int) -> Data {
        guard let cgImage = image.cgImage,
              let colorSpace = CGColorSpace(name: CGColorSpace.genericGrayGamma2_2),
              let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: width,
                space: colorSpace,
                bitmapInfo: CGImageAlphaInfo.none.rawValue
              ),
              let destination = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return Data() }

        context.setFillColor(gray: 1, alpha: 1)
        context.fill(CGRect(x: 0, y: 0, width: width, height: height))
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))

        var raster = Data(capacity: width / 8 * height)
        for row in 0..<height {
            // Core Graphics 的 bitmap 行从底部开始，而 P1 期望第一行是纸条顶部，
            // 所以这里反转垂直行序。
            let sourceRow = destination + (height - 1 - row) * width
            for byteOffset in stride(from: 0, to: width, by: 8) {
                var value: UInt8 = 0
                // P1 打印头从相反的水平边读取扫描线，必须反转整行像素，
                // 不能只反转每个字节内的 bit，否则打印结果会镜像。
                // 阈值化后只发送 0/1 黑白点，避免灰阶数据被 P1 当作异常值。
                for bit in 0..<8 where sourceRow[width - 1 - (byteOffset + bit)] < 180 {
                    value |= 1 << (7 - bit)
                }
                raster.append(value)
            }
        }
        return raster
    }
}
