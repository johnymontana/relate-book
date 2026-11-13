import Foundation

/// How one Place heading is geocoded (D-F, D14). Pure; no I/O.
struct NormalizedHeading: Sendable, Equatable {
    enum Status: String, Sendable { case lookup, skipped }
    /// The stored heading, unchanged (the MATCH key).
    let name: String
    let status: Status
    /// The geocoder query; nil when skipped.
    let query: String?
    /// At most one fallback query ("Salinas River, California").
    let fallbackQuery: String?
    /// The base used for matching candidates and as the default label.
    let labelBase: String
    /// The first expanded qualifier ("Massachusetts"): the label-collision suffix.
    let qualifierLabel: String?
    /// "non-terrestrial" | "fictional setting" | "not a place" |
    /// "unresolved Wikidata id" | "malformed heading".
    let skipReason: String?

    static func skipped(_ name: String, labelBase: String, reason: String) -> NormalizedHeading {
        NormalizedHeading(name: name, status: .skipped, query: nil, fallbackQuery: nil, labelBase: labelBase,
                          qualifierLabel: nil, skipReason: reason)
    }
}

/// A port of wishlist-to-graph's `normalize_heading`, `skip_reason`,
/// `fold`, `tokens` and `significant` (wishlist-to-graph.py 1106–1446),
/// without the `SYNONYMS`, `MANUAL_REGIONS`, `QUERY_OVERRIDES` and
/// `CANON_CC` tables and without country-code or feature-type hints (D14):
/// every synonym heading is already in the bundled store, and a new heading
/// that names a known place reuses its label through the 1 km rule
/// (`PlaceLocator`). The tables below are copied verbatim from the
/// extension.
///
/// Swift's `lowercased()` stands in for Python's `casefold()`; they differ
/// only for a few characters such as "ß" (casefold gives "ss"), which no
/// table entry contains.
enum HeadingNormalizer {
    // MARK: Tables (verbatim from wishlist-to-graph.py)

    static let qualifierExpansions: [String: String] = [
        "Ala.": "Alabama", "Alaska": "Alaska", "Ariz.": "Arizona",
        "Ark.": "Arkansas", "Calif.": "California", "California": "California",
        "Colo.": "Colorado", "Conn.": "Connecticut", "Del.": "Delaware",
        "D.C.": "District of Columbia", "Fla.": "Florida", "Ga.": "Georgia",
        "Hawaii": "Hawaii", "Idaho": "Idaho", "Ill.": "Illinois",
        "Ind.": "Indiana", "Iowa": "Iowa", "Kan.": "Kansas",
        "Kans.": "Kansas", "Ky.": "Kentucky", "La.": "Louisiana",
        "Me.": "Maine", "Md.": "Maryland", "Mass.": "Massachusetts",
        "Mich.": "Michigan", "Minn.": "Minnesota", "Miss.": "Mississippi",
        "Mo.": "Missouri", "Mont.": "Montana", "Neb.": "Nebraska",
        "Nebr.": "Nebraska", "Nev.": "Nevada", "Nevada": "Nevada",
        "N.H.": "New Hampshire", "N.J.": "New Jersey", "N.M.": "New Mexico",
        "N.Y.": "New York", "N.C.": "North Carolina", "N.D.": "North Dakota",
        "Ohio": "Ohio", "Okla.": "Oklahoma", "Or.": "Oregon",
        "Ore.": "Oregon", "Pa.": "Pennsylvania", "R.I.": "Rhode Island",
        "S.C.": "South Carolina", "S.D.": "South Dakota", "Tenn.": "Tennessee",
        "Tex.": "Texas", "Texas": "Texas", "Utah": "Utah",
        "Vt.": "Vermont", "Va.": "Virginia", "Wash.": "Washington",
        "W. Va.": "West Virginia", "Wis.": "Wisconsin", "Wyo.": "Wyoming",
        "U.S.": "United States", "USA": "United States", "United States": "United States",
        "Alta.": "Alberta", "B.C.": "British Columbia", "Man.": "Manitoba",
        "N.B.": "New Brunswick", "N.S.": "Nova Scotia", "Ont.": "Ontario",
        "P.E.I.": "Prince Edward Island", "Que.": "Quebec", "Sask.": "Saskatchewan",
        "Nfld.": "Newfoundland and Labrador", "Canada": "Canada", "GB": "United Kingdom",
        "Rusia": "Russia", "Russian Federation": "Russia",
    ]
    static let knownAndNames: Set<String> = [
        "Antigua and Barbuda", "Bosnia and Herzegovina", "Saint Kitts and Nevis",
        "Saint Vincent and the Grenadines", "São Tomé and Príncipe", "Trinidad and Tobago",
        "Turks and Caicos Islands",
    ]
    static let countryCodeNames: Set<String> = [
        "Afghanistan", "Alabama", "Alaska", "Alberta", "Argentina",
        "Arizona", "Arkansas", "Australia", "Austria", "Brazil",
        "British Columbia", "California", "Canada", "Chile", "China",
        "Colombia", "Colorado", "Connecticut", "Delaware", "District of Columbia",
        "Egypt", "England", "Florida", "France", "Georgia",
        "Germany", "Great Britain", "Hawaii", "Idaho", "Illinois",
        "India", "Indiana", "Iowa", "Ireland", "Israel",
        "Italy", "Japan", "Kansas", "Kazakhstan", "Kentucky",
        "Louisiana", "Maine", "Manitoba", "Maryland", "Massachusetts",
        "Mexico", "Michigan", "Minnesota", "Mississippi", "Missouri",
        "Montana", "Nebraska", "Netherlands", "Nevada", "New Brunswick",
        "New Hampshire", "New Jersey", "New Mexico", "New York", "New York City",
        "Newfoundland and Labrador", "North Carolina", "North Dakota", "Northern Ireland", "Nova Scotia",
        "Ohio", "Oklahoma", "Ontario", "Oregon", "Pennsylvania",
        "Philippines", "Poland", "Prince Edward Island", "Quebec", "Rhode Island",
        "Russia", "Saskatchewan", "Scotland", "South Carolina", "South Dakota",
        "Spain", "Sweden", "Switzerland", "Tennessee", "Texas",
        "Trinidad and Tobago", "United Kingdom", "United States", "Utah", "Venezuela",
        "Vermont", "Virginia", "Wales", "Washington", "West Virginia",
        "Wisconsin", "Wyoming",
    ]
    static let skipSpace: Set<String> = [
        "acidalia planitia", "arabia terra", "callisto", "ceres", "cyberspace", "deimos",
        "earth", "enceladus", "europa", "ganymede", "io", "jupiter",
        "mars", "mercury", "moon", "neptune", "opportunity region", "outer space",
        "phobos", "pluto", "saturn", "schiaparelli", "shi jie", "solar system",
        "space", "sun", "terra", "titan", "universe", "uranus",
        "venus", "world",
    ]
    static let skipFictional: Set<String> = [
        "allia", "ankh morpork", "arcara", "arrakis", "asgard",
        "castrima", "central london hatchery", "dibars", "discworld", "fulcrum",
        "gethen", "griboyedov's house", "hail mary", "hermes", "hogwarts",
        "imaginary places", "jezebel's", "london below", "lynn marness' lake", "meov",
        "middle-earth", "midgard", "mordor", "narnia", "palela",
        "panem", "pelapatarn", "republic of gilead", "schar's world", "st. deborah by the water",
        "tirimo", "trantor", "unseen university", "vavatch", "westeros",
        "yumenes",
    ]
    static let skipNotPlace: Set<String> = [
        "alien ship of some sort", "cold regions", "colonies", "developing countries",
        "developing country", "dogs", "ficcion", "foreign countries",
        "his home town and some planets and moons", "northern forests", "sailors", "the brain",
        "yesyesyesyesyesyes",
    ]
    static let genericSuffixes: Set<String> = [
        "area", "kommun", "municipality", "region", "valley", "watershed",
    ]
    static let stateQualifiers: Set<String> = [
        "estado", "etat", "state",
    ]
    static let tokenAliases: [String: String] = [
        "st": "saint", "ste": "sainte", "mt": "mount", "ft": "fort", "&": "and",
    ]
    static let matchStopwords: Set<String> = [
        "and", "area", "city", "de", "del", "des", "du", "la",
        "le", "les", "of", "region", "regions", "state", "the",
    ]

    // Regexes (compiled per call: places are geocoded a few at a time).
    static let celestialQualifierPattern = #"\b(mars|planet|planete|planeta|moon|lune|luna|venus|fictional|imaginary|imaginaire)\b"#
    static let fictionalQualifierPattern = #"\b(fictional|imaginary|imaginaire)\b"#
    static let starSystemPattern = #"^(alpha|beta|gamma|delta|epsilon|zeta|eta|theta|iota|kappa|lambda|mu|nu|xi|omicron|pi|rho|sigma|tau|upsilon|phi|chi|psi|omega|\d+)\s+(eridani|ceti|centauri|indi|hydri|leporis|cygni|draconis|pegasi|lyrae|orionis|tauri|ursae|bootis|aquilae|persei|scorpii|virginis|leonis|geminorum|pavonis|tucanae|arietis|piscium|ophiuchi|sagittarii|capricorni|aquarii|librae|cancri|andromedae|cassiopeiae)\b"#
    static let marsFeaturePattern = #"\b(planitia|planum|vallis|valles|chasma|fossae|patera)\b"#
    static let nonPlacePattern = #"^(scp-\d+|site \d+|q\d+)$"#
    static let wikidataIDPattern = #"^q\d+$"#
    static let qualifiedPattern = #"^(?<base>.+?)\s*\((?<qual>[^()]*)\)\s*$"#

    /// `re.search(pattern, text)` with Python's simple word boundaries.
    static func search(_ pattern: String, _ text: String) -> Bool {
        guard let regex = try? Regex(pattern) else { return false }
        return text.firstMatch(of: regex.wordBoundaryKind(.simple)) != nil
    }

    // MARK: Text keys

    /// NFKD, combining marks dropped, ’‘`´ → ', lowercased, whitespace
    /// collapsed, trimmed.
    static func fold(_ s: String) -> String {
        let decomposed = s.decomposedStringWithCompatibilityMapping
        var scalars = String.UnicodeScalarView()
        for scalar in decomposed.unicodeScalars where scalar.properties.canonicalCombiningClass.rawValue == 0 {
            scalars.append(scalar)
        }
        var text = String(scalars)
        for quote in ["’", "‘", "`", "´"] { text = text.replacingOccurrences(of: quote, with: "'") }
        return collapseWhitespace(text.lowercased())
    }

    /// `[a-z0-9]+` runs of `fold(s)` with apostrophes removed; aliases
    /// st → saint, ste → sainte, mt → mount, ft → fort.
    static func tokens(_ s: String) -> [String] {
        var out: [String] = []
        var current = ""
        for scalar in fold(s).replacingOccurrences(of: "'", with: "").unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                out.append(current)
                current = ""
            }
        }
        if !current.isEmpty { out.append(current) }
        return out.map { tokenAliases[$0] ?? $0 }
    }

    /// `tokens(s)` minus `matchStopwords`; all tokens if that leaves none.
    static func significant(_ s: String) -> Set<String> {
        let all = tokens(s)
        let kept = Set(all.filter { !matchStopwords.contains($0) })
        return kept.isEmpty ? Set(all) : kept
    }

    static func collapseWhitespace(_ s: String) -> String {
        s.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }

    // MARK: Skip rules

    /// Why a heading gets no coordinates at all, or nil (`skip_reason`).
    static func skipReason(heading: String, base: String?, qualifier: String?) -> String? {
        let k = fold(heading)
        var keys = [k]
        if let base { keys.append(fold(base)) }
        for key in keys {
            if skipSpace.contains(key) { return "non-terrestrial" }
            if skipFictional.contains(key) { return "fictional setting" }
            if skipNotPlace.contains(key) { return "not a place" }
        }
        if let qualifier {
            let folded = fold(qualifier)
            if search(celestialQualifierPattern, folded) {
                return search(fictionalQualifierPattern, folded) ? "fictional setting" : "non-terrestrial"
            }
        }
        if search(starSystemPattern, k) || search(marsFeaturePattern, k) { return "non-terrestrial" }
        if search(nonPlacePattern, k) {
            return search(wikidataIDPattern, k) ? "unresolved Wikidata id" : "fictional setting"
        }
        return nil
    }

    /// "Salinas River Valley" → "Salinas River"; nil unless the last of two
    /// or more words is a generic suffix.
    static func dropGenericSuffix(_ text: String) -> String? {
        let words = text.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard words.count >= 2, genericSuffixes.contains(words[words.count - 1].lowercased()) else { return nil }
        return words.dropLast().joined(separator: " ")
    }

    // MARK: normalize_heading

    /// One stored Place heading → how to geocode it.
    static func normalize(_ name: String) -> NormalizedHeading {
        var heading = collapseWhitespace(name.precomposedStringWithCanonicalMapping)
        if let semicolon = heading.firstIndex(of: ";") {
            heading = String(heading[..<semicolon]).trimmingCharacters(in: .whitespaces)
        }
        let opens = heading.filter { $0 == "(" }.count
        let closes = heading.filter { $0 == ")" }.count
        if closes > opens || !heading.contains(where: { $0.isLetter }) {
            return .skipped(name, labelBase: heading, reason: "malformed heading")
        }
        if opens > closes { heading += String(repeating: ")", count: opens - closes) }

        var base: String?
        var qual: String?
        if let regex = try? Regex(qualifiedPattern), let match = heading.wholeMatch(of: regex) {
            base = match.output["base"]?.substring.map { String($0).trimmingCharacters(in: .whitespaces) }
            qual = match.output["qual"]?.substring.map { String($0).trimmingCharacters(in: .whitespaces) }
        }
        if let reason = skipReason(heading: heading, base: base, qualifier: qual) {
            return .skipped(name, labelBase: base ?? heading, reason: reason)
        }

        guard var base, var qual else {
            return NormalizedHeading(name: name, status: .lookup, query: heading,
                                     fallbackQuery: dropGenericSuffix(heading), labelBase: heading,
                                     qualifierLabel: nil, skipReason: nil)
        }
        var labelBase = base
        if stateQualifiers.contains(fold(qual)) {
            base = "\(base) State"
            labelBase = base
            qual = ""
        }
        if let range = qual.range(of: " : ") {
            let left = String(qual[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
            let right = String(qual[range.upperBound...]).trimmingCharacters(in: .whitespaces)
            base = "\(base) \(right)"
            labelBase = base
            qual = left
        }
        qual = qual.replacingOccurrences(of: "New York, N.Y.", with: "New York City")
        var expanded: [String] = []
        var secondHalf: String?
        for rawPart in qual.split(separator: ",", omittingEmptySubsequences: false) {
            var part = rawPart.trimmingCharacters(in: .whitespaces)
            if part.isEmpty { continue }
            if part.contains(" and "), !knownAndNames.contains(part), let range = part.range(of: " and ") {
                let other = String(part[range.upperBound...]).trimmingCharacters(in: .whitespaces)
                part = String(part[..<range.lowerBound]).trimmingCharacters(in: .whitespaces)
                if secondHalf == nil, !other.isEmpty { secondHalf = qualifierExpansions[other] ?? other }
            }
            if let dash = part.firstIndex(of: "-") {
                let head = String(part[..<dash]).trimmingCharacters(in: .whitespaces)
                if qualifierExpansions[head] != nil || countryCodeNames.contains(head) { part = head }
            }
            expanded.append(qualifierExpansions[part] ?? part)
        }
        let tail = expanded.isEmpty ? "" : ", " + expanded.joined(separator: ", ")
        var fallback = dropGenericSuffix(base).map { $0 + tail }
        if fallback == nil, let secondHalf, !expanded.isEmpty {
            fallback = ([base, secondHalf] + expanded.dropFirst()).joined(separator: ", ")
        }
        return NormalizedHeading(name: name, status: .lookup, query: base + tail, fallbackQuery: fallback,
                                 labelBase: labelBase, qualifierLabel: expanded.first, skipReason: nil)
    }
}
