import SwiftUI

/// The launch wait: until the first screen has its data, or `cap` at most, then show what there is.
enum Splash {
    static let cap: Duration = .seconds(3)
    static let step: Duration = .milliseconds(50)

    /// Returns as soon as `ready` is true, or after `cap`. `sleep` is for tests.
    @MainActor
    static func wait(cap: Duration = cap, step: Duration = step,
                     sleep: (Duration) async throws -> Void = { try await Task.sleep(for: $0) }, ready: () -> Bool) async {
        var waited: Duration = .zero
        while !ready(), waited < cap {
            do { try await sleep(step) } catch { return }
            waited += step
        }
    }
}

/// The raven on its paper tile and the wordmark, on the app's paper, while Home loads.
struct SplashView: View {
    var body: some View {
        VStack(spacing: Theme.Space.m) {
            MarkView(size: 88)
            Wordmark(size: 34)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Theme.Color.bg.ignoresSafeArea())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AppConfig.displayName)
        .accessibilityIdentifier("splash")
    }
}
