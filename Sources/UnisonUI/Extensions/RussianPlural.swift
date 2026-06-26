import Foundation

/// Russian plural selector. `one` for 1/21/31…, `few` for 2-4/22-24…,
/// `many` for 0/5-20/11-14… E.g. `russianPlural(n, "встреча", "встречи", "встреч")`.
func russianPlural(_ n: Int, _ one: String, _ few: String, _ many: String) -> String {
    let mod10 = abs(n) % 10
    let mod100 = abs(n) % 100
    if mod10 == 1 && mod100 != 11 { return one }
    if (2...4).contains(mod10) && !(12...14).contains(mod100) { return few }
    return many
}
