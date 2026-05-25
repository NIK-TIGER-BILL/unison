import Testing
import SwiftUI
@testable import UnisonUI

// MARK: - Helpers

/// Walks a SwiftUI `Path` and counts subpaths (a "subpath" begins at every
/// `move(to:)`). The full Unison logo has five subpaths: 1 for the U and
/// 4 for the side voice-stream bars. The paused variant has 1.
private func countSubpaths(in path: Path) -> Int {
    var count = 0
    path.forEach { element in
        if case .move = element {
            count += 1
        }
    }
    return count
}

private struct ElementCounts {
    var moves = 0
    var lines = 0
    var curves = 0
    var quadCurves = 0
    var closes = 0
}

private func countElements(in path: Path) -> ElementCounts {
    var counts = ElementCounts()
    path.forEach { element in
        switch element {
        case .move:       counts.moves      += 1
        case .line:       counts.lines      += 1
        case .curve:      counts.curves     += 1
        case .quadCurve:  counts.quadCurves += 1
        case .closeSubpath: counts.closes   += 1
        }
    }
    return counts
}

// MARK: - Tests

@Test func unisonLogo_full_hasFiveSubpaths() {
    let shape = UnisonLogoShape(showVoiceStreams: true)
    let path = shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
    #expect(countSubpaths(in: path) == 5)
}

@Test func unisonLogo_paused_hasOneSubpath() {
    let shape = UnisonLogoShape(showVoiceStreams: false)
    let path = shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256))
    #expect(countSubpaths(in: path) == 1)
}

@Test func unisonLogo_full_hasExpectedElements() {
    // U letter contributes: 1 move, 2 lines (left vertical, right vertical),
    // 2 curves (left and right bottom rounding).
    // Each of the 4 side bars contributes: 1 move + 1 line.
    // Total expected: 5 moves, 6 lines, 2 curves.
    let shape = UnisonLogoShape(showVoiceStreams: true)
    let counts = countElements(in: shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256)))
    #expect(counts.moves == 5)
    #expect(counts.lines == 6)
    #expect(counts.curves == 2)
    #expect(counts.quadCurves == 0)
    #expect(counts.closes == 0)
}

@Test func unisonLogo_paused_hasNoSideBars() {
    // Only the U: 1 move, 2 lines, 2 curves.
    let shape = UnisonLogoShape(showVoiceStreams: false)
    let counts = countElements(in: shape.path(in: CGRect(x: 0, y: 0, width: 256, height: 256)))
    #expect(counts.moves == 1)
    #expect(counts.lines == 2)
    #expect(counts.curves == 2)
}

@Test func unisonLogo_aspectFits_intoNonSquareRect() {
    // For a rect wider than tall, the logo should center horizontally
    // and consume the full height. The bounding box of the produced path
    // should fit within the rect.
    let shape = UnisonLogoShape(showVoiceStreams: true)
    let path = shape.path(in: CGRect(x: 0, y: 0, width: 400, height: 200))
    let bounds = path.boundingRect

    // Path is non-empty.
    #expect(bounds.width > 0)
    #expect(bounds.height > 0)

    // The drawn area must respect the smaller dimension (200pt).
    // The 256-unit design space → scale 200/256 ≈ 0.781.
    // Logo bars span x=38..218 (180/256 ≈ 70%) and y=66..198 (132/256 ≈ 52%).
    #expect(bounds.height <= 200)
    #expect(bounds.width <= 400)
}

@Test func unisonLogo_defaultInit_showsVoiceStreams() {
    let shape = UnisonLogoShape()
    #expect(shape.showVoiceStreams == true)
}
