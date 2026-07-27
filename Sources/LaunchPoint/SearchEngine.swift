import Foundation

/// 搜索匹配引擎:按显示名/默认名/别名三路匹配,
/// 支持前缀、词首、单词首字母、缩写、驼峰、包含、拼音全拼与拼音首字母,并按匹配度排序。
/// 纯 Foundation 实现,可脱离 UI 独立测试。
enum SearchEngine {

    // MARK: - 预计算的检索键

    struct Keys {
        let full: String            // 完整小写文本
        let words: [String]         // 小写单词切分(供词首匹配)
        let wordInitials: String    // 单词/驼峰/数字边界首字母,如 "4K Video Downloader" → "4kvd"
        let pinyinFulls: [String]   // 拼音全拼变体,如 "网易云音乐" → ["wangyiyunyinle", "wangyiyunyinyue"]
        let pinyinInitials: [String]// 拼音首字母变体(非汉字段整段保留),如 "QQ音乐" → ["qqyl", "qqyy"]
    }

    /// 键缓存:同一文本只算一次拼音(CFStringTransform 有开销)。
    /// 仅主线程访问(SwiftUI body / onSubmit / 预热均在主线程)。
    private static var cache: [String: Keys] = [:]
    /// 查询缓存:同一批应用和查询不重复打分排序。
    private static var rankCache: [String: [AppItem]] = [:]

    static func keys(for text: String) -> Keys {
        if let hit = cache[text] { return hit }

        var pinyinFulls: [String] = []
        var pinyinInitials: [String] = []
        if let units = pinyinUnits(of: text) {
            let fullSeqs = boundedVariants(units.map(\.readings), cap: 16)
            pinyinFulls = Array(Set(fullSeqs.map { $0.joined() }))
            // 首字母序列:汉字取每个读音的首字母;非汉字单词整段保留(qq+y+y → "qqyy")
            let initialOptions = units.map { unit in
                unit.isHan ? unit.readings.map { $0.first.map(String.init) ?? "" }
                           : unit.readings
            }
            let initialSeqs = boundedVariants(initialOptions, cap: 16)
            pinyinInitials = Array(Set(initialSeqs.map { $0.joined() }))
        }

        let keys = Keys(full: text.lowercased(),
                        words: words(of: text),
                        wordInitials: wordInitials(of: text),
                        pinyinFulls: pinyinFulls,
                        pinyinInitials: pinyinInitials)
        cache[text] = keys
        return keys
    }

    /// 预热:启动后为所有条目提前建键,把 ICU 转换器首次初始化(约 40ms)挪出打字路径。
    static func prewarm(_ items: [AppItem]) {
        for item in items {
            _ = keys(for: item.name)
            if let alias = item.alias, !alias.isEmpty { _ = keys(for: alias) }
        }
    }

    // MARK: - 文本切分

    /// 小写单词切分:按非字母数字分隔。
    private static func words(of text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    /// 单词首字母:空格/标点、驼峰边界、字母↔数字切换处都算词首。
    /// "Visual Studio Code" → "vsc"、"OneSync" → "os"、"4K Video Downloader" → "4kvd"、"1Password" → "1p"
    private static func wordInitials(of text: String) -> String {
        var initials = ""
        var previous: Character? = nil
        for ch in text {
            guard ch.isLetter || ch.isNumber else {
                previous = nil  // 分隔符 → 下一个字符是词首
                continue
            }
            let isBoundary: Bool
            if let p = previous {
                isBoundary = (ch.isUppercase && p.isLowercase)   // 驼峰:小写后遇大写
                    || (ch.isNumber != p.isNumber)               // 字母↔数字切换
            } else {
                isBoundary = true
            }
            if isBoundary {
                initials.append(Character(ch.lowercased()))
            }
            previous = ch
        }
        return initials
    }

    // MARK: - 拼音

    /// 常见多音字补充表:逐字符 CFStringTransform 只给单字默认读音,这里补上应用名里高频的另一读音。
    /// 注意表值必须是"默认读音之外"的那个:实测单字默认为 乐→le、行→xing、重→zhong、长→zhang。
    private static let polyphoneAlternates: [Character: [String]] = [
        "乐": ["yue"], "行": ["hang"], "重": ["chong"], "长": ["chang"],
        "调": ["tiao"], "会": ["kuai"], "便": ["pian"], "传": ["zhuan"],
        "藏": ["zang"], "厦": ["xia"], "卡": ["qia"], "省": ["xing"],
        "还": ["huan"], "降": ["xiang"], "率": ["shuai"],
    ]

    /// 拼音单元:一个汉字(可多读音)或一个非汉字单词(原样)。
    private struct PinyinUnit {
        let readings: [String]
        let isHan: Bool
    }

    /// 中文 → 拼音单元序列。无中文返回 nil。
    /// 每个汉字取系统默认读音 + 补充表读音;含 ü 的读音追加 v 写法(lü → lu 与 lv)。
    private static func pinyinUnits(of text: String) -> [PinyinUnit]? {
        guard text.range(of: "\\p{Han}", options: .regularExpression) != nil else { return nil }

        var units: [PinyinUnit] = []
        var nonHanBuffer = ""
        func flushNonHan() {
            for word in words(of: nonHanBuffer) {
                units.append(PinyinUnit(readings: [word], isHan: false))
            }
            nonHanBuffer = ""
        }

        for ch in text {
            if String(ch).range(of: "\\p{Han}", options: .regularExpression) != nil {
                flushNonHan()
                // 先取带声调的转写,以便识别 ü;再剥离声调得到基础读音
                let toneful = NSMutableString(string: String(ch))
                CFStringTransform(toneful, nil, kCFStringTransformMandarinLatin, false)
                let stripped = NSMutableString(string: toneful as String)
                CFStringTransform(stripped, nil, kCFStringTransformStripDiacritics, false)
                let base = (stripped as String).lowercased()
                    .trimmingCharacters(in: .whitespaces)

                var readings = [base]
                // ü 的拼音输入法习惯写作 v:绿 lǜ → lu 之外补 lv
                if (toneful as String).rangeOfCharacter(from: CharacterSet(charactersIn: "üǖǘǚǜ")) != nil {
                    let vForm = base.replacingOccurrences(of: "u", with: "v")
                    if !readings.contains(vForm) { readings.append(vForm) }
                }
                for alt in polyphoneAlternates[ch] ?? [] where !readings.contains(alt) {
                    readings.append(alt)
                }
                units.append(PinyinUnit(readings: readings, isHan: true))
            } else {
                nonHanBuffer.append(ch)
            }
        }
        flushNonHan()
        return units
    }

    /// 生成读音组合变体,封顶 cap 个。
    /// 组合数不超上限时做完整笛卡尔积;超限时退化为:
    /// 默认序列 + 每个位置单独替换 + 全备选序列 —— 保证每个读音至少出现在一个变体中,
    /// 避免纯字典序截断把"第一个多音字的备选读音"整体丢掉。
    private static func boundedVariants(_ options: [[String]], cap: Int) -> [[String]] {
        guard !options.isEmpty else { return [] }

        var product = 1
        for opts in options {
            product *= max(opts.count, 1)
            if product > cap { break }
        }

        if product <= cap {
            var result: [[String]] = [[]]
            for opts in options {
                var next: [[String]] = []
                for sequence in result {
                    for option in opts {
                        next.append(sequence + [option])
                    }
                }
                result = next
            }
            return result
        }

        // 超限退化:线性覆盖每个读音
        let base = options.map { $0[0] }
        var result: [[String]] = [base]
        for (index, opts) in options.enumerated() {
            for alt in opts.dropFirst() {
                var variant = base
                variant[index] = alt
                result.append(variant)
            }
        }
        let allAlternate = options.map { $0.count > 1 ? $0[1] : $0[0] }
        if !result.contains(allAlternate) { result.append(allAlternate) }
        return result
    }

    // MARK: - 打分

    /// 单个文本对查询的匹配分。0 = 不匹配;分越高越靠前。查询应已去除首尾空白。
    static func score(_ text: String, query: String) -> Int {
        let q = query.lowercased().trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return 0 }
        let k = keys(for: text)

        if k.full == q { return 1000 }                              // 完全相等
        if k.full.hasPrefix(q) { return 900 }                       // 前缀
        if k.words.contains(where: { $0.hasPrefix(q) }) {
            return 850                                              // 词首("word" → Microsoft Word)
        }
        if k.wordInitials.hasPrefix(q) { return 800 }               // 单词/驼峰/数字边界首字母缩写
        if k.pinyinInitials.contains(where: { $0.hasPrefix(q) }) {
            return 700                                              // 拼音首字母
        }
        if k.pinyinFulls.contains(where: { $0.hasPrefix(q) }) {
            return 600                                              // 拼音全拼前缀
        }
        if k.full.contains(q) { return 500 }                        // 包含
        if k.pinyinFulls.contains(where: { $0.contains(q) }) {
            return 400                                              // 拼音全拼包含
        }
        if k.pinyinInitials.contains(where: { $0.contains(q) }) {
            return 300                                              // 拼音首字母包含
        }
        return 0
    }

    // MARK: - 排序检索

    /// 对应用列表执行三路匹配(显示名/默认名/别名),按分数降序、同分按名短优先。
    /// 查询会先去除首尾空白;去除后为空则原样返回全部应用。
    static func rank(_ query: String, in apps: [AppItem]) -> [AppItem] {
        let q = query.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return apps }
        var hasher = Hasher()
        hasher.combine(apps.count)
        for app in apps {
            hasher.combine(app.id)
            hasher.combine(app.alias ?? "")
        }
        let cacheKey = "\(q.lowercased())#\(hasher.finalize())"
        if let cached = rankCache[cacheKey] { return cached }

        let result = apps
            .compactMap { app -> (AppItem, Int)? in
                var best = score(app.name, query: q)
                if let alias = app.alias, !alias.isEmpty {
                    best = max(best, score(alias, query: q))
                }
                return best > 0 ? (app, best) : nil
            }
            .sorted { a, b in
                if a.1 != b.1 { return a.1 > b.1 }
                if a.0.displayName.count != b.0.displayName.count {
                    return a.0.displayName.count < b.0.displayName.count
                }
                return a.0.displayName.localizedCaseInsensitiveCompare(b.0.displayName) == .orderedAscending
            }
            .map(\.0)
        rankCache[cacheKey] = result
        if rankCache.count > 32, let first = rankCache.keys.first {
            rankCache.removeValue(forKey: first)
        }
        return result
    }
}
