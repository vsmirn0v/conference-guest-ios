import Foundation

/// VoxCPM2's Llama-style BPE tokenizer, read from the checkpoint's tokenizer.json.
/// Matches `tokenizer.tokenize` + `convert_tokens_to_ids` of the Python runtime: the text is
/// normalized ("▁" prepended, spaces become "▁"), split into Unicode scalars (unknown ones fall
/// back to byte tokens), then merged by rank. Multi-character Chinese tokens are split into
/// characters, as upstream's `mask_multichar_chinese_tokens` does.
struct VoxTokenizer {
    private let vocab: [String: Int]
    private let tokens: [Int: String]
    private let merges: [UInt64: (rank: Int, id: Int)]
    private let chineseWords: Set<String>
    private let unknown: Int

    init(url: URL) throws {
        guard let root = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any],
              let model = root["model"] as? [String: Any], model["type"] as? String == "BPE",
              let vocab = model["vocab"] as? [String: Int] else {
            throw VoxError.format("tokenizer.json is not a BPE tokenizer")
        }
        guard model["byte_fallback"] as? Bool == true, root["pre_tokenizer"] is NSNull || root["pre_tokenizer"] == nil,
              let normalizer = root["normalizer"] as? [String: Any], normalizer["type"] as? String == "Sequence",
              let steps = normalizer["normalizers"] as? [[String: Any]], steps.count == 2,
              steps[0]["type"] as? String == "Prepend", steps[0]["prepend"] as? String == "▁",
              steps[1]["type"] as? String == "Replace", steps[1]["content"] as? String == "▁",
              (steps[1]["pattern"] as? [String: Any])?["String"] as? String == " " else {
            throw VoxError.unsupported("tokenizer layout differs from VoxCPM2")
        }
        var all = vocab
        for added in root["added_tokens"] as? [[String: Any]] ?? [] {
            if let content = added["content"] as? String, let id = added["id"] as? Int { all[content] = id }
        }
        self.vocab = all
        tokens = Dictionary(all.map { ($0.value, $0.key) }, uniquingKeysWith: { first, _ in first })
        unknown = all[model["unk_token"] as? String ?? "<unk>"] ?? 0

        var table: [UInt64: (rank: Int, id: Int)] = [:]
        let lines = model["merges"] as? [Any] ?? []
        table.reserveCapacity(lines.count)
        for (rank, line) in lines.enumerated() {
            var pair: (String, String)?
            if let parts = line as? [String], parts.count == 2 {
                pair = (parts[0], parts[1])
            } else if let text = line as? String {
                // A token may itself contain a space: take the split whose parts and join are tokens.
                var index = text.startIndex
                while let space = text[index...].firstIndex(of: " ") {
                    let left = String(text[..<space]), right = String(text[text.index(after: space)...])
                    if all[left] != nil, all[right] != nil, all[left + right] != nil { pair = (left, right); break }
                    index = text.index(after: space)
                }
            }
            guard let pair, let a = all[pair.0], let b = all[pair.1], let merged = all[pair.0 + pair.1] else {
                throw VoxError.format("tokenizer merge \(rank) is invalid")
            }
            let key = UInt64(UInt32(a)) << 32 | UInt64(UInt32(b))
            if table[key] == nil { table[key] = (rank, merged) }
        }
        merges = table
        chineseWords = Set(vocab.keys.filter { word in
            word.unicodeScalars.count >= 2 && word.unicodeScalars.allSatisfy { (0x4E00...0x9FFF).contains($0.value) }
        })
    }

    /// Token ids for `text` (no BOS), as the runtime feeds them to the model.
    func encode(_ text: String) -> [Int] {
        let normalized = "▁" + text.replacingOccurrences(of: " ", with: "▁")
        var symbols: [Int] = []
        symbols.reserveCapacity(normalized.unicodeScalars.count)
        for scalar in normalized.unicodeScalars {
            let character = String(scalar)
            if let id = vocab[character] {
                symbols.append(id)
            } else {
                let bytes = character.utf8.map { vocab[String(format: "<0x%02X>", $0)] }
                if bytes.allSatisfy({ $0 != nil }) { symbols += bytes.map { $0! } } else { symbols.append(unknown) }
            }
        }
        while symbols.count > 1 {
            var best: (index: Int, rank: Int, id: Int)?
            for index in 0..<(symbols.count - 1) {
                let key = UInt64(UInt32(symbols[index])) << 32 | UInt64(UInt32(symbols[index + 1]))
                if let merge = merges[key], merge.rank < (best?.rank ?? .max) { best = (index, merge.rank, merge.id) }
            }
            guard let best else { break }
            symbols[best.index] = best.id
            symbols.remove(at: best.index + 1)
        }
        var ids: [Int] = []
        ids.reserveCapacity(symbols.count)
        for id in symbols {
            let word = tokens[id].map { $0.replacingOccurrences(of: "▁", with: "") } ?? ""
            if chineseWords.contains(word) {
                ids += word.unicodeScalars.map { vocab[String($0)] ?? unknown }
            } else {
                ids.append(id)
            }
        }
        return ids
    }
}
