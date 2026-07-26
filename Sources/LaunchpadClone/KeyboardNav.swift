import Foundation

/// 键盘导航:方向键在网格间移动高亮。纯逻辑实现,可脱离 UI 独立测试。
enum KeyboardNav {
    enum Direction { case left, right, up, down }

    /// 分页模式移动(条目 = 应用或文件夹图块)。返回新高亮条目与其所在页;nil 表示保持不动。
    /// 约定(还原原生启动台):
    /// - 尚无高亮时,从当前页第一个条目开始
    /// - 左/右在页首/页尾时自动跨到相邻非空页(高亮所在页同步切换)
    /// - 上/下只在本页内移动,越界不动
    static func move(pages: [[PageEntry]], columns: Int,
                     currentID: String?, currentPage: Int,
                     direction: Direction) -> (id: String, page: Int)? {
        guard pages.contains(where: { !$0.isEmpty }) else { return nil }
        let boundedPage = min(max(currentPage, 0), pages.count - 1)

        // 尚无高亮:从当前页(或其后第一个非空页)的第一个应用开始
        guard let currentID, let (p, i) = locate(currentID, in: pages) else {
            let order = Array(pages.indices.dropFirst(boundedPage)) + Array(pages.indices.prefix(boundedPage))
            for candidate in order where !pages[candidate].isEmpty {
                return (pages[candidate][0].id, candidate)
            }
            return nil
        }

        switch direction {
        case .right:
            if i + 1 < pages[p].count { return (pages[p][i + 1].id, p) }
            // 页尾 → 下一个非空页的页首
            for np in (p + 1)..<pages.count where !pages[np].isEmpty {
                return (pages[np][0].id, np)
            }
            return nil
        case .left:
            if i > 0 { return (pages[p][i - 1].id, p) }
            // 页首 → 上一个非空页的页尾
            for np in stride(from: p - 1, through: 0, by: -1) where !pages[np].isEmpty {
                return (pages[np][pages[np].count - 1].id, np)
            }
            return nil
        case .up:
            let target = i - columns
            return target >= 0 ? (pages[p][target].id, p) : nil
        case .down:
            let target = i + columns
            return target < pages[p].count ? (pages[p][target].id, p) : nil
        }
    }

    /// 扁平模式移动(搜索结果网格)。nil 表示保持不动。
    static func move(items: [AppItem], columns: Int,
                     currentID: String?, direction: Direction) -> String? {
        guard !items.isEmpty else { return nil }
        guard let currentID,
              let i = items.firstIndex(where: { $0.id == currentID }) else {
            return items[0].id   // 尚无高亮:从第一个结果开始
        }
        switch direction {
        case .right: return i + 1 < items.count ? items[i + 1].id : nil
        case .left:  return i > 0 ? items[i - 1].id : nil
        case .up:
            let target = i - columns
            return target >= 0 ? items[target].id : nil
        case .down:
            let target = i + columns
            return target < items.count ? items[target].id : nil
        }
    }

    private static func locate(_ id: String, in pages: [[PageEntry]]) -> (Int, Int)? {
        for (p, page) in pages.enumerated() {
            if let i = page.firstIndex(where: { $0.id == id }) { return (p, i) }
        }
        return nil
    }
}
