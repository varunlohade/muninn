import SwiftUI
import UIKit

/// The onboarding hero: a pixel shop street at dusk. Payments land, each shop lights up with its amount,
/// the raven visits the one dark shop, and at closing the street goes dark. An 8 s loop at 24 fps.
/// A 1:1 port of build/anim.js (`street(t)`): every frame is a pure function of t, in whole art pixels and hard steps.
enum StreetScene {
    static let width = 98, height = 118
    static let loop: Double = 8
    static let fps: Double = 24
    /// The still frame for Reduce Motion: all shops lit, the raven on the teal shop, no labels, no car.
    static let stillTime: Double = 6.9

    private struct Shop { let w: Int, h: Int, c: UInt32, d: UInt32, aw: (UInt32, UInt32), on: Double, amt: String, open: Bool }
    private static let sky: [UInt32] = [0x1E1B36, 0x272443, 0x332D57, 0x463768, 0x5E4478, 0x7E4F7E, 0xA55E7D, 0xCB727A, 0xE68E79, 0xF3AE84]
    private static let shops = [
        Shop(w: 23, h: 52, c: 0xB8604A, d: 0x8E4536, aw: (0xF1E6D2, 0x3F6E6A), on: 1.0, amt: "+45", open: true),
        Shop(w: 26, h: 58, c: 0xE3D3AE, d: 0xBFA97E, aw: (0xF1E6D2, 0xC2523F), on: 2.2, amt: "+90", open: false),
        Shop(w: 23, h: 46, c: 0x4F7E78, d: 0x3A605B, aw: (0xF1E6D2, 0xE2A13F), on: 5.0, amt: "+120", open: false),
        Shop(w: 26, h: 58, c: 0x8C6B9C, d: 0x6C5079, aw: (0xF1E6D2, 0x2F5A86), on: 3.4, amt: "+160", open: false),
    ]
    /// Closing time per shop: lights go out fast.
    private static let off: [Double] = [7.75, 7.6, 7.3, 7.45]
    private static let lampOn: [(Double, Double)] = [(0.6, 0.7), (0.85, 7.9)]
    private static let openBlink = (1.5, 1.65)
    private static let ravenHop: [(Double, Double)] = [(3.0, 3.12), (3.24, 3.36)]
    private static let ravenFly = (3.6, 4.6), ravenBack = (7.2, 8.0)
    private static let carStart = 1.4, carSpeed = 24.0

    private static let perch = PixelRaven.rows
    private static let perchPal: [Character: UInt32] = ["#": 0x151A2B, "b": 0x2E3D63, "e": 0xF2F2F2, ">": 0x3A3A3A, "|": 0x1B1B1B]
    private static let flyUp = [".KK...........", "..KLK.........", "...KBK....KK..", "....KKKKKKKEKY", "..KKKKKKKKKK..", ".KK..........."]
    private static let flyDown = ["..............", "..........KK..", "..KKKKKKKKKEKY", ".KKKKBBKKKKK..", "....KLBK......", ".....KLK......", "......KK......"]
    private static let flyPal: [Character: UInt32] = ["K": 0x151A2B, "B": 0x2E3D63, "L": 0x4A5E90, "E": 0xF2F2F2, "Y": 0x4A4A4A]
    private static let car = ["....KKKKKK......", "...KWWKWWWK.....", ".KKKKKKKKKKKKKK.", "KRRRRRRRRRRRRRRY", "KRRrrrrrrrrrRRRK", ".KKGK.....KGKK..", "..KK.......KK..."]
    private static let carPal: [Character: UInt32] = ["K": 0x1E1B2B, "W": 0x9FB4D6, "R": 0xD8473C, "r": 0xB23A31, "Y": 0xFFE7A8, "G": 0x8B83A3]
    private static let font: [Character: [String]] = [
        "+": ["...", ".#.", "###", ".#.", "..."], "0": ["###", "#.#", "#.#", "#.#", "###"], "1": [".#.", "##.", ".#.", ".#.", "###"],
        "2": ["##.", "..#", ".#.", "#..", "###"], "4": ["..#", ".##", "#.#", "###", "..#"], "5": ["###", "#..", "##.", "..#", "##."],
        "6": [".##", "#..", "###", "#.#", "###"], "9": ["###", "#.#", "###", "..#", "##."],
    ]

    /// The same small generator as the JS (an LCG on 32 bits), so the stars and rooftops land where the mock has them.
    private struct RNG {
        var s: UInt32
        mutating func next() -> Double { s = s &* 1664525 &+ 1013904223; return Double(s) / 4294967296 }
    }

    private struct Painter {
        var px = [UInt32](repeating: 0xFF000000, count: StreetScene.width * StreetScene.height)
        mutating func set(_ x: Int, _ y: Int, _ c: UInt32) {
            guard x >= 0, y >= 0, x < StreetScene.width, y < StreetScene.height else { return }
            // RGBA bytes in memory, little-endian: 0xAABBGGRR.
            px[y * StreetScene.width + x] = 0xFF000000 | ((c & 0xFF) << 16) | (c & 0xFF00) | ((c >> 16) & 0xFF)
        }
        mutating func rect(_ x: Int, _ y: Int, _ w: Int, _ h: Int, _ c: UInt32) {
            for j in y..<(y + max(0, h)) { for i in x..<(x + max(0, w)) { set(i, j, c) } }
        }
        mutating func sprite(_ x0: Int, _ y0: Int, _ rows: [String], _ pal: [Character: UInt32], flip: Bool = false) {
            for (y, row) in rows.enumerated() {
                let n = row.count
                for (x, ch) in row.enumerated() { if let c = pal[ch] { set(flip ? x0 + n - 1 - x : x0 + x, y0 + y, c) } }
            }
        }
    }

    private static func jsRound(_ v: Double) -> Int { Int((v + 0.5).rounded(.down)) }
    private static func within(_ t: Double, _ r: (Double, Double)) -> Bool { t >= r.0 && t < r.1 }

    /// One frame at time t (seconds), as a 98 x 118 image.
    static func frame(at time: Double) -> CGImage? { image(pixels(at: time)) }

    /// One frame's pixels, row by row, as RGBA bytes in memory.
    static func pixels(at time: Double) -> [UInt32] {
        let t = (time.truncatingRemainder(dividingBy: loop) + loop).truncatingRemainder(dividingBy: loop)
        var p = Painter()
        let W = width, H = height
        let base = H - 22, skyEnd = 62
        var r = RNG(s: 7)

        // Night deepens in two steps, then returns at closing.
        var night = (t >= 2.0 ? 1 : 0) + (t >= 4.0 ? 1 : 0)
        if t >= 7.6 { night = t >= 7.8 ? 0 : 1 }
        let bands = Double(sky.count - 1)
        for y in 0..<skyEnd {
            let f = Double(y) / Double(skyEnd) * bands, i = Int(f.rounded(.down))
            for x in 0..<W {
                var k = i
                if f - Double(i) > 0.82 && (x + y) % 2 == 0 { k += 1 }
                k = max(0, k + 1 - night)
                p.set(x, y, sky[min(sky.count - 1, k)])
            }
        }
        // Stars: more as night deepens. Each twinkles on its own period, in steps.
        for i in 0..<34 {
            let x = Int(r.next() * Double(W)), y = 15 + Int(r.next() * 26), per = 1.5 + r.next() * 1.5, ph = r.next() * per, big = r.next() < 0.25
            if i >= 16 + night * 9 { continue }
            let on = (t + ph).truncatingRemainder(dividingBy: per) < per * 0.78
            p.set(x, y, on ? (big ? 0xFFF3D6 : 0xBDB2D8) : 0x5E5380)
        }
        // Far rooftops, with windows that switch on together.
        var x = 0
        var rr = RNG(s: 11)
        while x < W {
            let w = 5 + Int(rr.next() * 8), h = 6 + Int(rr.next() * 10)
            p.rect(x, skyEnd - h, w, h, 0x4A3B66)
            if rr.next() < 0.5 { p.rect(x + 1, skyEnd - h - 3, 2, 3, 0x4A3B66) }
            if rr.next() < 0.6 { p.set(x + 2, skyEnd - h + 3, t > 0.5 && t < 7.9 ? 0xF3C978 : 0x5A4A78) }
            x += w
        }
        p.rect(0, skyEnd, W, base - skyEnd, 0x4A3B66)

        // Sidewalk and road.
        for y in base..<H { p.rect(0, y, W, 1, y < base + 6 ? 0x8E8299 : y == base + 6 ? 0x5C5170 : 0x433B57) }
        for i in stride(from: 2, to: W, by: 8) { p.rect(i, base + 12, 4, 1, 0x6B6283) }

        x = 0
        var tops: [Int] = [], xs: [Int] = []
        for (si, s) in shops.enumerated() {
            let top = base - s.h
            tops.append(top); xs.append(x)
            let litAt = { (k: Int) in t >= s.on + Double(k) * 0.15 && t < off[si] }
            let lit = litAt(0)
            p.rect(x, top, s.w, s.h, s.c); p.rect(x, top, s.w, 2, s.d)
            for j in stride(from: top + 3, to: base, by: 3) { for i in stride(from: x, to: x + s.w, by: 2) where (i + j) % 5 == 0 { p.set(i, j, s.d) } }
            p.rect(x, top, 1, s.h, s.d); p.rect(x + s.w - 1, top, 1, s.h, s.d)
            // Upper windows light row by row from the bottom, 0.15 s apart.
            let rows = Array(stride(from: top + 6, to: base - 30, by: 11))
            for (ri, wy) in rows.enumerated() {
                let on = litAt(rows.count - ri)
                for wx in [x + 4, x + s.w - 10] {
                    p.rect(wx - 1, wy - 1, 8, 9, on ? 0xE7A64B : 0x1F2236); p.rect(wx, wy, 6, 7, on ? 0xFFD37C : 0x2C2F48)
                    p.rect(wx + 3, wy, 1, 7, on ? 0xE7A64B : 0x1F2236)
                    if !on { p.set(wx + 1, wy + 1, 0x4B5174) }
                }
            }
            let ay = base - 26
            for j in 0..<5 { for i in (x + 1)..<(x + s.w - 1) { p.set(i, ay + j, ((i - x) / 3) % 2 == 0 ? s.aw.0 : s.aw.1) } }
            for i in (x + 1)..<(x + s.w - 1) where (i - x) % 3 == 1 { p.set(i, ay + 5, ((i - x) / 3) % 2 == 0 ? s.aw.0 : s.aw.1) }
            p.rect(x + 1, ay - 1, s.w - 2, 1, 0x2A2338)
            p.rect(x + 2, ay + 7, s.w - 11, 15, 0x2A2338)
            p.rect(x + 3, ay + 8, s.w - 13, 13, lit ? 0xFFD37C : 0x2C2F48)
            if lit {
                for i in stride(from: x + 4, to: x + s.w - 11, by: 3) { p.set(i, ay + 9, 0xFFF1C4) }
                p.rect(x + 4, ay + 17, s.w - 15, 4, 0xE7A64B)
            } else { p.set(x + 5, ay + 10, 0x4B5174) }
            p.rect(x + s.w - 8, ay + 6, 6, 16, 0x2A2338); p.rect(x + s.w - 7, ay + 7, 4, 15, lit ? 0xC98B3F : 0x3A3550)
            p.set(x + s.w - 4, ay + 14, lit ? 0xFFD37C : 0x5A5070)
            // Warm light spills on the sidewalk under a lit shop.
            if lit {
                for j in base..<(base + 6) { for i in (x + 2)..<(x + s.w - 2) where j < base + 2 || (i + j) % 2 == 0 { p.set(i, j, j < base + 2 ? 0xE6C38A : 0xB79B88) } }
            }
            // OPEN sign: lights with the shop, blinks off once.
            if s.open {
                let signOn = lit && !within(t, openBlink)
                p.rect(x + 5, ay + 10, 7, 4, signOn ? 0xD8473C : 0x5B2E3A)
                if signOn { for (a, b) in [(6, 11), (8, 11), (10, 11), (7, 12), (9, 12)] { p.set(x + a, ay + b, 0xFFE6D9) } }
                p.set(x + 8, ay + 9, 0x2A2338)
            }
            x += s.w
        }

        // Street lamp: flickers on, then holds.
        let lx = 49, lamp = lampOn.contains { within(t, $0) }
        p.rect(lx, base - 34, 1, 34, 0x231E31); p.rect(lx - 2, base - 37, 5, 3, 0x231E31); p.rect(lx - 1, base - 36, 3, 2, lamp ? 0xFFE7A8 : 0x4B4560)
        if lamp { for j in base..<(base + 6) { for i in (lx - 4)...(lx + 4) where (i + j) % 2 == 0 { p.set(i, j, 0xA898A0) } } }

        // The car passes left to right, one art pixel per frame.
        let cx = Int((-18 + (t - carStart) * carSpeed).rounded(.down))
        if t >= carStart && cx < W + 2 {
            for i in 1...8 { for j in 0..<3 where (i + j) % 2 == 0 { p.set(cx + 16 + i, base + 11 + j + (i > 4 ? j - 1 : 0), 0x6E6283) } }
            p.sprite(cx, base + 8, car, carPal)
        }

        // The raven: perched on the cream shop, hops, flies to the dark shop, flies home at closing.
        let a = (xs[1] + 7, tops[1] - 9), b = (xs[2] + 5, tops[2] - 9)
        let hop = ravenHop.contains { within(t, $0) } ? 1 : 0
        let flap = Int((t * 8).rounded(.down)) % 2
        func flight(_ from: (Int, Int), _ to: (Int, Int), _ u: Double, flip: Bool) {
            let fx = jsRound(Double(from.0) + Double(to.0 - from.0) * u)
            let fy = jsRound(Double(from.1) + Double(to.1 - from.1) * u - sin(Double.pi * u) * 10)
            p.sprite(fx, fy + 2, flap == 1 ? flyUp : flyDown, flyPal, flip: flip)
        }
        if t < ravenFly.0 { p.sprite(a.0, a.1 - hop, perch, perchPal) }
        else if t < ravenFly.1 { flight(a, b, ((t - ravenFly.0) / (ravenFly.1 - ravenFly.0) * 12).rounded(.down) / 12, flip: false) }
        else if t < ravenBack.0 { p.sprite(b.0, b.1, perch, perchPal) }
        else { flight(b, a, ((t - ravenBack.0) / (ravenBack.1 - ravenBack.0) * 10).rounded(.down) / 10, flip: true) }

        // "+45" rises 1 px per 0.125 s for 6 steps, holds, dims, then goes.
        for (si, s) in shops.enumerated() {
            let dt = t - s.on
            if dt < 0 || dt >= 1.75 { continue }
            let rise = min(6, Int((dt / 0.125).rounded(.down)))
            let ravenThere = (si == 1 && t < ravenFly.0) || (si == 2 && t >= ravenFly.1 && t < ravenBack.0)
            let y = tops[si] - 8 - (ravenThere ? 9 : 0) - rise
            let tx = xs[si] + jsRound(Double(s.w - s.amt.count * 4) / 2) + 1
            if dt < 1.5 { text(&p, tx, y, s.amt, 0xFFE29A, shadow: 0x2A2338) } else { text(&p, tx, y, s.amt, 0xA88C8A) }
        }
        return p.px
    }

    private static func text(_ p: inout Painter, _ x: Int, _ y: Int, _ s: String, _ c: UInt32, shadow: UInt32? = nil) {
        for pass in shadow == nil ? [0] : [1, 0] {
            for (i, ch) in s.enumerated() {
                for (yy, row) in (font[ch] ?? []).enumerated() {
                    for (xx, v) in row.enumerated() where v == "#" { p.set(x + i * 4 + xx + pass, y + yy + pass, pass == 1 ? shadow! : c) }
                }
            }
        }
    }

    private static func image(_ px: [UInt32]) -> CGImage? {
        let data = px.withUnsafeBufferPointer { Data(buffer: $0) } as CFData
        guard let provider = CGDataProvider(data: data) else { return nil }
        return CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: width * 4,
                       space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.noneSkipLast.rawValue),
                       provider: provider, decode: nil, shouldInterpolate: false, intent: .defaultIntent)
    }
}

/// Plays the street at 24 fps while it is on screen and the app is active. Under Reduce Motion it shows one still frame.
/// It stops ticking when it leaves the screen or the app goes to the background.
struct StreetSceneView: View {
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.scenePhase) private var scenePhase
    @State private var visible = false
    @State private var start = Date()

    var body: some View {
        let paused = reduceMotion || !visible || scenePhase != .active
        TimelineView(.animation(minimumInterval: 1 / StreetScene.fps, paused: paused)) { context in
            let t = reduceMotion ? StreetScene.stillTime : (context.date.timeIntervalSince(start) * StreetScene.fps).rounded(.down) / StreetScene.fps
            pixels(t)
        }
        .onAppear { start = Date(); visible = true }
        .onDisappear { visible = false }
        .accessibilityHidden(true)
    }

    @ViewBuilder private func pixels(_ t: Double) -> some View {
        if let frame = StreetScene.frame(at: t) {
            Image(decorative: frame, scale: 1).resizable().interpolation(.none)
        } else {
            Color(hex: 0x1E1B36)
        }
    }
}

/// The first onboarding screen: the street, the wordmark, the two-tone headline and one button.
struct HeroView: View {
    let addKeyboard: () -> Void
    let haveAccount: () -> Void

    var body: some View {
        GeometryReader { g in
            let sceneWidth = g.size.width + 2
            let full = sceneWidth * CGFloat(StreetScene.height) / CGFloat(StreetScene.width)
            // Small phones crop the top of the sky, so the words and the button always fit.
            let sceneHeight = min(full, g.size.height + g.safeAreaInsets.top - 330)
            VStack(alignment: .leading, spacing: 0) {
                StreetSceneView()
                    .frame(width: sceneWidth, height: full)
                    .frame(width: g.size.width, height: sceneHeight, alignment: .bottom)
                    .clipped()
                    .accessibilityIdentifier("onboarding.hero")
                VStack(alignment: .leading, spacing: 14) {
                    Wordmark(size: 24)
                    twoTone("Your business, in your keyboard.", "Works in every app you already type in.")
                        .font(Theme.Font.headline).tracking(-0.4).lineSpacing(1)
                        .fixedSize(horizontal: false, vertical: true)
                        .minimumScaleFactor(0.8)
                        .accessibilityIdentifier("onboarding.headline")
                }
                .padding(.horizontal, 24)
                .padding(.top, 22)
                Spacer(minLength: Theme.Space.m)
                VStack(spacing: 4) {
                    Button("Add the keyboard", action: addKeyboard)
                        .buttonStyle(PrimaryButton())
                        .accessibilityIdentifier("onboarding.add")
                    Button("I already have an account", action: haveAccount)
                        .font(Theme.Font.sans(15)).foregroundStyle(Theme.Color.text2)
                        .frame(maxWidth: .infinity, minHeight: Theme.Metric.secondaryButton)
                        .accessibilityIdentifier("onboarding.account")
                }
                .padding(.horizontal, 20)
                .padding(.bottom, Theme.Space.s)
            }
            .ignoresSafeArea(edges: .top)
        }
        .background(Theme.Color.bg.ignoresSafeArea())
        .statusBarHidden(true)
    }
}
