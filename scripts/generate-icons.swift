#!/usr/bin/env swift
//
// StockBar AppIcon generator.
// Resizes the approved Scheme B master into every macOS AppIcon size.
//
// Run: swift scripts/generate-icons.swift

import AppKit
import Foundation

let sizes = [16, 32, 64, 128, 256, 512, 1024]
let masterPath = "scripts/assets/StockBarIconMaster.png"
let outputDirectory = "StockBar/Resources/Assets.xcassets/AppIcon.appiconset"

let fileManager = FileManager.default
let rootURL = URL(fileURLWithPath: fileManager.currentDirectoryPath)
let masterURL = rootURL.appendingPathComponent(masterPath)
let outputURL = rootURL.appendingPathComponent(outputDirectory)

guard let master = NSImage(contentsOf: masterURL) else {
    fputs("Missing icon master: \(masterURL.path)\n", stderr)
    exit(1)
}

guard
    let masterData = try? Data(contentsOf: masterURL),
    let masterBitmap = NSBitmapImageRep(data: masterData),
    masterBitmap.hasAlpha
else {
    fputs("Icon master must be a PNG with an alpha channel\n", stderr)
    exit(1)
}

let cornerPixels = [
    (0, 0),
    (masterBitmap.pixelsWide - 1, 0),
    (0, masterBitmap.pixelsHigh - 1),
    (masterBitmap.pixelsWide - 1, masterBitmap.pixelsHigh - 1),
]
guard cornerPixels.allSatisfy({ x, y in
    (masterBitmap.colorAt(x: x, y: y)?.alphaComponent ?? 1) < 0.05
}) else {
    fputs("Icon master must have transparent outer corners\n", stderr)
    exit(1)
}

try fileManager.createDirectory(at: outputURL, withIntermediateDirectories: true)

func pngData(size: Int) -> Data? {
    guard let bitmap = NSBitmapImageRep(
        bitmapDataPlanes: nil,
        pixelsWide: size,
        pixelsHigh: size,
        bitsPerSample: 8,
        samplesPerPixel: 4,
        hasAlpha: true,
        isPlanar: false,
        colorSpaceName: .deviceRGB,
        bytesPerRow: 0,
        bitsPerPixel: 0
    ) else { return nil }

    bitmap.size = NSSize(width: size, height: size)
    NSGraphicsContext.saveGraphicsState()
    defer { NSGraphicsContext.restoreGraphicsState() }

    let context = NSGraphicsContext(bitmapImageRep: bitmap)
    context?.imageInterpolation = .high
    NSGraphicsContext.current = context
    master.draw(
        in: NSRect(x: 0, y: 0, width: size, height: size),
        from: .zero,
        operation: .copy,
        fraction: 1
    )
    return bitmap.representation(using: .png, properties: [:])
}

for size in sizes {
    guard let data = pngData(size: size) else {
        fputs("Failed to render \(size)px icon\n", stderr)
        exit(1)
    }
    let destination = outputURL.appendingPathComponent("icon_\(size).png")
    try data.write(to: destination, options: .atomic)
    print("Generated \(destination.lastPathComponent)")
}

print("StockBar AppIcon set updated from \(masterPath)")
