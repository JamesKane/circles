import Foundation
import CirclesFuzz

/// The target named by CIRCLES_FUZZ_TARGET.
let target: @Sendable ([UInt8]) -> Void = {
    let name = ProcessInfo.processInfo.environment["CIRCLES_FUZZ_TARGET"] ?? ""
    guard let target = FuzzTargets.all[name] else {
        FileHandle.standardError.write(Data("Set CIRCLES_FUZZ_TARGET to one of: \(FuzzTargets.all.keys.sorted().joined(separator: ", "))\n".utf8))
        exit(2)
    }
    return target
}()

@_cdecl("LLVMFuzzerTestOneInput")
public func fuzz(_ data: UnsafePointer<UInt8>, _ size: Int) -> CInt {
    target(Array(UnsafeBufferPointer(start: data, count: size)))
    return 0
}

/// Before fuzzing starts: fill an empty corpus directory (CIRCLES_FUZZ_SEED_DIR)
/// with the target's seeds, valid encodings to mutate from.
@_cdecl("LLVMFuzzerInitialize")
public func initialize(_ argc: UnsafeMutablePointer<CInt>, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>) -> CInt {
    let environment = ProcessInfo.processInfo.environment
    guard let directory = environment["CIRCLES_FUZZ_SEED_DIR"], let name = environment["CIRCLES_FUZZ_TARGET"],
          (try? FileManager.default.contentsOfDirectory(atPath: directory))?.isEmpty ?? true,
          let seeds = try? FuzzTargets.seeds()[name]
    else { return 0 }
    try? FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: true)
    for (index, seed) in seeds.enumerated() {
        FileManager.default.createFile(atPath: "\(directory)/seed-\(index)", contents: Data(seed))
    }
    return 0
}

/// libFuzzer's driver, for running it from our own entry point.
@_silgen_name("LLVMFuzzerRunDriver")
func LLVMFuzzerRunDriver(
    _ argc: UnsafeMutablePointer<CInt>,
    _ argv: UnsafeMutablePointer<UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?>,
    _ callback: @convention(c) (UnsafePointer<UInt8>?, Int) -> CInt
) -> CInt

/// SwiftPM links an executable's entry point under this name; libFuzzer
/// then takes over.
@_cdecl("circles_fuzz_main")
public func circlesFuzzMain(_ argc: CInt, _ argv: UnsafeMutablePointer<UnsafeMutablePointer<CChar>?>?) -> CInt {
    var count = argc
    var arguments = argv
    return LLVMFuzzerRunDriver(&count, &arguments) { data, size in
        guard let data else { return 0 }
        return fuzz(data, size)
    }
}
