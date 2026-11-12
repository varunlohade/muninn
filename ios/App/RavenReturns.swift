import SwiftUI

/// "The raven returns": a thin green line leaves the paid note, loops once, and lands in the PAID stamp.
/// Path 0.6 s on (0.77, 0, 0.175, 1); it fades 0.5 s after the stamp lands. Reduce Motion: stamp crossfades in.
struct RavenReturns: View {
    let payment: Payment
    let done: () -> Void
    @State private var trim: CGFloat = 0
    @State private var stamped = false
    @State private var lineGone = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        ZStack {
            Theme.Color.bg.opacity(0.82).ignoresSafeArea().onTapGesture(perform: done)
            VStack(spacing: 0) {
                HStack(spacing: Theme.Space.xs) {
                    PixelRaven(scale: 1.6)
                    Text("\(payment.client_name ?? "Client") paid")
                        .font(Theme.Font.sans(15, 500)).foregroundStyle(Theme.Color.text1)
                }
                .padding(.horizontal, 14).padding(.vertical, 10)
                .cardSurface(radius: Theme.Metric.buttonRadius, fill: Theme.Color.surface)
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    if !reduceMotion {
                        LoopPath()
                            .trim(from: 0, to: trim)
                            .stroke(Theme.Color.paid, style: StrokeStyle(lineWidth: 1.5, lineCap: .round))
                            .opacity(lineGone ? 0 : 1)
                    }
                }
                .frame(height: 170)
                // The receipt: amount, a dashed line, what it was for. The Paid pill lands on it.
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        Text("Receipt").font(Theme.Font.sans(12)).foregroundStyle(Theme.Color.text2)
                        Spacer()
                        StatusPill(text: "Paid", tone: .paid)
                            .scaleEffect(stamped || reduceMotion ? 1 : 1.35)
                            .opacity(stamped ? 1 : 0)
                            .accessibilityIdentifier("raven.stamp")
                    }
                    Text(formatMoney(payment.amount, payment.currency)).font(Theme.Font.sans(30)).monospacedDigit().tracking(-0.6)
                        .foregroundStyle(Theme.Color.text1)
                    DashedLine()
                    HStack(alignment: .top) {
                        Text("\(payment.item)\n\(payment.client_name ?? "")")
                        Spacer()
                        Text("PayPal").multilineTextAlignment(.trailing)
                    }
                    .font(Theme.Font.sans(12.5)).foregroundStyle(Theme.Color.text2)
                }
                .padding(.horizontal, 14).padding(.top, 16).padding(.bottom, 12)
                .frame(width: 230)
                .cardSurface()
                .rotationEffect(.degrees(-4))
                .frame(maxWidth: .infinity, alignment: .trailing)
            }
            .padding(.horizontal, 32)
        }
        .task { await play() }
    }

    private func play() async {
        if reduceMotion {
            withAnimation(Theme.Motion.crossfade) { stamped = true }
        } else {
            withAnimation(Theme.Motion.ravenPath) { trim = 1 }
            try? await Task.sleep(for: .milliseconds(600))
            withAnimation(Theme.Motion.stamp) { stamped = true }
            try? await Task.sleep(for: .milliseconds(500))
            withAnimation(.easeOut(duration: 0.3)) { lineGone = true }
        }
        try? await Task.sleep(for: .seconds(2))
        done()
    }
}

/// From the note (top left) down, one loop in the open space, into the stamp (bottom right).
struct LoopPath: Shape {
    func path(in r: CGRect) -> Path {
        var p = Path()
        p.move(to: CGPoint(x: r.minX + 40, y: r.minY))
        p.addCurve(to: CGPoint(x: r.midX + 10, y: r.midY + 30),
                   control1: CGPoint(x: r.minX + 40, y: r.midY), control2: CGPoint(x: r.midX - 60, y: r.maxY))
        p.addCurve(to: CGPoint(x: r.midX - 10, y: r.midY - 10),
                   control1: CGPoint(x: r.midX + 70, y: r.midY - 20), control2: CGPoint(x: r.midX + 20, y: r.minY - 10))
        p.addCurve(to: CGPoint(x: r.maxX - 60, y: r.maxY + 40),
                   control1: CGPoint(x: r.midX - 40, y: r.midY + 10), control2: CGPoint(x: r.maxX - 60, y: r.midY))
        return p
    }
}
