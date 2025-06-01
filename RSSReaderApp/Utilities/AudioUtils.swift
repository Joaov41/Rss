import Foundation

// MARK: - Audio Utility Functions
// Made public so it can be accessed from other files
public func createWavData(from pcmData: Data, sampleRate: UInt32, channels: UInt16, bitsPerSample: UInt16) -> Data {
    var header = Data()
    let pcmDataSize = UInt32(pcmData.count)
    var chunkSize: UInt32 = 36 + pcmDataSize
    var subChunk1Size: UInt32 = 16 // For PCM
    var audioFormat: UInt16 = 1   // For PCM

    // RIFF Header
    header.append("RIFF".data(using: .ascii)!)
    header.append(Data(bytes: &chunkSize, count: MemoryLayout.size(ofValue: chunkSize)))
    header.append("WAVE".data(using: .ascii)!)

    // FMT Subchunk
    header.append("fmt ".data(using: .ascii)!)
    header.append(Data(bytes: &subChunk1Size, count: MemoryLayout.size(ofValue: subChunk1Size)))
    header.append(Data(bytes: &audioFormat, count: MemoryLayout.size(ofValue: audioFormat)))
    
    var mutableChannels = channels // Create a mutable copy
    header.append(Data(bytes: &mutableChannels, count: MemoryLayout.size(ofValue: mutableChannels)))
    
    var mutableSampleRate = sampleRate // Create a mutable copy
    header.append(Data(bytes: &mutableSampleRate, count: MemoryLayout.size(ofValue: mutableSampleRate)))
    
    let byteRate = sampleRate * UInt32(channels) * UInt32(bitsPerSample) / 8
    var mutableByteRate = byteRate // Create a mutable copy for the pointer
    header.append(Data(bytes: &mutableByteRate, count: MemoryLayout.size(ofValue: mutableByteRate)))
    
    let blockAlign = channels * bitsPerSample / 8
    var mutableBlockAlign = blockAlign // Create a mutable copy
    header.append(Data(bytes: &mutableBlockAlign, count: MemoryLayout.size(ofValue: mutableBlockAlign)))
    
    var mutableBitsPerSample = bitsPerSample // Create a mutable copy
    header.append(Data(bytes: &mutableBitsPerSample, count: MemoryLayout.size(ofValue: mutableBitsPerSample)))

    // DATA Subchunk
    header.append("data".data(using: .ascii)!)
    var mutablePcmDataSize = pcmDataSize // Create a mutable copy
    header.append(Data(bytes: &mutablePcmDataSize, count: MemoryLayout.size(ofValue: mutablePcmDataSize)))
    
    // Append PCM data
    var result = header
    result.append(pcmData)
    
    return result
}

// Helper function to detect MP3 data format (used by multiple views)
public func isMP3Data(_ data: Data) -> Bool {
    // MP3 files typically start with ID3 tag (0x494433) or sync header (0xFFE or 0xFFF)
    guard data.count >= 3 else { return false }
    
    let bytes = data.prefix(3)
    let header = [UInt8](bytes)
    
    // Check for ID3 tag (ID3v2)
    if header.count >= 3 && header[0] == 0x49 && header[1] == 0x44 && header[2] == 0x33 {
        return true
    }
    
    // Check for MP3 sync header (frame sync)
    if header.count >= 2 {
        let syncPattern = (UInt16(header[0]) << 8) | UInt16(header[1])
        // MP3 frame header starts with 11 bits set (0xFFE or 0xFFF followed by specific patterns)
        if (syncPattern & 0xFFE0) == 0xFFE0 {
            return true
        }
    }
    
    return false
} 