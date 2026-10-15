import AppKit
import CryptoKit
import OSLog
import UniformTypeIdentifiers

/// 剪贴板监听：轮询 `NSPasteboard.changeCount`，把新内容分类落盘，并提供复用（写回）。
@MainActor
final class ClipboardMonitor {
    private static let pollInterval: TimeInterval = 0.25

    /// 密码管理器等会打这些标记，不该被记录
    private static let secretTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType("org.nspasteboard.ConcealedType"),
        NSPasteboard.PasteboardType("org.nspasteboard.TransientType"),
        NSPasteboard.PasteboardType("com.agilebits.onepassword"),
    ]

    private static let videoTypes: [NSPasteboard.PasteboardType] = [
        NSPasteboard.PasteboardType(UTType.movie.identifier),
        NSPasteboard.PasteboardType(UTType.mpeg4Movie.identifier),
        NSPasteboard.PasteboardType(UTType.quickTimeMovie.identifier),
    ]

    private let store: ClipboardStore
    private let logger = Logger(subsystem: "com.mymy.macq", category: "clipboard")
    private var timer: Timer?
    private var lastChangeCount = 0

    /// 一次采集的产物：要么直接入库（文件引用类、无需落盘），
    /// 要么带上载荷数据去后台算哈希 + 落盘（文本/图片/视频，大内容不能卡主线程）
    private enum Capture {
        case ready(ClipItem)
        case payload(ClipItem, data: Data, ext: String)
    }

    /// 记录时的上限配置（由工具实例提供）
    var limits: () -> (maxBytes: Int, retention: ClipRetention) = { (MagicClipboard.defaultMaxBytes, .forever) }

    init(store: ClipboardStore) {
        self.store = store
    }

    var isRunning: Bool { timer != nil }

    func start() {
        guard timer == nil else { return }
        lastChangeCount = 0   // 开启时把当前剪贴板里的内容也收进来
        poll()
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [self] _ in
            MainActor.assumeIsolated { self.poll() }
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
    }

    // MARK: - 采集

    private func poll() {
        let pasteboard = NSPasteboard.general
        guard pasteboard.changeCount != lastChangeCount else { return }
        lastChangeCount = pasteboard.changeCount
        guard let capture = capture(from: pasteboard) else { return }
        switch capture {
        case .ready(let item):
            commit(item)
        case .payload(let item, let data, let ext):
            stash(item, data: data, ext: ext, root: store.root)
        }
    }

    private func commit(_ item: ClipItem) {
        let limits = limits()
        store.insert(item, maxBytes: limits.maxBytes, retention: limits.retention)
        logger.info("记录剪贴板 \(item.kind.rawValue) \(item.size) 字节")
    }

    /// 哈希与落盘放后台：粘贴板里可能有几百 MB 的图，SHA256 + 写盘在主线程会明显卡顿。
    /// 顺序不受影响——`usedAt` 在采集时就定了，入库后依然按它排序。
    private nonisolated func stash(_ item: ClipItem, data: Data, ext: String, root: URL) {
        let logger = self.logger
        // 强引用自己：任务几毫秒就结束，且监控器与工具同生命周期，弱引用只会惹来并发捕获的告警
        Task.detached(priority: .utility) {
            let name = "\(item.id.uuidString).\(ext)"
            do {
                try data.write(to: root.appendingPathComponent(name))
            } catch {
                logger.error("写入载荷失败：\(error.localizedDescription)")
                return
            }
            // 先做成不可变副本再跨过去：并发闭包不能捕获 var
            let finished = item.updating(payload: name, fingerprint: Self.digest(data))
            await MainActor.run { self.commit(finished) }
        }
    }

    private func capture(from pasteboard: NSPasteboard) -> Capture? {
        let types = pasteboard.types ?? []
        if Self.secretTypes.contains(where: types.contains) { return nil }
        let maxBytes = limits().maxBytes

        // 1) 文件（含视频/图片文件）
        // ponytail: 只记录引用、不复制内容——把用户媒体悄悄拷进缓存能吃掉几 GB；
        // 占用上限只对落盘载荷（文本/图片/视频数据）生效。
        if let urls = fileURLs(from: pasteboard) {
            return .ready(fileItem(urls))
        }
        // 2) 图片数据
        if let (data, type) = firstData(in: pasteboard, types: [.png, .tiff]) {
            return dataItem(data, type: type, kind: .image, maxBytes: maxBytes)
        }
        // 3) 视频数据
        if let (data, type) = firstData(in: pasteboard, types: Self.videoTypes) {
            return dataItem(data, type: type, kind: .video, maxBytes: maxBytes)
        }
        // 4) 文本
        if let string = pasteboard.string(forType: .string), !string.isEmpty {
            return textItem(string, maxBytes: maxBytes)
        }
        return nil
    }

    private func fileURLs(from pasteboard: NSPasteboard) -> [URL]? {
        let options: [NSPasteboard.ReadingOptionKey: Any] = [.urlReadingFileURLsOnly: true]
        guard let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: options) as? [URL],
              !urls.isEmpty
        else { return nil }
        return urls
    }

    private func fileItem(_ urls: [URL]) -> ClipItem {
        let kinds = urls.map(Self.kind(of:))
        let kind: ClipKind = Set(kinds).count == 1 ? (kinds.first ?? .file) : .file
        let names = urls.map(\.lastPathComponent)
        let sizes = urls.map(Self.fileSize)
        let preview = names.count == 1 ? names[0] : String(format: AppLanguage.localized("%@ 等 %d 个文件"), names[0], names.count)

        return ClipItem(
            id: UUID(),
            kind: kind,
            usedAt: Date(),
            size: sizes.reduce(0, +),
            characters: 0,
            preview: preview,
            searchText: String(names.joined(separator: " ").prefix(ClipboardStore.searchTextLimit)),
            payload: nil,
            paths: urls.map(\.path),
            pasteboardType: nil,
            fingerprint: Self.digest("file:" + urls.enumerated().map { index, url in
                "\(url.path)|\(sizes[index])|\(Self.modificationStamp(url))"
            }.joined(separator: "|"))
        )
    }

    private func dataItem(_ data: Data, type: NSPasteboard.PasteboardType, kind: ClipKind, maxBytes: Int) -> Capture? {
        guard data.count <= maxBytes else {
            logger.info("跳过单条超过占用上限的内容：\(data.count) > \(maxBytes)")
            return nil
        }
        let id = UUID()
        let ext = UTType(type.rawValue)?.preferredFilenameExtension ?? "bin"
        let preview: String
        if kind == .image, let size = Self.pixelSize(of: data) {
            preview = "\(Int(size.width)) × \(Int(size.height))"
        } else {
            preview = "\(kind.title)（\(ext)）"
        }

        let item = ClipItem(
            id: id,
            kind: kind,
            usedAt: Date(),
            size: data.count,
            characters: 0,
            preview: preview,
            searchText: preview,
            payload: nil,
            paths: [],
            pasteboardType: type.rawValue,
            fingerprint: ""
        )
        return .payload(item, data: data, ext: ext)
    }

    private func textItem(_ string: String, maxBytes: Int) -> Capture? {
        let data = Data(string.utf8)
        guard data.count <= maxBytes else {
            logger.info("跳过单条超过占用上限的文本：\(data.count) > \(maxBytes)")
            return nil
        }
        let flattened = string
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\t", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let preview = flattened.count > ClipboardStore.previewLimit
            ? String(flattened.prefix(ClipboardStore.previewLimit)) + "…"
            : flattened

        let item = ClipItem(
            id: UUID(),
            kind: .text,
            usedAt: Date(),
            size: data.count,
            characters: string.count,
            preview: preview,
            searchText: String(string.prefix(ClipboardStore.searchTextLimit)),
            payload: nil,
            paths: [],
            pasteboardType: NSPasteboard.PasteboardType.string.rawValue,
            fingerprint: ""
        )
        return .payload(item, data: data, ext: "txt")
    }

    private func firstData(in pasteboard: NSPasteboard, types: [NSPasteboard.PasteboardType]) -> (Data, NSPasteboard.PasteboardType)? {
        for type in types {
            if let data = pasteboard.data(forType: type), !data.isEmpty { return (data, type) }
        }
        return nil
    }

    // MARK: - 复用

    /// 写回剪贴板并刷新时间为最新
    @discardableResult
    func reuse(_ item: ClipItem) -> Bool {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        var written = false

        if let url = store.payloadURL(item), let data = try? Data(contentsOf: url) {
            switch item.kind {
            case .text:
                pasteboard.setString(String(decoding: data, as: UTF8.self), forType: .string)
            default:
                let type = NSPasteboard.PasteboardType(item.pasteboardType ?? UTType.data.identifier)
                pasteboard.setData(data, forType: type)
            }
            written = true
        } else if !item.paths.isEmpty {
            let urls = item.paths
                .map { URL(fileURLWithPath: $0) }
                .filter { FileManager.default.fileExists(atPath: $0.path) }
            if !urls.isEmpty {
                pasteboard.writeObjects(urls.map { $0 as NSURL })
                written = true
            }
        }

        guard written else {
            logger.error("复用失败：载荷已丢失 \(item.id.uuidString)")
            return false
        }
        lastChangeCount = pasteboard.changeCount   // 别把自己这次写入当成新复制
        store.touch(item)
        return true
    }

    // MARK: - 工具方法

    private static func kind(of url: URL) -> ClipKind {
        guard let type = UTType(filenameExtension: url.pathExtension.lowercased()) else { return .file }
        if type.conforms(to: .movie) || type.conforms(to: .video) { return .video }
        if type.conforms(to: .image) { return .image }
        return .file
    }

    private static func fileSize(_ url: URL) -> Int {
        (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
    }

    private static func modificationStamp(_ url: URL) -> Int {
        let date = (try? url.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? .distantPast
        return Int(date.timeIntervalSince1970)
    }

    private static func pixelSize(of data: Data) -> CGSize? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
              let width = properties[kCGImagePropertyPixelWidth] as? Int,
              let height = properties[kCGImagePropertyPixelHeight] as? Int
        else { return nil }
        return CGSize(width: width, height: height)
    }

    nonisolated private static func digest(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    private static func digest(_ string: String) -> String {
        digest(Data(string.utf8))
    }
}
