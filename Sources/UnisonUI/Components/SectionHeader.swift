import SwiftUI

/// Uppercase caps section title used in Settings. Monospaced, faded white,
/// 0.14em letter-spacing — DESIGN.md §5.10.
public struct SectionHeader: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        Text(text)
            .font(UnisonFonts.sectionHead())
            .textCase(.uppercase)
            .tracking(1.4)
            .foregroundStyle(UnisonColors.whiteAlpha(0.42))
            .padding(.top, 18)
            .padding(.bottom, 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

