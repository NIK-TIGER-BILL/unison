import Testing
@testable import UnisonDomain
@testable import UnisonUI

// MARK: - fraction(of:in:)

@Test func neutralSlider_fraction_zeroAtLowerBound() {
    let f = NeutralSlider.fraction(of: 0, in: 0...100)
    #expect(f == 0)
}

@Test func neutralSlider_fraction_oneAtUpperBound() {
    let f = NeutralSlider.fraction(of: 100, in: 0...100)
    #expect(f == 1)
}

@Test func neutralSlider_fraction_halfAtMidpoint() {
    let f = NeutralSlider.fraction(of: 50, in: 0...100)
    #expect(abs(f - 0.5) < 1e-12)
}

@Test func neutralSlider_fraction_clampsAboveUpperBound() {
    let f = NeutralSlider.fraction(of: 150, in: 0...100)
    #expect(f == 1)
}

@Test func neutralSlider_fraction_clampsBelowLowerBound() {
    let f = NeutralSlider.fraction(of: -50, in: 0...100)
    #expect(f == 0)
}

@Test func neutralSlider_fraction_zeroSpanRange_returnsZero() {
    let f = NeutralSlider.fraction(of: 5, in: 5...5)
    #expect(f == 0)
}

// MARK: - fillOpacity(for:)

@Test func neutralSlider_fillOpacity_atZeroFractionEquals0_12() {
    let o = NeutralSlider.fillOpacity(for: 0)
    #expect(abs(o - 0.12) < 1e-12)
}

@Test func neutralSlider_fillOpacity_atOneFractionEquals0_85() {
    let o = NeutralSlider.fillOpacity(for: 1)
    #expect(abs(o - 0.85) < 1e-12)
}

@Test func neutralSlider_fillOpacity_atHalfFraction_isMidpoint() {
    let o = NeutralSlider.fillOpacity(for: 0.5)
    // 0.12 + 0.5 * 0.73 = 0.485
    #expect(abs(o - 0.485) < 1e-12)
}

@Test func neutralSlider_fillOpacity_clampsBelowZero() {
    let o = NeutralSlider.fillOpacity(for: -0.4)
    #expect(o == 0.12)
}

@Test func neutralSlider_fillOpacity_clampsAboveOne() {
    let o = NeutralSlider.fillOpacity(for: 2.0)
    #expect(o == 0.85)
}

// MARK: - LanguagePickerDropdown filter helper

@Test func languagePickerFilter_emptyQueryReturnsAll() {
    let all = LanguagePickerDropdown.filter([.ru, .en, .ja], query: "")
    #expect(all == [.ru, .en, .ja])
}

@Test func languagePickerFilter_matchesByDisplayName() {
    // "русск" matches the Russian display name "Русский" (case-insensitive
    // substring), but not English's "English".
    let found = LanguagePickerDropdown.filter(Array(Language.allCases), query: "русск")
    #expect(found.contains(.ru))
    #expect(found.contains(.en) == false)
}

@Test func languagePickerFilter_matchesByCode() {
    let found = LanguagePickerDropdown.filter(Array(Language.allCases), query: "ja")
    #expect(found.contains(.ja))
}

@Test func languagePickerFilter_caseInsensitive() {
    let found = LanguagePickerDropdown.filter(Array(Language.allCases), query: "ENGLISH")
    #expect(found.contains(.en))
}

// MARK: - TranscriptSettingsPopover size mapping

@Test func transcriptSettings_sizeLabel_atKnownIndexes() {
    #expect(TranscriptSettingsPopover.sizeLabel(for: 0) == "XS")
    #expect(TranscriptSettingsPopover.sizeLabel(for: 1) == "S")
    #expect(TranscriptSettingsPopover.sizeLabel(for: 2) == "M")
    #expect(TranscriptSettingsPopover.sizeLabel(for: 3) == "L")
    #expect(TranscriptSettingsPopover.sizeLabel(for: 4) == "XL")
}

@Test func transcriptSettings_sizeLabel_clampsOutOfRange() {
    #expect(TranscriptSettingsPopover.sizeLabel(for: -1) == "XS")
    #expect(TranscriptSettingsPopover.sizeLabel(for: 99) == "XL")
}

@Test func transcriptSettings_bubbleScale_interpolatesBetween075And13() {
    #expect(abs(TranscriptSettingsPopover.bubbleScale(for: 0) - 0.75) < 1e-12)
    #expect(abs(TranscriptSettingsPopover.bubbleScale(for: 4) - 1.30) < 1e-12)
    // Midpoint should land at the arithmetic mean.
    #expect(abs(TranscriptSettingsPopover.bubbleScale(for: 2) - 1.025) < 1e-12)
}
