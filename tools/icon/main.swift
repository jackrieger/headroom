import AppKit
import SwiftUI

let iconset = URL(fileURLWithPath: CommandLine.arguments[1])

func hex(_ v: UInt32) -> Color {
    Color(red: Double(v >> 16 & 0xFF) / 255, green: Double(v >> 8 & 0xFF) / 255, blue: Double(v & 0xFF) / 255)
}

struct Art: View {
    var body: some View {
        ZStack {
            LinearGradient(colors: [hex(0x2E3138), hex(0x141619)], startPoint: .top, endPoint: .bottom)
            VStack(spacing: 60) {
                meter(filled: 4, color: hex(0xF4EEE4))
                meter(filled: 8, color: hex(0xF2A33A))
            }
        }
    }

    func meter(filled: Int, color: Color) -> some View {
        VStack(spacing: 20) {
            ForEach(0..<2, id: \.self) { _ in
                HStack(spacing: 20) {
                    ForEach(0..<10, id: \.self) { column in
                        Circle()
                            .fill(column < filled ? color : Color.white.opacity(0.14))
                            .frame(width: 44, height: 44)
                    }
                }
            }
        }
    }
}

@MainActor
func save(_ view: some View, _ name: String, size: Int) {
    let renderer = ImageRenderer(content: view.frame(width: 1024, height: 1024))
    renderer.scale = Double(size) / 1024
    let rep = NSBitmapImageRep(cgImage: renderer.cgImage!)
    try! rep.representation(using: .png, properties: [:])!.write(to: iconset.appendingPathComponent(name))
}

MainActor.assumeIsolated {
    try! FileManager.default.createDirectory(at: iconset, withIntermediateDirectories: true)
    let mac = Art().frame(width: 824, height: 824).clipShape(RoundedRectangle(cornerRadius: 185, style: .continuous))
    for points in [16, 32, 128, 256, 512] {
        save(mac, "icon_\(points)x\(points).png", size: points)
        save(mac, "icon_\(points)x\(points)@2x.png", size: points * 2)
    }
}
