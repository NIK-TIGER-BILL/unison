import Testing
@testable import UnisonUI

@Test func russianPlural_selectsCorrectForm() {
    func v(_ n: Int) -> String { russianPlural(n, "встреча", "встречи", "встреч") }
    #expect(v(1) == "встреча")
    #expect(v(2) == "встречи")
    #expect(v(4) == "встречи")
    #expect(v(5) == "встреч")
    #expect(v(11) == "встреч")
    #expect(v(14) == "встреч")
    #expect(v(21) == "встреча")
    #expect(v(22) == "встречи")
    #expect(v(0) == "встреч")
}
