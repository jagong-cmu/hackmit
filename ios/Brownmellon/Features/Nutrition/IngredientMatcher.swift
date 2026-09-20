import Foundation

/// Keyword tables and matching for the ingredient-based diet rules: gluten,
/// each FDA allergen, phosphate additives, and the caregiver's free-text avoid
/// list (PRD-food-label § 10a/10d).
///
/// Matching is case- and diacritic-insensitive and works on whole words with
/// plural tolerance ("almonds" matches "almond"), so "eggplant" does not read
/// as egg and "coconut" does not read as a tree nut. The avoid list is the
/// one exception — the PRD specifies a plain substring match there, since the
/// caregiver typed the exact word they want caught.
///
/// Pure functions, no UIKit, no networking — unit-tested directly.
enum IngredientMatcher {
    /// A keyword hit: which word matched and where it was found.
    struct Match: Equatable {
        let keyword: String
        /// The ingredient (or statement) text the keyword was found in.
        let source: String
    }

    // MARK: - Tables

    /// Gluten-containing grains and derivatives (PRD table). A "gluten-free"
    /// claim on the package overrides — see `hasGlutenFreeClaim`.
    static let glutenKeywords: [String] = [
        "wheat", "barley", "rye", "malt", "malted", "spelt", "semolina", "durum", "farro",
        "triticale", "brewer's yeast", "brewers yeast", "bulgur", "couscous", "seitan",
        "farina", "graham", "einkorn", "kamut",
    ]

    /// Phosphate additives — flagged for a low-potassium (kidney) diet.
    static let phosphateKeywords: [String] = [
        "phosphate", "phosphates", "phosphoric acid", "pyrophosphate", "polyphosphate",
        "hexametaphosphate", "tripolyphosphate",
    ]

    /// Ingredient names that mean each allergen, including the hidden ones a
    /// wearer wouldn't recognize ("whey" is milk, "albumin" is egg).
    static func keywords(for allergen: Allergen) -> [String] {
        switch allergen {
        // Deliberately not listed: "cream" (cream of tartar, coconut cream),
        // "butter" (peanut butter, cocoa butter), "dairy" ("non-dairy"), "curd"
        // (bean curd) — real dairy is declared in "Contains:" anyway.
        case .milk:
            return ["milk", "milkfat", "whey", "casein", "caseinate", "caseinates", "lactose", "buttermilk",
                    "cheese", "yogurt", "yoghurt", "ghee", "lactalbumin", "lactoglobulin", "half and half",
                    "heavy cream", "sour cream", "cream cheese", "skim milk", "milk powder"]
        case .eggs:
            return ["egg", "eggs", "albumin", "albumen", "ovalbumin", "mayonnaise", "meringue",
                    "lysozyme", "egg white", "egg yolk"]
        case .fish:
            return ["fish", "anchovy", "anchovies", "cod", "salmon", "tuna", "tilapia", "haddock",
                    "pollock", "bass", "trout", "sardine", "sardines", "halibut", "mahi mahi",
                    "fish sauce", "worcestershire"]
        case .shellfish:
            return ["shellfish", "shrimp", "prawn", "prawns", "crab", "lobster", "crawfish", "crayfish",
                    "clam", "clams", "mussel", "mussels", "oyster", "oysters", "scallop", "scallops",
                    "squid", "calamari", "krill"]
        case .treeNuts:
            // Not "chestnut" (water chestnut) and not "coconut" — neither is a
            // tree nut in the sense an allergic wearer means.
            return ["tree nut", "tree nuts", "almond", "walnut", "cashew", "pecan", "pistachio",
                    "hazelnut", "filbert", "macadamia", "brazil nut", "pine nut",
                    "praline", "marzipan", "nut butter", "mixed nuts"]
        case .peanuts:
            return ["peanut", "peanuts", "arachis", "groundnut", "groundnuts", "peanut butter",
                    "peanut oil"]
        case .wheat:
            return ["wheat", "semolina", "durum", "spelt", "farro", "bulgur", "couscous", "seitan",
                    "farina", "graham", "einkorn", "kamut", "triticale", "wheat flour", "enriched flour",
                    "bread crumbs"]
        case .soybeans:
            return ["soy", "soya", "soybean", "soybeans", "tofu", "edamame", "miso", "tempeh", "shoyu",
                    "tamari", "soy lecithin", "soy protein", "textured vegetable protein"]
        case .sesame:
            return ["sesame", "tahini", "benne", "sesamol", "gingelly"]
        }
    }

    // MARK: - Normalization

    /// Lowercase, diacritics folded, anything that isn't a letter or digit
    /// becomes a space, whitespace collapsed. "Crème Fraîche," → "creme fraiche".
    static func normalize(_ text: String) -> String {
        let folded = text.folding(options: [.diacriticInsensitive, .caseInsensitive], locale: nil)
        return folded
            .map { $0.isLetter || $0.isNumber ? $0 : " " }
            .reduce(into: "") { $0.append($1) }
            .split(separator: " ")
            .joined(separator: " ")
    }

    static func tokens(_ text: String) -> [String] {
        normalize(text).split(separator: " ").map(String.init)
    }

    // MARK: - Keyword matching

    /// Whole-word match of `keyword` (one or more words) inside `text`, with
    /// simple plural tolerance on the last word.
    static func contains(keyword: String, in text: String) -> Bool {
        let needle = tokens(keyword)
        guard !needle.isEmpty else { return false }
        let haystack = tokens(text)
        guard haystack.count >= needle.count else { return false }

        for start in 0...(haystack.count - needle.count) {
            var matched = true
            for offset in 0..<needle.count where !wordMatches(haystack[start + offset], needle[offset]) {
                matched = false
                break
            }
            if matched { return true }
        }
        return false
    }

    private static func wordMatches(_ word: String, _ keyword: String) -> Bool {
        if word == keyword { return true }
        // Plurals: almond/almonds, peach/peaches. Never the other way round —
        // "bass" must not match "bas".
        if word == keyword + "s" || word == keyword + "es" { return true }
        if keyword.hasSuffix("y"), word == String(keyword.dropLast()) + "ies" { return true }
        return false
    }

    /// First keyword found in any of `texts`, or nil.
    static func firstMatch(of keywords: [String], in texts: [String]) -> Match? {
        for text in texts {
            for keyword in keywords where contains(keyword: keyword, in: text) {
                return Match(keyword: keyword, source: text)
            }
        }
        return nil
    }

    /// Case/diacritic-insensitive substring search — the avoid-list rule.
    static func containsSubstring(_ needle: String, in texts: [String]) -> Match? {
        let n = normalize(needle)
        guard !n.isEmpty else { return nil }
        for text in texts where normalize(text).contains(n) {
            return Match(keyword: needle, source: text)
        }
        return nil
    }

    // MARK: - "May contain" handling

    /// Some extractions fold "may contain peanuts" into the ingredients list.
    /// Those entries are advisory, not composition — split them out so an
    /// allergen there reads as *moderate* (may contain) rather than *high*.
    static func splitAdvisories(_ ingredients: [String]) -> (ingredients: [String], advisories: [String]) {
        var plain: [String] = []
        var advisories: [String] = []
        for entry in ingredients {
            if isAdvisory(entry) { advisories.append(entry) } else { plain.append(entry) }
        }
        return (plain, advisories)
    }

    static func isAdvisory(_ entry: String) -> Bool {
        let n = normalize(entry)
        return n.hasPrefix("may contain") || n.hasPrefix("may also contain")
            || n.hasPrefix("manufactured in a facility") || n.hasPrefix("processed in a facility")
            || n.hasPrefix("made on shared equipment") || n.hasPrefix("produced in a facility")
            || n.hasPrefix("made in a facility")
    }

    /// A "Contains:" statement with its lead-in stripped ("Contains: wheat,
    /// milk, soy" → "wheat, milk, soy"), or nil when it's blank.
    static func stripContainsLeadIn(_ statement: String?) -> String? {
        guard let statement else { return nil }
        var text = statement.trimmingCharacters(in: .whitespacesAndNewlines)
        let range = NSRange(text.startIndex..., in: text)
        if let regex = try? NSRegularExpression(pattern: "^\\s*contains\\s*:?\\s*", options: [.caseInsensitive]) {
            text = regex.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: "")
        }
        text = text.trimmingCharacters(in: .whitespacesAndNewlines)
        while text.hasSuffix(".") { text.removeLast() }
        return text.isEmpty ? nil : text
    }

    // MARK: - Rule helpers

    /// "gluten-free" / "gluten free" / "certified gluten-free" anywhere in the
    /// package claims.
    static func hasGlutenFreeClaim(_ claims: [String]) -> Bool {
        claims.contains { normalize($0).contains("gluten free") }
    }

    /// The first gluten keyword in the ingredients, or nil.
    static func glutenMatch(in ingredients: [String]) -> Match? {
        firstMatch(of: glutenKeywords, in: splitAdvisories(ingredients).ingredients)
    }

    /// The first gluten keyword anywhere the label declares composition: the
    /// "Contains:" statement (which names wheat even when the ingredient list
    /// says only "enriched flour", or wasn't legible at all) and then the
    /// ingredients themselves.
    static func glutenMatch(in label: FoodLabelResult) -> Match? {
        if let statement = stripContainsLeadIn(label.containsStatement),
           let match = firstMatch(of: glutenKeywords, in: [statement]) {
            return match
        }
        return glutenMatch(in: label.ingredients)
    }

    /// The first phosphate additive in the ingredients, or nil.
    static func phosphateMatch(in ingredients: [String]) -> Match? {
        firstMatch(of: phosphateKeywords, in: splitAdvisories(ingredients).ingredients)
    }

    enum AllergenPresence: Equatable {
        /// In the "Contains:" statement or the ingredient list itself.
        case contains(Match)
        /// Only in a "may contain" advisory.
        case mayContain(Match)
    }

    /// Where an allergen shows up on this label, if anywhere. The "Contains:"
    /// statement is checked first — it's the manufacturer's own summary — then
    /// the ingredient keywords, then the may-contain advisory.
    static func presence(of allergen: Allergen, in label: FoodLabelResult) -> AllergenPresence? {
        let keywords = keywords(for: allergen)
        if let statement = stripContainsLeadIn(label.containsStatement),
           let match = firstMatch(of: keywords, in: [statement]) {
            return .contains(match)
        }
        let split = splitAdvisories(label.ingredients)
        if let match = firstMatch(of: keywords, in: split.ingredients) {
            return .contains(match)
        }
        var advisories = split.advisories
        if let may = label.mayContainStatement { advisories.append(may) }
        if let match = firstMatch(of: keywords, in: advisories) {
            return .mayContain(match)
        }
        return nil
    }

    /// The avoid-list rule: substring match on ingredients and product name.
    static func avoidMatch(_ word: String, in label: FoodLabelResult) -> Match? {
        var texts = splitAdvisories(label.ingredients).ingredients
        if let name = label.productName { texts.append(name) }
        if let statement = stripContainsLeadIn(label.containsStatement) { texts.append(statement) }
        return containsSubstring(word, in: texts)
    }
}
