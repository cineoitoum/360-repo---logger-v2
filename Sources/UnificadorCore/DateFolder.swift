import Foundation

/// Extração da pasta de data a partir de VID_AAAAMMDD_HHMMSS.
public enum DateFolder {
    public static let undatedFolderName = "_sem_data"

    /// "VID_20261108_162608" → "261108". Nome fora do padrão (ou data inválida) → nil.
    public static func dateFolderName(for folderName: String) -> String? {
        let b = Array(folderName.utf8)
        // V I D _ Y Y Y Y M M D D _ h h m m s s  → 19 bytes
        guard b.count == 19,
              b[0] == UInt8(ascii: "V"), b[1] == UInt8(ascii: "I"), b[2] == UInt8(ascii: "D"),
              b[3] == UInt8(ascii: "_"), b[12] == UInt8(ascii: "_") else { return nil }
        let digitRanges = [4..<12, 13..<19]
        for r in digitRanges {
            for i in r where !(b[i] >= 48 && b[i] <= 57) { return nil }
        }
        func num(_ r: Range<Int>) -> Int { r.reduce(0) { $0 * 10 + Int(b[$1] - 48) } }
        let year = num(4..<8), month = num(8..<10), day = num(10..<12)
        let hour = num(13..<15), minute = num(15..<17), second = num(17..<19)
        guard (1...12).contains(month), day >= 1, day <= daysIn(month: month, year: year),
              hour < 24, minute < 60, second < 60 else { return nil }
        return String(decoding: b[6..<12], as: UTF8.self)
    }

    static func daysIn(month: Int, year: Int) -> Int {
        switch month {
        case 2:
            let leap = (year % 4 == 0 && year % 100 != 0) || year % 400 == 0
            return leap ? 29 : 28
        case 4, 6, 9, 11: return 30
        default: return 31
        }
    }
}
