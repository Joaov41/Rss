import MLX

public enum Memory {
    public static var activeMemory: Int {
        GPU.activeMemory
    }

    public static var cacheMemory: Int {
        GPU.cacheMemory
    }

    public static var peakMemory: Int {
        GPU.peakMemory
    }

    public static var cacheLimit: Int {
        get {
            GPU.cacheLimit
        }
        set {
            GPU.set(cacheLimit: newValue)
        }
    }

    public static func clearCache() {
        GPU.clearCache()
    }

    public static func snapshot() -> GPU.Snapshot {
        GPU.snapshot()
    }
}
