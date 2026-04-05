import Foundation
import CoreVideo
import CoreGraphics
import OSLog

private let logger = Logger(subsystem: "wendigo", category: "TestSource")

struct TestSourceConfig: Hashable, Codable {
    var width: Int
    var height: Int
    var label: String

    static let presets: [(name: String, width: Int, height: Int)] = [
        ("720p",  1280,  720),
        ("1080p", 1920, 1080),
        ("1440p", 2560, 1440),
        ("4K",    3840, 2160),
    ]
}

/// Generates a numbered grid test card with rainbow-colored lines at 30fps
class TestSourceReceiver {
    private var pixelBufferPool: CVPixelBufferPool?
    private var frameCounter: UInt64 = 0
    private let width: Int
    private let height: Int
    private let label: String
    private var isRunning = false
    private var bgBuffer: [UInt32] = []
    private var cols: Int = 0
    private var rows: Int = 0
    private var cellW: Int = 0
    private var cellH: Int = 0

    var onPixelBuffer: ((CVPixelBuffer) -> Void)?

    init(config: TestSourceConfig = TestSourceConfig(width: 1920, height: 1080, label: "test")) {
        self.width = config.width
        self.height = config.height
        self.label = config.label
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        let attrs: [String: Any] = [
            kCVPixelBufferWidthKey as String: width,
            kCVPixelBufferHeightKey as String: height,
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
        ]
        CVPixelBufferPoolCreate(nil, nil, attrs as CFDictionary, &pixelBufferPool)
        logger.info("Test source '\(self.label)' started: \(self.width)x\(self.height) @ 30fps")

        // Compute square grid that fits the aspect ratio
        let gcd = gcdFunc(width, height)
        let ratioW = width / gcd
        let ratioH = height / gcd
        // Scale up to get a reasonable number of cells
        let scale = max(1, min(16 / ratioW, 9 / ratioH, 4))
        cols = ratioW * scale
        rows = ratioH * scale
        // Clamp to reasonable range
        if cols < 4 { let m = 4 / cols + 1; cols *= m; rows *= m }
        if cols > 20 { cols = ratioW; rows = ratioH; if cols < 4 { cols *= 2; rows *= 2 } }
        cellW = width / cols
        cellH = height / rows

        renderBackground()

        let queue = DispatchQueue(label: "wendigo.testsource.\(label)", qos: .userInteractive)
        queue.async { [weak self] in
            var nextFrameTime = CFAbsoluteTimeGetCurrent()
            let frameDuration = 1.0 / 30.0
            while self?.isRunning == true {
                self?.generateFrame()
                nextFrameTime += frameDuration
                let sleepTime = nextFrameTime - CFAbsoluteTimeGetCurrent()
                if sleepTime > 0 {
                    Thread.sleep(forTimeInterval: sleepTime)
                } else {
                    nextFrameTime = CFAbsoluteTimeGetCurrent()
                }
            }
        }
    }

    private func gcdFunc(_ a: Int, _ b: Int) -> Int { b == 0 ? a : gcdFunc(b, a % b) }

    private func hsv(_ h: Double, _ s: Double, _ v: Double) -> UInt32 {
        let c = v * s
        let x = c * (1 - abs((h / 60.0).truncatingRemainder(dividingBy: 2) - 1))
        let m = v - c
        var r = 0.0, g = 0.0, b = 0.0
        if h < 60       { r = c; g = x }
        else if h < 120  { r = x; g = c }
        else if h < 180  { g = c; b = x }
        else if h < 240  { g = x; b = c }
        else if h < 300  { r = x; b = c }
        else             { r = c; b = x }
        return 0xFF000000 | UInt32((r + m) * 255) << 16 | UInt32((g + m) * 255) << 8 | UInt32((b + m) * 255)
    }

    private func renderBackground() {
        let W = width, H = height
        bgBuffer = [UInt32](repeating: 0xFF000000, count: W * H)

        let totalCells = cols * rows
        let lineW = max(1, W / 960)

        // ── Draw grid lines with rainbow hue ──
        // Vertical lines
        for col in 0...cols {
            let x0 = col * cellW
            let hue = Double(col) / Double(cols) * 300.0  // 0-300 hue range
            let color = hsv(hue, 0.8, 0.5)
            for y in 0..<H {
                for dx in 0..<lineW {
                    let x = x0 + dx
                    if x >= 0 && x < W { bgBuffer[y * W + x] = color }
                }
            }
        }

        // Horizontal lines
        for row in 0...rows {
            let y0 = row * cellH
            let hue = Double(row) / Double(rows) * 300.0
            let color = hsv(hue, 0.8, 0.5)
            for x in 0..<W {
                for dy in 0..<lineW {
                    let y = y0 + dy
                    if y >= 0 && y < H { bgBuffer[y * W + x] = color }
                }
            }
        }

        // ── Cell numbers ──
        let numScale = max(1, min(cellW, cellH) / 50)
        for row in 0..<rows {
            for col in 0..<cols {
                let cellIdx = row * cols + col
                let hue = Double(cellIdx) / Double(totalCells) * 300.0
                let color = hsv(hue, 0.6, 0.35)
                let text = "\(col),\(row)"
                let tx = col * cellW + cellW / 2
                let ty = row * cellH + numScale * 5
                drawTextToBg(text, tx, ty, numScale, color)
            }
        }
    }

    private func generateFrame() {
        guard let pool = pixelBufferPool else { return }
        var pixelBuffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &pixelBuffer)
        guard let pb = pixelBuffer else { return }

        CVPixelBufferLockBaseAddress(pb, [])
        defer { CVPixelBufferUnlockBaseAddress(pb, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pb) else { return }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pb)
        let px = baseAddress.assumingMemoryBound(to: UInt32.self)
        let st = bytesPerRow / 4

        let frame = Int(frameCounter)
        frameCounter += 1
        let W = width, H = height
        let cx = W / 2, cy = H / 2

        // Copy background
        bgBuffer.withUnsafeBufferPointer { src in
            for y in 0..<H {
                (px + y * st).update(from: src.baseAddress! + y * W, count: W)
            }
        }

        // ── Dynamic text at center ──
        let scale = max(1, W / 480)

        // Label
        drawText(px, st, label.uppercased(), cx, cy - scale * 16, scale + 2, 0xFFFFFFFF)

        // Resolution
        drawText(px, st, "\(W)x\(H)", cx, cy - scale * 2, scale, hsv(180, 0.6, 0.8))

        // Clock
        let now = Date()
        let cal = Calendar.current
        let h = cal.component(.hour, from: now)
        let m = cal.component(.minute, from: now)
        let s = cal.component(.second, from: now)
        drawText(px, st, String(format: "%02d:%02d:%02d", h, m, s), cx, cy + scale * 12, scale + 1, 0xFFFFFFFF)

        // Frame counter
        drawText(px, st, String(format: "F%06d", frame), cx, cy + scale * 26, scale, hsv(280, 0.6, 0.6))

        onPixelBuffer?(pb)
    }

    // ── Drawing helpers ──
    private func setPixelSafe(_ buf: UnsafeMutablePointer<UInt32>, _ st: Int, _ x: Int, _ y: Int, _ c: UInt32) {
        guard x >= 0 && x < width && y >= 0 && y < height else { return }
        buf[y * st + x] = c
    }

    private static let glyphs: [Character: [UInt8]] = [
        "0": [0x0E,0x11,0x13,0x15,0x19,0x11,0x0E], "1": [0x04,0x0C,0x04,0x04,0x04,0x04,0x0E],
        "2": [0x0E,0x11,0x01,0x06,0x08,0x10,0x1F], "3": [0x0E,0x11,0x01,0x06,0x01,0x11,0x0E],
        "4": [0x02,0x06,0x0A,0x12,0x1F,0x02,0x02], "5": [0x1F,0x10,0x1E,0x01,0x01,0x11,0x0E],
        "6": [0x06,0x08,0x10,0x1E,0x11,0x11,0x0E], "7": [0x1F,0x01,0x02,0x04,0x08,0x08,0x08],
        "8": [0x0E,0x11,0x11,0x0E,0x11,0x11,0x0E], "9": [0x0E,0x11,0x11,0x0F,0x01,0x02,0x0C],
        "x": [0x00,0x00,0x11,0x0A,0x04,0x0A,0x11], " ": [0x00,0x00,0x00,0x00,0x00,0x00,0x00],
        "A": [0x0E,0x11,0x11,0x1F,0x11,0x11,0x11], "B": [0x1E,0x11,0x11,0x1E,0x11,0x11,0x1E],
        "C": [0x0E,0x11,0x10,0x10,0x10,0x11,0x0E], "D": [0x1E,0x11,0x11,0x11,0x11,0x11,0x1E],
        "E": [0x1F,0x10,0x10,0x1E,0x10,0x10,0x1F], "F": [0x1F,0x10,0x10,0x1E,0x10,0x10,0x10],
        "G": [0x0E,0x11,0x10,0x17,0x11,0x11,0x0E], "H": [0x11,0x11,0x11,0x1F,0x11,0x11,0x11],
        "I": [0x0E,0x04,0x04,0x04,0x04,0x04,0x0E], "J": [0x07,0x02,0x02,0x02,0x02,0x12,0x0C],
        "K": [0x11,0x12,0x14,0x18,0x14,0x12,0x11], "L": [0x10,0x10,0x10,0x10,0x10,0x10,0x1F],
        "M": [0x11,0x1B,0x15,0x15,0x11,0x11,0x11], "N": [0x11,0x19,0x15,0x13,0x11,0x11,0x11],
        "O": [0x0E,0x11,0x11,0x11,0x11,0x11,0x0E], "P": [0x1E,0x11,0x11,0x1E,0x10,0x10,0x10],
        "Q": [0x0E,0x11,0x11,0x11,0x15,0x12,0x0D], "R": [0x1E,0x11,0x11,0x1E,0x14,0x12,0x11],
        "S": [0x0E,0x11,0x10,0x0E,0x01,0x11,0x0E], "T": [0x1F,0x04,0x04,0x04,0x04,0x04,0x04],
        "U": [0x11,0x11,0x11,0x11,0x11,0x11,0x0E], "V": [0x11,0x11,0x11,0x11,0x0A,0x0A,0x04],
        "W": [0x11,0x11,0x11,0x15,0x15,0x15,0x0A], "Y": [0x11,0x11,0x0A,0x04,0x04,0x04,0x04],
        "Z": [0x1F,0x01,0x02,0x04,0x08,0x10,0x1F], "-": [0x00,0x00,0x00,0x1F,0x00,0x00,0x00],
        ".": [0x00,0x00,0x00,0x00,0x00,0x00,0x04], ":": [0x00,0x00,0x04,0x00,0x00,0x04,0x00],
        "X": [0x11,0x11,0x0A,0x04,0x0A,0x11,0x11], ",": [0x00,0x00,0x00,0x00,0x00,0x04,0x08],
    ]

    // Draw to bgBuffer (width stride)
    private func drawTextToBg(_ text: String, _ x: Int, _ y: Int, _ scale: Int, _ color: UInt32) {
        let charW = 6 * scale
        let charH = 7 * scale
        let startX = x - text.count * charW / 2
        let startY = y - charH / 2
        let W = width
        for (ci, ch) in text.enumerated() {
            guard let glyph = Self.glyphs[ch] else { continue }
            let ox = startX + ci * charW
            for row in 0..<7 {
                for col in 0..<5 {
                    if glyph[row] & (1 << (4 - col)) != 0 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                let px = ox + col * scale + sx
                                let py = startY + row * scale + sy
                                if px >= 0 && px < width && py >= 0 && py < height {
                                    bgBuffer[py * W + px] = color
                                }
                            }
                        }
                    }
                }
            }
        }
    }

    // Draw to pixel buffer (st stride)
    private func drawText(_ px: UnsafeMutablePointer<UInt32>, _ st: Int,
                           _ text: String, _ x: Int, _ y: Int, _ scale: Int, _ color: UInt32) {
        let charW = 6 * scale
        let charH = 7 * scale
        let startX = x - text.count * charW / 2
        let startY = y - charH / 2

        // Dark background
        let pad = scale * 2
        for by in max(0, startY - pad)..<min(height, startY + charH + pad) {
            for bx in max(0, startX - pad)..<min(width, startX + text.count * charW + pad) {
                px[by * st + bx] = 0xE0000000
            }
        }

        for (ci, ch) in text.enumerated() {
            guard let glyph = Self.glyphs[ch] else { continue }
            let ox = startX + ci * charW
            for row in 0..<7 {
                for col in 0..<5 {
                    if glyph[row] & (1 << (4 - col)) != 0 {
                        for sy in 0..<scale {
                            for sx in 0..<scale {
                                setPixelSafe(px, st, ox + col * scale + sx, startY + row * scale + sy, color)
                            }
                        }
                    }
                }
            }
        }
    }

    func stop() {
        isRunning = false
        pixelBufferPool = nil
        bgBuffer = []
        logger.info("Test source '\(self.label)' stopped")
    }

    deinit { stop() }
}
