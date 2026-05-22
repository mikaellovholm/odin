#if os(macOS)
import SwiftUI

struct AboutView: View {
    private let attnURL = URL(string: "https://github.com/victorarias/attn")!

    private var appName: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleDisplayName") as? String
            ?? Bundle.main.object(forInfoDictionaryKey: "CFBundleName") as? String
            ?? "Odin"
    }

    private var versionString: String {
        let short = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0"
        let build = Bundle.main.object(forInfoDictionaryKey: "CFBundleVersion") as? String ?? "1"
        return "Version \(short) (\(build))"
    }

    var body: some View {
        VStack(spacing: 18) {
            if let appIcon = NSImage(named: "AppIcon") ?? NSApp.applicationIconImage {
                Image(nsImage: appIcon)
                    .resizable()
                    .interpolation(.high)
                    .frame(width: 96, height: 96)
            }

            VStack(spacing: 4) {
                Text(appName)
                    .font(.system(size: 22, weight: .semibold))
                Text(versionString)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }

            Divider()
                .padding(.horizontal, 24)

            VStack(spacing: 12) {
                Text("Inspired by")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)

                HStack(spacing: 12) {
                    Image("AttnIcon")
                        .resizable()
                        .interpolation(.high)
                        .frame(width: 48, height: 48)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))

                    VStack(spacing: 2) {
                        Link("attn", destination: attnURL)
                            .font(.system(size: 15, weight: .medium))
                        Text("by Victor Arias")
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    .multilineTextAlignment(.center)

                    Image("VictorFace")
                        .resizable()
                        .interpolation(.high)
                        .scaledToFill()
                        .frame(width: 48, height: 48)
                        .clipShape(Circle())
                }
            }
        }
        .padding(.vertical, 24)
        .padding(.horizontal, 28)
        .frame(width: 360)
    }
}
#endif
