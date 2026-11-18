import Foundation

/// Whole numbers read from `JSONSerialization` output. Booleans, strings, non-finite values and anything past
/// `Int32.max` are refused; fractions are truncated.
enum JSONNumbers {
    /// At least 1 (a context length, a count that cannot be zero).
    static func positiveInt(_ v: Any?) -> Int? {
        guard let d = finiteDouble(v), d >= 1, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }

    /// At least 0 (a token count).
    static func nonNegativeInt(_ v: Any?) -> Int? {
        guard let d = finiteDouble(v), d >= 0, d <= Double(Int32.max) else { return nil }
        return Int(d)
    }

    private static func finiteDouble(_ v: Any?) -> Double? {
        guard let n = v as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
        let d = n.doubleValue
        return d.isFinite ? d : nil
    }
}
