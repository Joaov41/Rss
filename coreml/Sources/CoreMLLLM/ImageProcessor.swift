import CoreML
import CoreGraphics
import Foundation

/// Processes images for Gemma 4 multimodal vision encoder.
///
/// Matches HuggingFace Gemma3nImageProcessor:
///   1. Aspect-ratio-preserving resize to max 645,120 pixels (2520 × 16²)
///   2. Each side rounded down to a multiple of 48 (pooling_kernel × patch_size)
///   3. Patch extraction: 16×16, channels-last, /255 normalization
///   4. Meshgrid position IDs (x, y) = (px, py) matching HF indexing="xy"
///   5. Padding positions marked with -1
public enum ImageProcessor {

    /// Process an image through the vision encoder CoreML model.
    ///
    /// Returns image features MLMultiArray (1, 280, hidden_size).
    public static func process(_ image: CGImage, with visionModel: MLModel) throws -> MLMultiArray {
        let ps = 16
        let total = 2520
        let pd = ps * ps * 3  // 768 per patch

        // 1. Aspect-ratio-preserving resize (each side multiple of 48).
        let origH = Double(image.height)
        let origW = Double(image.width)
        let targetPx = Double(total * ps * ps)  // 645_120
        let factor = sqrt(targetPx / (origH * origW))
        let sideMult = 48
        var tH = Int(floor(factor * origH / Double(sideMult))) * sideMult
        var tW = Int(floor(factor * origW / Double(sideMult))) * sideMult
        if tH < sideMult { tH = sideMult }
        if tW < sideMult { tW = sideMult }
        let Hp = tH / ps
        let Wp = tW / ps
        let realPatches = Hp * Wp

        // 2. Draw into (tW, tH) RGBA canvas with bicubic interpolation.
        var pixels = [UInt8](repeating: 0, count: tW * tH * 4)
        let bitmap = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        let ctx = CGContext(data: &pixels, width: tW, height: tH, bitsPerComponent: 8,
                            bytesPerRow: tW * 4, space: CGColorSpaceCreateDeviceRGB(),
                            bitmapInfo: bitmap.rawValue)!
        ctx.interpolationQuality = .high
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: tW, height: tH))

        // 3. Build pixel_values (1, 2520, 768) fp32 and pixel_position_ids (1, 2520, 2) int32.
        let pv = try MLMultiArray(shape: [1, NSNumber(value: total), NSNumber(value: pd)],
                                  dataType: .float32)
        let pid = try MLMultiArray(shape: [1, NSNumber(value: total), 2], dataType: .int32)
        let pvp = pv.dataPointer.bindMemory(to: Float.self, capacity: total * pd)
        let pidp = pid.dataPointer.bindMemory(to: Int32.self, capacity: total * 2)
        memset(pvp, 0, total * pd * MemoryLayout<Float>.stride)

        var pi = 0
        for py in 0..<Hp {
            for px in 0..<Wp {
                var o = pi * pd
                for dy in 0..<ps {
                    for dx in 0..<ps {
                        let srcIdx = ((py * ps + dy) * tW + (px * ps + dx)) * 4
                        pvp[o]   = Float(pixels[srcIdx])   / 255
                        pvp[o+1] = Float(pixels[srcIdx+1]) / 255
                        pvp[o+2] = Float(pixels[srcIdx+2]) / 255
                        o += 3
                    }
                }
                pidp[pi * 2]     = Int32(px)
                pidp[pi * 2 + 1] = Int32(py)
                pi += 1
            }
        }
        for i in realPatches..<total {
            pidp[i * 2]     = -1
            pidp[i * 2 + 1] = -1
        }

        let input = try MLDictionaryFeatureProvider(dictionary: [
            "pixel_values": MLFeatureValue(multiArray: pv),
            "pixel_position_ids": MLFeatureValue(multiArray: pid),
        ])
        guard let features = try visionModel.prediction(from: input)
                .featureValue(for: "image_features")?.multiArrayValue else {
            throw CoreMLLLMError.predictionFailed
        }
        return features
    }

    /// Extract a single image feature token from the vision output.
    public static func sliceFeature(_ features: MLMultiArray, at index: Int,
                                     hiddenSize: Int) -> MLMultiArray {
        let r = try! MLMultiArray(shape: [1, 1, NSNumber(value: hiddenSize)], dataType: .float16)
        let s = features.dataPointer.bindMemory(to: UInt16.self, capacity: features.count)
        let d = r.dataPointer.bindMemory(to: UInt16.self, capacity: hiddenSize)
        memcpy(d, s.advanced(by: index * hiddenSize), hiddenSize * MemoryLayout<UInt16>.stride)
        return r
    }
}
