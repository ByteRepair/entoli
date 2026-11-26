import Foundation
internal import MLX

/// What the app planned for one model (`BudgetPlan` in Dart): everything MLX
/// does for it inside `budget`, the rest of the app keeping what is left.
public struct MlxLimits: Sendable {
  /// Bytes this model may take: its weights, its state, the prefill's working
  /// memory, its share of the buffer cache and its KV cache.
  public let budget: Int
  /// What MLX may keep of the buffers it frees.
  public let cache: Int
  /// The most tokens of conversation it has room for.
  public let context: Int
  /// The prefill's chunk, short enough that its working memory fits.
  public let prefillStep: Int

  /// Nil where the app sent no plan, which leaves MLX its own defaults.
  public init?(channel map: [String: Any]) {
    guard let budget = map["budget"] as? Int, let cache = map["cache"] as? Int,
      let context = map["context"] as? Int, let prefillStep = map["prefillStep"] as? Int
    else { return nil }
    self.budget = budget
    self.cache = cache
    self.context = context
    self.prefillStep = prefillStep
  }
}

/// MLX's share of this process: the sum of the loaded models' budgets, which
/// MLX's own limits are set to and a reply is stopped at. Measured by MLX's
/// counters, never the app's free memory, so the rest of the app is not
/// what moves the line.
///
/// MLX's soft limit only makes an evaluation wait for work in flight — its
/// allocator never fails at it — so `isOver`, checked after each prefill
/// chunk and each output chunk, is what holds MLX to the budget.
final class MlxBudget: @unchecked Sendable {
  static let shared = MlxBudget()

  private let lock = NSLock()
  private var planned: [String: MlxLimits] = [:]
  private var unplanned: Set<String> = []
  private var total: Int?

  /// MLX's own, read before anything changes them.
  private let ownMemoryLimit = Memory.memoryLimit
  private let ownCacheLimit = Memory.cacheLimit

  func admit(_ id: String, _ limits: MlxLimits?) {
    lock.withLock {
      if let limits { planned[id] = limits } else { unplanned.insert(id) }
      apply()
    }
  }

  func release(_ id: String) {
    lock.withLock {
      planned.removeValue(forKey: id)
      unplanned.remove(id)
      apply()
    }
  }

  /// Whether MLX holds more than every loaded model was planned to.
  var isOver: Bool {
    guard let total = lock.withLock({ total }) else { return false }
    return Memory.activeMemory + Memory.cacheMemory > total
  }

  /// A model loaded with no plan has no budget to hold anything to, so MLX
  /// keeps its defaults while one is. With nothing loaded the cache keeps
  /// nothing: an evicted model's buffers are freed a moment after its unload
  /// returns, and are handed back as they are.
  private func apply() {
    if planned.isEmpty && unplanned.isEmpty {
      total = nil
      Memory.memoryLimit = ownMemoryLimit
      Memory.cacheLimit = 0
    } else if !unplanned.isEmpty {
      total = nil
      Memory.memoryLimit = ownMemoryLimit
      Memory.cacheLimit = ownCacheLimit
    } else {
      let sum = planned.values.reduce(0) { $0 + $1.budget }
      total = sum
      Memory.memoryLimit = sum
      Memory.cacheLimit = planned.values.reduce(0) { $0 + $1.cache }
    }
  }
}
