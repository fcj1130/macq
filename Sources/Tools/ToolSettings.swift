import Foundation
import os

/// 单个工具的配置域。
///
/// - **命名空间**：键统一是 `<工具名>.<键>`，工具之间不会撞车；要清空也只需清一片
/// - **默认值**：读取处一律给兜底值，缺键读成兜底值而不是 `false` / `0`
/// - **版本与迁移**：`<工具名>.schema` 记录写入时的配置版本。
///   改动配置结构（键名、单位、拆分合并）时把工具里的 `schema` +1 并在迁移表里补一步，
///   老用户启动时自动升级。
///   单纯**新增**配置项不用迁移（读取时兜底即可），**删除**配置项也不用（旧键静默忽略）。
/// - **卸载清理**：`removeAll()` 清掉整个命名空间，工具下架后不留垃圾键。
@MainActor
struct ToolSettings {
    /// 命名空间，一般就是工具 id（如 `magicMouse`）
    let tool: String
    /// 当前配置版本
    let schema: Int
    private let defaults: UserDefaults
    private let logger = Logger(subsystem: "com.mymy.macq", category: "config")

    init(tool: String, schema: Int = 1, defaults: UserDefaults = .standard) {
        self.tool = tool
        self.schema = schema
        self.defaults = defaults
    }

    private func key(_ name: String) -> String { "\(tool).\(name)" }
    private var schemaKey: String { "\(tool).schema" }

    // MARK: - 读（缺键 → 兜底值）

    func bool(_ name: String, _ fallback: Bool) -> Bool {
        defaults.object(forKey: key(name)) as? Bool ?? fallback
    }

    func int(_ name: String, _ fallback: Int) -> Int {
        defaults.object(forKey: key(name)) as? Int ?? fallback
    }

    func double(_ name: String, _ fallback: Double) -> Double {
        defaults.object(forKey: key(name)) as? Double ?? fallback
    }

    /// 以 `rawValue` 存储的枚举等配置
    func raw<T: RawRepresentable>(_ name: String, _ fallback: T) -> T where T.RawValue == String {
        defaults.string(forKey: key(name)).flatMap(T.init(rawValue:)) ?? fallback
    }

    func string(_ name: String, _ fallback: String) -> String {
        defaults.string(forKey: key(name)) ?? fallback
    }

    func stringArray(_ name: String) -> [String]? {
        defaults.stringArray(forKey: key(name))
    }

    func data(_ name: String) -> Data? { defaults.data(forKey: key(name)) }

    // MARK: - 写

    func set(_ value: Any?, _ name: String) { defaults.set(value, forKey: key(name)) }

    // MARK: - 版本与迁移

    /// 逐级补迁移：存量 v1、当前 v3 → 依次跑 `steps[2]`、`steps[3]`，最后盖上当前版本号。
    ///
    /// 注意：迁移步骤只应改动**确定已存在**的键（缺键会被写成无意义的值）。
    /// 存量版本比当前更高（用户装过新版本又降级）时不动配置，交给读取处兜底。
    func migrate(_ steps: [Int: (ToolSettings) -> Void] = [:]) {
        let stored = defaults.object(forKey: schemaKey) as? Int ?? 0
        guard stored < schema else { return }
        for version in (stored + 1)...schema { steps[version]?(self) }
        defaults.set(schema, forKey: schemaKey)
        if stored > 0, steps.isEmpty == false {
            logger.info("配置迁移 \(self.tool, privacy: .public)：v\(stored) → v\(self.schema)")
        }
    }

    /// 清掉这个工具的全部配置（工具下架时用）
    func removeAll() {
        let prefix = "\(tool)."
        for key in defaults.dictionaryRepresentation().keys where key.hasPrefix(prefix) {
            defaults.removeObject(forKey: key)
        }
    }
}
