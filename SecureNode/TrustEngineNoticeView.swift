import SwiftUI

/// Shown once on first launch (TestFlight install). Explains Trust Engine and setup steps.
struct TrustEngineNoticeView: View {
    var onContinue: () -> Void

    var body: some View {
        ZStack {
            Color.black
                .ignoresSafeArea()
            VStack(spacing: 24) {
                Spacer()
                Text("SecureNode Trust Engine is active.")
                    .font(.title2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                Text("This app enables verified caller identity to be shown by iOS for approved phone numbers.")
                    .font(.body)
                    .foregroundStyle(.white.opacity(0.9))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                VStack(alignment: .leading, spacing: 8) {
                    Text("To complete setup:")
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundStyle(.white)
                    Text("• Open Settings")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("• Go to Phone → Call Blocking & Identification")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                    Text("• Enable SecureNode")
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 32)
                Text("No calls are intercepted or recorded.")
                    .font(.footnote)
                    .foregroundStyle(.white.opacity(0.7))
                    .multilineTextAlignment(.center)
                    .padding(.horizontal)
                Spacer()
                Button("Continue") {
                    onContinue()
                }
                .font(.headline)
                .foregroundStyle(.black)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .background(Color.white)
                .clipShape(RoundedRectangle(cornerRadius: 12))
                .padding(.horizontal, 24)
                .padding(.bottom, 40)
            }
        }
    }
}
