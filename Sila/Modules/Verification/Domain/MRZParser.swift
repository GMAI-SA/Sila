import Foundation

/// A machine-readable zone, parsed and **check-digit verified** on device.
///
/// The camera reads the two (passport) or three (ID card) lines at the bottom
/// of the document; this turns them into the handful of facts the server
/// needs and refuses anything whose check digits do not add up. That refusal
/// is the point: OCR misreads, and a zone that is wrong by one character must
/// be a "retake the photo", not a wrong nationality on a badge.
///
/// Mirrors `app/mrz.py` on the server, which verifies the same digits again —
/// the client's copy exists so the person hears about a bad read before
/// uploading, not after.
public struct MRZ: Equatable, Sendable {

    /// `TD3` (passport), `TD2` (older cards, visas) or `TD1` (ID card).
    public let format: String
    public let documentCode: String
    /// ISO alpha-2, or `nil` when the zone's code is not a country.
    public let issuingCountry: String?
    public let issuingCountryRaw: String
    /// ISO alpha-2 — what the badge will show — or `nil` when the zone names
    /// no country (stateless, UN documents). The server decides what to do
    /// with `nil`; the client never guesses.
    public let nationality: String?
    public let nationalityRaw: String
    public let documentNumber: String
    public let dateOfBirth: Date?
    public let expiryDate: Date?
    public let sex: String
    public let surname: String
    public let givenNames: String
    /// `true` only when every check digit in the zone verifies.
    public let isValid: Bool
    public let errors: [String]

    /// The zone exactly as it should be sent to the server, lines joined
    /// with `\n`.
    public let text: String
}

public enum MRZParser {

    // MARK: - Check digits

    private static let weights = [7, 3, 1]

    /// The ICAO 7-3-1 check digit of `field`, or `nil` if it contains a
    /// character that cannot appear in a zone.
    public static func checkDigit(_ field: String) -> String? {
        var total = 0
        for (index, scalar) in field.unicodeScalars.enumerated() {
            let value: Int
            switch scalar {
            case "<": value = 0
            case "0"..."9": value = Int(scalar.value) - 48
            case "A"..."Z": value = Int(scalar.value) - 55
            default: return nil
            }
            total += value * weights[index % 3]
        }
        return String(total % 10)
    }

    private static func checksOut(_ field: String, _ digit: Character) -> Bool {
        if digit == "<" {
            return field.allSatisfy { $0 == "<" }
        }
        return checkDigit(field) == String(digit)
    }

    // MARK: - Parsing

    private static let formats: [String: String] = ["2x44": "TD3", "2x36": "TD2", "3x30": "TD1"]

    /// Lines as the OCR produced them, tidied: upper-cased, whitespace
    /// removed, and only lines made of zone characters kept. No repairs.
    public static func normaliseLines(_ text: String) -> [String] {
        text.replacingOccurrences(of: "\r", with: "\n")
            .split(separator: "\n", omittingEmptySubsequences: true)
            .map { line -> String in
                String(line.uppercased().unicodeScalars.filter { !$0.properties.isWhitespace })
            }
            .filter { line in
                !line.isEmpty && line.unicodeScalars.allSatisfy { scalar in
                    scalar == "<" || ("0"..."9").contains(scalar) || ("A"..."Z").contains(scalar)
                }
            }
    }

    /// Parses a zone. `nil` when the text is not shaped like one at all; an
    /// ``MRZ`` with `isValid == false` when it is, but a check digit fails.
    public static func parse(_ text: String) -> MRZ? {
        let lines = normaliseLines(text)
        guard let first = lines.first,
              let format = formats["\(lines.count)x\(first.count)"],
              lines.allSatisfy({ $0.count == first.count }) else { return nil }

        var errors: [String] = []
        func note(_ error: String) { if !errors.contains(error) { errors.append(error) } }

        let documentCode: String
        let issuingRaw: String
        let number: String
        let nationalityRaw: String
        let dobRaw: String
        let expiryRaw: String
        let sex: Character
        let names: String

        if format == "TD3" || format == "TD2" {
            let l1 = Array(lines[0]), l2 = Array(lines[1])
            documentCode = String(l1[0..<2])
            issuingRaw = String(l1[2..<5])
            names = String(l1[5...])

            number = String(l2[0..<9])
            if !checksOut(number, l2[9]) { note("document_number") }
            nationalityRaw = String(l2[10..<13])
            dobRaw = String(l2[13..<19])
            if !checksOut(dobRaw, l2[19]) { note("date_of_birth") }
            sex = l2[20]
            expiryRaw = String(l2[21..<27])
            if !checksOut(expiryRaw, l2[27]) { note("expiry_date") }

            if format == "TD3" {
                let optional = String(l2[28..<42])
                if !checksOut(optional, l2[42]) { note("optional_data") }
                let numberPart = String(l2[0..<10])
                let birthPart = String(l2[13..<20])
                let expiryPart = String(l2[21..<43])
                if !checksOut(numberPart + birthPart + expiryPart, l2[43]) { note("composite") }
            } else {
                let numberPart = String(l2[0..<10])
                let birthPart = String(l2[13..<20])
                let expiryPart = String(l2[21..<35])
                if !checksOut(numberPart + birthPart + expiryPart, l2[35]) { note("composite") }
            }
        } else {
            let l1 = Array(lines[0]), l2 = Array(lines[1]), l3 = lines[2]
            documentCode = String(l1[0..<2])
            issuingRaw = String(l1[2..<5])
            number = String(l1[5..<14])
            if !checksOut(number, l1[14]) { note("document_number") }
            dobRaw = String(l2[0..<6])
            if !checksOut(dobRaw, l2[6]) { note("date_of_birth") }
            sex = l2[7]
            expiryRaw = String(l2[8..<14])
            if !checksOut(expiryRaw, l2[14]) { note("expiry_date") }
            nationalityRaw = String(l2[15..<18])
            let upperPart = String(l1[5..<30])
            let birthPart = String(l2[0..<7])
            let expiryPart = String(l2[8..<15])
            let optionalPart = String(l2[18..<29])
            if !checksOut(upperPart + birthPart + expiryPart + optionalPart, l2[29]) { note("composite") }
            names = l3
        }

        let dateOfBirth = date(dobRaw, birth: true)
        if dateOfBirth == nil { note("date_of_birth") }
        let expiryDate = date(expiryRaw, birth: false)
        if expiryDate == nil { note("expiry_date") }

        let (surname, given) = split(names: names)

        return MRZ(
            format: format,
            documentCode: documentCode.replacingOccurrences(of: "<", with: ""),
            issuingCountry: CountryCode.fromAlpha3(issuingRaw),
            issuingCountryRaw: issuingRaw,
            nationality: CountryCode.fromAlpha3(nationalityRaw),
            nationalityRaw: nationalityRaw,
            documentNumber: number.replacingOccurrences(of: "<", with: ""),
            dateOfBirth: dateOfBirth,
            expiryDate: expiryDate,
            sex: (sex == "M" || sex == "F") ? String(sex) : "",
            surname: surname,
            givenNames: given,
            isValid: errors.isEmpty,
            errors: errors,
            text: lines.joined(separator: "\n")
        )
    }

    /// Parses, and when a check digit fails, retries with the misreads OCR
    /// makes in **numeric-only** positions corrected (`O`→`0`, `I`→`1`,
    /// `Z`→`2`, `S`→`5`, `B`→`8`).
    ///
    /// Safe because the repair is bounded to positions that can only hold
    /// digits and is accepted only when the whole zone then verifies — a
    /// repair that produces a different valid zone is not possible without
    /// defeating several check digits at once.
    public static func parseRepairing(_ text: String) -> MRZ? {
        if let strict = parse(text), strict.isValid { return strict }
        let lines = normaliseLines(text)
        guard let first = lines.first, let format = formats["\(lines.count)x\(first.count)"] else {
            return parse(text)
        }
        let repaired = lines.enumerated().map { index, line in
            repairDigits(in: line, positions: numericPositions(format: format, line: index))
        }
        if let fixed = parse(repaired.joined(separator: "\n")), fixed.isValid { return fixed }
        return parse(text)
    }

    // MARK: - Helpers

    private static let digitRepairs: [Character: Character] = ["O": "0", "I": "1", "Z": "2", "S": "5", "B": "8", "Q": "0", "D": "0"]

    private static func numericPositions(format: String, line: Int) -> [Int] {
        switch (format, line) {
        case ("TD3", 1): return [9] + Array(13...19) + Array(21...27) + [42, 43]
        case ("TD2", 1): return [9] + Array(13...19) + Array(21...27) + [35]
        case ("TD1", 0): return [14]
        case ("TD1", 1): return Array(0...6) + Array(8...14) + [29]
        default: return []
        }
    }

    private static func repairDigits(in line: String, positions: [Int]) -> String {
        var chars = Array(line)
        for position in positions where position < chars.count {
            if let digit = digitRepairs[chars[position]] { chars[position] = digit }
        }
        return String(chars)
    }

    private static func date(_ yymmdd: String, birth: Bool) -> Date? {
        guard yymmdd.count == 6, yymmdd.allSatisfy(\.isNumber),
              let yy = Int(yymmdd.prefix(2)),
              let mm = Int(yymmdd.dropFirst(2).prefix(2)),
              let dd = Int(yymmdd.suffix(2)) else { return nil }
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        let thisYear = calendar.component(.year, from: Date()) % 100
        let year = birth ? (yy > thisYear ? 1900 + yy : 2000 + yy) : 2000 + yy
        var components = DateComponents()
        components.year = year; components.month = mm; components.day = dd
        guard components.isValidDate(in: calendar) else { return nil }
        return calendar.date(from: components)
    }

    private static func split(names field: String) -> (String, String) {
        let parts = field.components(separatedBy: "<<")
        let surname = parts.first?.replacingOccurrences(of: "<", with: " ").trimmingCharacters(in: .whitespaces) ?? ""
        let given = parts.dropFirst().joined(separator: " ")
            .replacingOccurrences(of: "<", with: " ")
            .trimmingCharacters(in: .whitespaces)
        return (surname, given)
    }
}

// MARK: - Alpha-3

extension CountryCode {

    /// ISO 3166-1 alpha-3 (as printed in a zone) to the alpha-2 the rest of
    /// the app speaks, plus the ICAO-only codes: Germany prints `D`, the
    /// British-national categories all collapse to `GB`. Codes that are not
    /// countries — stateless `XXA`, `UNO`, the `UTO` of ICAO's specimens —
    /// map to `nil`. Never guesses.
    public static func fromAlpha3(_ raw: String) -> String? {
        let cleaned = raw.uppercased().replacingOccurrences(of: "<", with: "").trimmingCharacters(in: .whitespaces)
        guard !cleaned.isEmpty, let two = alpha3ToAlpha2[cleaned] else { return nil }
        // Through the same gate every other code passes, so the table cannot
        // introduce a region the badge renderer would refuse.
        return normalised(two)
    }

    static let alpha3ToAlpha2: [String: String] = {
        let table = """
        AFG:AF ALA:AX ALB:AL DZA:DZ ASM:AS AND:AD AGO:AO AIA:AI ATA:AQ ATG:AG ARG:AR ARM:AM
        ABW:AW AUS:AU AUT:AT AZE:AZ BHS:BS BHR:BH BGD:BD BRB:BB BLR:BY BEL:BE BLZ:BZ BEN:BJ
        BMU:BM BTN:BT BOL:BO BES:BQ BIH:BA BWA:BW BVT:BV BRA:BR IOT:IO BRN:BN BGR:BG BFA:BF
        BDI:BI CPV:CV KHM:KH CMR:CM CAN:CA CYM:KY CAF:CF TCD:TD CHL:CL CHN:CN CXR:CX CCK:CC
        COL:CO COM:KM COG:CG COD:CD COK:CK CRI:CR CIV:CI HRV:HR CUB:CU CUW:CW CYP:CY CZE:CZ
        DNK:DK DJI:DJ DMA:DM DOM:DO ECU:EC EGY:EG SLV:SV GNQ:GQ ERI:ER EST:EE SWZ:SZ ETH:ET
        FLK:FK FRO:FO FJI:FJ FIN:FI FRA:FR GUF:GF PYF:PF ATF:TF GAB:GA GMB:GM GEO:GE DEU:DE
        GHA:GH GIB:GI GRC:GR GRL:GL GRD:GD GLP:GP GUM:GU GTM:GT GGY:GG GIN:GN GNB:GW GUY:GY
        HTI:HT HMD:HM VAT:VA HND:HN HKG:HK HUN:HU ISL:IS IND:IN IDN:ID IRN:IR IRQ:IQ IRL:IE
        IMN:IM ISR:IL ITA:IT JAM:JM JPN:JP JEY:JE JOR:JO KAZ:KZ KEN:KE KIR:KI PRK:KP KOR:KR
        KWT:KW KGZ:KG LAO:LA LVA:LV LBN:LB LSO:LS LBR:LR LBY:LY LIE:LI LTU:LT LUX:LU MAC:MO
        MDG:MG MWI:MW MYS:MY MDV:MV MLI:ML MLT:MT MHL:MH MTQ:MQ MRT:MR MUS:MU MYT:YT MEX:MX
        FSM:FM MDA:MD MCO:MC MNG:MN MNE:ME MSR:MS MAR:MA MOZ:MZ MMR:MM NAM:NA NRU:NR NPL:NP
        NLD:NL NCL:NC NZL:NZ NIC:NI NER:NE NGA:NG NIU:NU NFK:NF MKD:MK MNP:MP NOR:NO OMN:OM
        PAK:PK PLW:PW PSE:PS PAN:PA PNG:PG PRY:PY PER:PE PHL:PH PCN:PN POL:PL PRT:PT PRI:PR
        QAT:QA REU:RE ROU:RO RUS:RU RWA:RW BLM:BL SHN:SH KNA:KN LCA:LC MAF:MF SPM:PM VCT:VC
        WSM:WS SMR:SM STP:ST SAU:SA SEN:SN SRB:RS SYC:SC SLE:SL SGP:SG SXM:SX SVK:SK SVN:SI
        SLB:SB SOM:SO ZAF:ZA SGS:GS SSD:SS ESP:ES LKA:LK SDN:SD SUR:SR SJM:SJ SWE:SE CHE:CH
        SYR:SY TWN:TW TJK:TJ TZA:TZ THA:TH TLS:TL TGO:TG TKL:TK TON:TO TTO:TT TUN:TN TUR:TR
        TKM:TM TCA:TC TUV:TV UGA:UG UKR:UA ARE:AE GBR:GB USA:US UMI:UM URY:UY UZB:UZ VUT:VU
        VEN:VE VNM:VN VGB:VG VIR:VI WLF:WF ESH:EH YEM:YE ZMB:ZM ZWE:ZW
        D:DE GBD:GB GBN:GB GBO:GB GBP:GB GBS:GB
        """
        var map: [String: String] = [:]
        for pair in table.split(whereSeparator: \.isWhitespace) {
            let parts = pair.split(separator: ":")
            if parts.count == 2 { map[String(parts[0])] = String(parts[1]) }
        }
        return map
    }()
}
