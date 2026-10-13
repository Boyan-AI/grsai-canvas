#!/usr/bin/env swift

import AppKit
import Foundation

/// 描述 iconset 中一个文件对应的实际像素尺寸。
struct IconSlot {
    let fileName: String
    let pixels: Int
}

/// 描述 ICNS 容器中的一个 PNG 数据块。
struct ICNSChunk {
    let type: String
    let fileName: String
}

/// 把源图渲染为 iconutil 可接受的 RGBA PNG。
func render(source: NSImage, slot: IconSlot, outputDirectory: URL) throws {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: slot.pixels,
        pixelsHigh: slot.pixels,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bitmapFormat: [],
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else {
        throw CocoaError(.fileWriteUnknown)
    }

    bitmap.size = NSSize(width: slot.pixels, height: slot.pixels)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }
    guard let context = NSGraphicsContext(bitmapImageRep: bitmap) else {
        throw CocoaError(.fileWriteUnknown)
    }
    NSGraphicsContext.current = context
    context.imageInterpolation = .high
    let bounds = NSRect(x: 0, y: 0, width: slot.pixels, height: slot.pixels)
    NSColor.clear.setFill()
    bounds.fill()
    let cornerRadius = CGFloat(slot.pixels) * 0.22
    NSBezierPath(roundedRect: bounds, xRadius: cornerRadius, yRadius: cornerRadius).addClip()
    source.draw(
        in: bounds,
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    context.flushGraphics()

    guard let data = bitmap.representation(using: .png, properties: [:]) else {
        throw CocoaError(.fileWriteUnknown)
    }
    try data.write(to: outputDirectory.appendingPathComponent(slot.fileName), options: .atomic)
}

/// 把整数编码为 ICNS 要求的大端 32 位长度。
func bigEndianData(_ value: UInt32) -> Data {
    var encoded = value.bigEndian
    return Data(bytes: &encoded, count: MemoryLayout<UInt32>.size)
}

/// 将标准 RGBA PNG 槽位写入 ICNS 容器。
func writeICNS(chunks: [ICNSChunk], iconsetDirectory: URL, outputURL: URL) throws {
    var body = Data()
    for chunk in chunks {
        guard let typeData = chunk.type.data(using: .ascii), typeData.count == 4 else {
            throw CocoaError(.fileWriteUnknown)
        }
        let pngData = try Data(contentsOf: iconsetDirectory.appendingPathComponent(chunk.fileName))
        body.append(typeData)
        body.append(bigEndianData(UInt32(8 + pngData.count)))
        body.append(pngData)
    }

    var result = Data("icns".utf8)
    result.append(bigEndianData(UInt32(8 + body.count)))
    result.append(body)
    try result.write(to: outputURL, options: .atomic)
}

let arguments = CommandLine.arguments
guard arguments.count == 4 else {
    FileHandle.standardError.write(Data("用法：render-iconset.swift <源图> <iconset目录> <输出icns>\n".utf8))
    exit(2)
}

let sourceURL = URL(fileURLWithPath: arguments[1])
let outputDirectory = URL(fileURLWithPath: arguments[2], isDirectory: true)
let outputURL = URL(fileURLWithPath: arguments[3])
guard let sourceImage = NSImage(contentsOf: sourceURL) else {
    FileHandle.standardError.write(Data("无法读取图标母图。\n".utf8))
    exit(3)
}

let slots = [
    IconSlot(fileName: "icon_16x16.png", pixels: 16),
    IconSlot(fileName: "icon_16x16@2x.png", pixels: 32),
    IconSlot(fileName: "icon_32x32.png", pixels: 32),
    IconSlot(fileName: "icon_32x32@2x.png", pixels: 64),
    IconSlot(fileName: "icon_128x128.png", pixels: 128),
    IconSlot(fileName: "icon_128x128@2x.png", pixels: 256),
    IconSlot(fileName: "icon_256x256.png", pixels: 256),
    IconSlot(fileName: "icon_256x256@2x.png", pixels: 512),
    IconSlot(fileName: "icon_512x512.png", pixels: 512),
    IconSlot(fileName: "icon_512x512@2x.png", pixels: 1024)
]

let chunks = [
    ICNSChunk(type: "icp4", fileName: "icon_16x16.png"),
    ICNSChunk(type: "ic11", fileName: "icon_16x16@2x.png"),
    ICNSChunk(type: "icp5", fileName: "icon_32x32.png"),
    ICNSChunk(type: "ic12", fileName: "icon_32x32@2x.png"),
    ICNSChunk(type: "icp6", fileName: "icon_32x32@2x.png"),
    ICNSChunk(type: "ic07", fileName: "icon_128x128.png"),
    ICNSChunk(type: "ic13", fileName: "icon_128x128@2x.png"),
    ICNSChunk(type: "ic08", fileName: "icon_256x256.png"),
    ICNSChunk(type: "ic14", fileName: "icon_256x256@2x.png"),
    ICNSChunk(type: "ic09", fileName: "icon_512x512.png"),
    ICNSChunk(type: "ic10", fileName: "icon_512x512@2x.png")
]

do {
    try FileManager.default.createDirectory(at: outputDirectory, withIntermediateDirectories: true)
    for slot in slots {
        try render(source: sourceImage, slot: slot, outputDirectory: outputDirectory)
    }
    try writeICNS(chunks: chunks, iconsetDirectory: outputDirectory, outputURL: outputURL)
} catch {
    FileHandle.standardError.write(Data("图标尺寸渲染失败：\(error.localizedDescription)\n".utf8))
    exit(4)
}
