import SwiftUI
import AVFoundation
import AVKit

/// Full-screen intro video. Plays once; on end or Skip, calls `onFinish`.
/// Uses `SecureNode – iPhone Demo.mp4` in the app bundle (add to SecureNode group).
struct IntroVideoView: View {
    var onFinish: () -> Void

    @State private var player: AVPlayer?
    @State private var hasEnded = false

    private static let videoName = "SecureNode – iPhone Demo"
    private static let videoExtension = "mp4"

    var body: some View {
        ZStack {
            if let url = Bundle.main.url(forResource: Self.videoName, withExtension: Self.videoExtension), !hasEnded {
                IntroPlayerView(url: url, onEnd: {
                    hasEnded = true
                    onFinish()
                })
                .ignoresSafeArea()
                VStack {
                    Spacer()
                    Button("Skip") {
                        hasEnded = true
                        onFinish()
                    }
                    .font(.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 10)
                    .background(Color.black.opacity(0.5))
                    .clipShape(Capsule())
                    .padding(.bottom, 50)
                }
            } else {
                Color.black
                    .ignoresSafeArea()
                    .onAppear { onFinish() }
            }
        }
        .onAppear {
            if Bundle.main.url(forResource: Self.videoName, withExtension: Self.videoExtension) == nil {
                hasEnded = true
                onFinish()
            }
        }
    }
}

private struct IntroPlayerView: UIViewControllerRepresentable {
    let url: URL
    let onEnd: () -> Void

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let player = AVPlayer(url: url)
        let vc = AVPlayerViewController()
        vc.player = player
        vc.showsPlaybackControls = false
        context.coordinator.observeEnd(player: player)
        player.play()
        return vc
    }

    func updateUIViewController(_ uiViewController: AVPlayerViewController, context: Context) {}

    func makeCoordinator() -> Coordinator {
        Coordinator(onEnd: onEnd)
    }

    final class Coordinator {
        private let onEnd: () -> Void
        private var observer: NSObjectProtocol?

        init(onEnd: @escaping () -> Void) {
            self.onEnd = onEnd
        }

        func observeEnd(player: AVPlayer) {
            observer = NotificationCenter.default.addObserver(
                forName: .AVPlayerItemDidPlayToEndTime,
                object: player.currentItem,
                queue: .main
            ) { [weak self] _ in
                self?.onEnd()
            }
        }

        deinit {
            if let o = observer {
                NotificationCenter.default.removeObserver(o)
            }
        }
    }
}
