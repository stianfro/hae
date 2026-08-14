#!/usr/bin/env swift
import AppKit
import Foundation

guard CommandLine.arguments.count == 2 else {
  FileHandle.standardError.write(Data("Usage: draw-app-icon.swift OUTPUT.png\n".utf8))
  exit(2)
}

let canvas = NSSize(width: 1_024, height: 1_024)
guard
  let bitmap = NSBitmapImageRep(
    bitmapDataPlanes: nil,
    pixelsWide: Int(canvas.width),
    pixelsHigh: Int(canvas.height),
    bitsPerSample: 8,
    samplesPerPixel: 4,
    hasAlpha: true,
    isPlanar: false,
    colorSpaceName: .deviceRGB,
    bytesPerRow: 0,
    bitsPerPixel: 0
  ),
  let context = NSGraphicsContext(bitmapImageRep: bitmap)
else {
  FileHandle.standardError.write(Data("Could not create icon canvas.\n".utf8))
  exit(1)
}

NSGraphicsContext.saveGraphicsState()
NSGraphicsContext.current = context
defer { NSGraphicsContext.restoreGraphicsState() }

NSGraphicsContext.current?.imageInterpolation = .high
NSColor.clear.setFill()
NSRect(origin: .zero, size: canvas).fill()

let tile = NSBezierPath(
  roundedRect: NSRect(x: 48, y: 48, width: 928, height: 928),
  xRadius: 210,
  yRadius: 210
)
let gradient = NSGradient(
  starting: NSColor(calibratedRed: 0.06, green: 0.13, blue: 0.16, alpha: 1),
  ending: NSColor(calibratedRed: 0.16, green: 0.38, blue: 0.43, alpha: 1)
)
gradient?.draw(in: tile, angle: 38)

NSColor(calibratedWhite: 1, alpha: 0.12).setStroke()
tile.lineWidth = 10
tile.stroke()

let waveformColor = NSColor(calibratedRed: 0.90, green: 0.96, blue: 0.94, alpha: 1)
waveformColor.setStroke()

let bars: [(CGFloat, CGFloat)] = [
  (264, 178),
  (374, 330),
  (484, 456),
  (594, 294),
  (704, 142),
]
for (x, height) in bars {
  let bar = NSBezierPath()
  bar.move(to: NSPoint(x: x, y: 512 - height / 2))
  bar.line(to: NSPoint(x: x, y: 512 + height / 2))
  bar.lineWidth = 66
  bar.lineCapStyle = .round
  bar.stroke()
}

let recordingDot = NSBezierPath(ovalIn: NSRect(x: 744, y: 724, width: 132, height: 132))
NSColor(calibratedRed: 1, green: 0.25, blue: 0.23, alpha: 1).setFill()
recordingDot.fill()
NSColor(calibratedWhite: 1, alpha: 0.28).setStroke()
recordingDot.lineWidth = 8
recordingDot.stroke()

guard let png = bitmap.representation(using: .png, properties: [:]) else {
  FileHandle.standardError.write(Data("Could not render icon.\n".utf8))
  exit(1)
}

try png.write(to: URL(fileURLWithPath: CommandLine.arguments[1]), options: .atomic)
