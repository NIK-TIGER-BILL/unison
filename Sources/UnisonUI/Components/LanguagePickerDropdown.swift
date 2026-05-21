import SwiftUI
import UnisonDomain

/// Portal-style language picker. Search row + scrollable list.
/// Selected language renders white-bold; no accent color.
/// Hover / keyboard-focus uses 10% white background. DESIGN.md §5.8.
public struct LanguagePickerDropdown: View {
    public let languages: [Language]
    @Binding public var selection: Language
    public let onPick: (Language) -> Void
    public let onCancel: () -> Void

    public init(
        languages: [Language] = Language.allCases,
        selection: Binding<Language>,
        onPick: @escaping (Language) -> Void,
        onCancel: @escaping () -> Void = {}
    ) {
        self.languages = languages
        self._selection = selection
        self.onPick = onPick
        self.onCancel = onCancel
    }

    @SwiftUI.State private var query: String = ""
    @SwiftUI.State private var focusedIndex: Int = 0

    private var filtered: [Language] {
        Self.filter(languages, query: query)
    }

    public var body: some View {
        VStack(spacing: 0) {
            SearchField(text: $query)
                .padding(.horizontal, 2)
                .padding(.bottom, 6)
            ScrollView {
                LazyVStack(spacing: 1) {
                    if filtered.isEmpty {
                        Text("Ничего не найдено")
                            .font(.system(size: 12))
                            .foregroundStyle(UnisonColors.whiteAlpha(0.4))
                            .padding(.vertical, 14)
                    } else {
                        ForEach(Array(filtered.enumerated()), id: \.element) { idx, lang in
                            row(for: lang, isKeyboardFocused: idx == focusedIndex)
                                .onTapGesture {
                                    pick(lang)
                                }
                        }
                    }
                }
            }
            .frame(maxHeight: 200)
        }
        .padding(5)
        .liquidGlass(cornerRadius: 13)
        .frame(width: 220)
        .onAppear {
            // Seed focus on the currently-selected language if visible.
            focusedIndex = filtered.firstIndex(of: selection) ?? 0
        }
        .onChange(of: query) { _, _ in
            focusedIndex = 0
        }
        // ↑ ↓ Enter Esc handled via SwiftUI 14+ APIs.
        .onKeyPress(.upArrow) {
            if !filtered.isEmpty {
                focusedIndex = max(0, focusedIndex - 1)
            }
            return .handled
        }
        .onKeyPress(.downArrow) {
            if !filtered.isEmpty {
                focusedIndex = min(filtered.count - 1, focusedIndex + 1)
            }
            return .handled
        }
        .onKeyPress(.return) {
            if filtered.indices.contains(focusedIndex) {
                pick(filtered[focusedIndex])
            }
            return .handled
        }
        .onKeyPress(.escape) {
            onCancel()
            return .handled
        }
    }

    private func row(for lang: Language, isKeyboardFocused: Bool) -> some View {
        let isSelected = lang == selection
        return HStack(spacing: 9) {
            FlagText(lang.flagEmoji)
            Text(lang.displayName)
                .font(.system(size: 12.5, weight: isSelected ? .semibold : .regular))
                .foregroundStyle(isSelected ? .white : UnisonColors.whiteAlpha(0.85))
            Spacer(minLength: 0)
            if isSelected {
                Image(systemName: "checkmark")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white)
            }
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(isKeyboardFocused ? UnisonColors.whiteAlpha(0.10) : Color.clear)
        )
        .contentShape(Rectangle())
    }

    private func pick(_ lang: Language) {
        selection = lang
        onPick(lang)
    }

    /// Pure filter used by tests as well. Case-insensitive substring match
    /// against both the language display name and its ISO code.
    public nonisolated static func filter(_ languages: [Language], query: String) -> [Language] {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return languages }
        let needle = trimmed.lowercased()
        return languages.filter {
            $0.displayName.lowercased().contains(needle)
                || $0.rawValue.lowercased().contains(needle)
        }
    }
}

