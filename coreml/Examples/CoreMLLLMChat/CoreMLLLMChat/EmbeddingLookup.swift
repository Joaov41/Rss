import Foundation
import CoreML
import Accelerate

/// Memory-mapped embedding lookup for large vocabulary tables.
/// Reads int8 quantized embeddings from disk without loading entire table into RAM.
final class EmbeddingLookup {
    private let data: Data  // memory-mapped
    private let scales: Data
    private let vocabSize: Int
    private let dim: Int
    private let scale: Float  // embedding scale factor

    // Preallocated buffers for vectorized dequantization (avoid alloc per token)
    private var f32Buffer: [Float]
    private var f16Buffer: [UInt16]

    /// Load an int8 quantized embedding table.
    init(dataURL: URL, scalesURL: URL, vocabSize: Int, dim: Int, scale: Float = 1.0) throws {
        self.data = try Data(contentsOf: dataURL, options: .mappedIfSafe)
        self.scales = try Data(contentsOf: scalesURL, options: .mappedIfSafe)
        self.vocabSize = vocabSize
        self.dim = dim
        self.scale = scale
        self.f32Buffer = [Float](repeating: 0, count: dim)
        self.f16Buffer = [UInt16](repeating: 0, count: dim)
    }

    /// Look up embedding for a single token and return as float16 MLMultiArray.
    /// Uses Accelerate for vectorized INT8 → FP16 conversion.
    func lookup(_ tokenID: Int, shape: [NSNumber]) throws -> MLMultiArray {
        let result = try MLMultiArray(shape: shape, dataType: .float16)
        let dstPtr = result.dataPointer.bindMemory(to: UInt16.self, capacity: dim)

        data.withUnsafeBytes { rawPtr in
            let int8Ptr = rawPtr.baseAddress!.assumingMemoryBound(to: Int8.self)
                .advanced(by: tokenID * dim)
            scales.withUnsafeBytes { scaleRaw in
                let scalePtr = scaleRaw.baseAddress!.assumingMemoryBound(to: UInt16.self)
                let rowScale = float16ToFloat32(scalePtr[tokenID]) / 127.0 * scale

                // Vectorized: int8 → float32 → scale → float16
                // 1. Convert int8 to float32 using vDSP
                vDSP.convertElements(of: UnsafeBufferPointer(start: int8Ptr, count: dim),
                                     to: &f32Buffer)
                // 2. Multiply by scale
                vDSP.multiply(rowScale, f32Buffer, result: &f32Buffer)
                // 3. Convert float32 to float16
                f32Buffer.withUnsafeBufferPointer { src in
                    var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                               height: 1, width: UInt(dim), rowBytes: dim * 4)
                    var dstBuf = vImage_Buffer(data: UnsafeMutableRawPointer(dstPtr),
                                               height: 1, width: UInt(dim), rowBytes: dim * 2)
                    vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
                }
            }
        }

        return result
    }

    /// Look up and return as raw float16 array (for per-layer combined computation).
    func lookupRaw(_ tokenID: Int) -> [UInt16] {
        data.withUnsafeBytes { rawPtr in
            let int8Ptr = rawPtr.baseAddress!.assumingMemoryBound(to: Int8.self)
                .advanced(by: tokenID * dim)
            scales.withUnsafeBytes { scaleRaw in
                let scalePtr = scaleRaw.baseAddress!.assumingMemoryBound(to: UInt16.self)
                let rowScale = float16ToFloat32(scalePtr[tokenID]) / 127.0 * scale

                // Vectorized conversion
                vDSP.convertElements(of: UnsafeBufferPointer(start: int8Ptr, count: dim),
                                     to: &f32Buffer)
                vDSP.multiply(rowScale, f32Buffer, result: &f32Buffer)
                f32Buffer.withUnsafeBufferPointer { src in
                    var srcBuf = vImage_Buffer(data: UnsafeMutableRawPointer(mutating: src.baseAddress!),
                                               height: 1, width: UInt(dim), rowBytes: dim * 4)
                    f16Buffer.withUnsafeMutableBufferPointer { dst in
                        var dstBuf = vImage_Buffer(data: dst.baseAddress!,
                                                   height: 1, width: UInt(dim), rowBytes: dim * 2)
                        vImageConvert_PlanarFtoPlanar16F(&srcBuf, &dstBuf, 0)
                    }
                }
            }
        }
        return f16Buffer
    }

    // MARK: - Float16 Conversion

    private func float16ToFloat32(_ bits: UInt16) -> Float {
        var f: Float = 0
        withUnsafePointer(to: bits) { _ in
            let sign: UInt32 = UInt32(bits >> 15) << 31
            let exp = UInt32((bits >> 10) & 0x1F)
            let frac = UInt32(bits & 0x3FF)

            if exp == 0 {
                if frac == 0 { f = Float(bitPattern: sign); return }
                var e: UInt32 = 113
                var fr = frac
                while fr & 0x400 == 0 { fr <<= 1; e -= 1 }
                fr &= 0x3FF
                f = Float(bitPattern: sign | ((e + 1) << 23) | (fr << 13))
            } else if exp == 31 {
                f = Float(bitPattern: sign | 0x7F800000 | (frac << 13))
            } else {
                f = Float(bitPattern: sign | ((exp + 112) << 23) | (frac << 13))
            }
        }
        return f
    }
}
