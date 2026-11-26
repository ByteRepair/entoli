import Foundation
internal import MLX

/// What MLX may take of this process.
///
/// MLX sizes itself from Metal's working set: on a 12 GB iPhone it keeps the
/// buffers it frees until it holds about 7.6 GB. iOS ends the app at its own
/// per-process limit, 6.0 GiB on that phone by its JetsamEvent report, and
/// gives nobody an error to catch. So on iOS the cache is kept small, MLX's
/// soft limit comes from what the OS says is left, and a reply stops itself
/// short of the OS's limit. A Mac runs the models in a process of its own,
/// with no such limit, and keeps MLX's defaults.
enum MlxMemory {
  /// MLX's buffer cache while a model is loaded. A buffer kept there is
  /// resident memory the OS's limit counts.
  static let cacheLimit: Int = {
    #if os(iOS)
    return 64 << 20
    #else
    return Memory.cacheLimit
    #endif
  }()

  /// Kept clear of the OS's limit for the rest of the app, and for the one
  /// prefill chunk that may run between two checks: a 4B's is a few hundred
  /// megabytes.
  private static let reserve = 768 << 20

  /// MLX's own soft limit, read before `fit` first changes it.
  private static let ownLimit = Memory.memoryLimit

  /// Before each call on a model: MLX's soft limit, past which an evaluation
  /// waits for the work in flight to free its buffers, set to what MLX holds
  /// now and what the OS still allows, less the reserve. Asked each time,
  /// since what is left moves with every model loaded beside this one.
  static func fit() {
    #if os(iOS)
    let headroom = Int(os_proc_available_memory())
    Memory.memoryLimit = min(ownLimit, Memory.activeMemory + max(headroom - reserve, 0))
    #endif
  }

  /// With no model left, MLX's limit is its own again, so the next load is
  /// not held to one sized for the model before it.
  static func reset() {
    Memory.memoryLimit = ownLimit
  }

  /// Refuses a load whose weights would not fit in what the OS still allows,
  /// with the reserve kept. The weights are read on a dispatch queue, out of
  /// reach of the checks a reply makes, so a load that ran out partway would
  /// end the app rather than fail.
  ///
  /// With `nothingLoaded`, whatever MLX still holds is on its way out: an
  /// evicted model's weights are let go of a moment after its unload returns
  /// (see `MlxModels.evict`), and the OS still counts them.
  static func checkFits(_ directory: String, nothingLoaded: Bool) throws {
    #if os(iOS)
    let files = (try? FileManager.default.contentsOfDirectory(atPath: directory)) ?? []
    let weights = files.filter { $0.hasSuffix(".safetensors") }.reduce(0) { sum, name in
      let path = (directory as NSString).appendingPathComponent(name)
      let size = (try? FileManager.default.attributesOfItem(atPath: path)[.size] as? Int) ?? 0
      return sum + size
    }
    let reclaimable = nothingLoaded ? Memory.activeMemory + Memory.cacheMemory : 0
    let headroom = Int(os_proc_available_memory()) + reclaimable
    if weights + reserve > headroom {
      let gb = { (bytes: Int) in String(format: "%.1f GB", Double(bytes) / 1e9) }
      throw MlxFailure(
        code: "resources",
        description: "This model needs \(gb(weights + reserve)), and the app has \(gb(headroom)) left.")
    }
    #endif
  }

  /// Close enough to the OS's limit that the next step could be the one it
  /// ends the app for. MLX's soft limit only slows it down, so this is what
  /// stops it.
  static var isShort: Bool {
    #if os(iOS)
    return Int(os_proc_available_memory()) < reserve / 2
    #else
    return false
    #endif
  }
}
