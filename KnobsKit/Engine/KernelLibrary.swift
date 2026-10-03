import CoreImage
import Synchronization

/// The Core Image kernels compiled from every plugin's .metal file into one library.
/// Names are global across plugins, so prefix each kernel with its plugin id.
public enum KernelLibrary {
    private final class BundleToken {}

    private static let data: Data = {
        guard let url = Bundle(for: BundleToken.self).url(forResource: "default", withExtension: "metallib"),
              let data = try? Data(contentsOf: url)
        else { fatalError("KnobsKit default.metallib is missing") }
        return data
    }()

    private static let cache = Mutex<[String: CIKernel]>([:])

    public static func color(_ name: String) -> CIColorKernel {
        load(name: name) { try CIColorKernel(functionName: name, fromMetalLibraryData: data) }
    }

    public static func general(_ name: String) -> CIKernel {
        load(name: name) { try CIKernel(functionName: name, fromMetalLibraryData: data) }
    }

    public static func warp(_ name: String) -> CIWarpKernel {
        load(name: name) { try CIWarpKernel(functionName: name, fromMetalLibraryData: data) }
    }

    private static func load<Kernel: CIKernel>(name: String, make: () throws -> Kernel) -> Kernel {
        if let cached = cache.withLock({ $0[name] }) as? Kernel {
            return cached
        }
        do {
            let kernel = try make()
            cache.withLock { $0[name] = kernel }
            return kernel
        } catch {
            fatalError("Kernel \(name) failed to load: \(error)")
        }
    }
}
