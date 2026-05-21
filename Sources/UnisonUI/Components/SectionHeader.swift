import SwiftUI

/// Title-case section title for lists/forms.
///
/// Per Apple's official Liquid Glass guidance ("Adopting Liquid Glass"):
/// > "Lists, tables, and forms optimize for legibility by adopting
/// > title-style capitalization for section headers."
///
/// This is the natural-casing label used inside our manual sections
/// where `Form` + `.formStyle(.grouped)` cannot be applied. The system
/// `Form` already renders its `Section("Title")` header the same way;
/// this view is for parity in the places we still hand-roll sections.
public struct SectionHeader: View {
    public let text: String

    public init(_ text: String) {
        self.text = text
    }

    public var body: some View {
        // HIG Materials: vibrant `.primary` so section titles get the
        // system's contrast / Increase Contrast treatment on glass.
        Text(text)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(.primary)
            .padding(.top, 18)
            .padding(.bottom, 6)
            .padding(.horizontal, 16)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

