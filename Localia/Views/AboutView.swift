import SwiftUI

/// Version and the credits from the bundled `THIRD_PARTY_NOTICES.md`.
struct AboutView: View {
    private var version: String {
        let info = Bundle.main.infoDictionary
        let v = info?["CFBundleShortVersionString"] as? String ?? "?"
        let b = info?["CFBundleVersion"] as? String ?? "?"
        return String(localized: "Version \(v) (\(b))")
    }

    private var notices: AttributedString {
        guard let url = Bundle.main.url(forResource: "THIRD_PARTY_NOTICES", withExtension: "md"),
              let text = try? String(contentsOf: url, encoding: .utf8) else {
            return AttributedString(String(localized: "Third-party notices are missing from this build."))
        }
        // Headings become bold lines; the rest keeps inline Markdown (links, code).
        var out = AttributedString()
        for line in text.components(separatedBy: "\n") {
            if line.hasPrefix("# ") { continue }   // the window already has a title
            var piece: AttributedString
            if line.hasPrefix("## ") {
                piece = AttributedString(String(line.dropFirst(3)))
                piece.font = .headline
            } else {
                piece = (try? AttributedString(markdown: line, options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
                    ?? AttributedString(line)
            }
            out += piece + AttributedString("\n")
        }
        return out
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Image(systemName: "cpu.fill").font(.system(size: 36)).foregroundStyle(Color.accentColor)
                VStack(alignment: .leading) {
                    Text("Localia").font(.title.weight(.semibold))
                    Text(version).foregroundStyle(.secondary)
                }
            }
            Text(String(localized: "Local coding models on this Mac, in one click. Free and open source."))
            Divider()
            Text(String(localized: "Credits")).font(.headline)
            ScrollView {
                Text(notices).font(.callout).textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(20)
        .frame(minWidth: 460, minHeight: 420)
    }
}
