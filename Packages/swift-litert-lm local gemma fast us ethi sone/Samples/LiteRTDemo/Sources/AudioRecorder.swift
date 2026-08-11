// LiteRTDemo — microphone recorder.
//
// Records 16 kHz mono PCM WAV (the rate Gemma 4's audio encoder expects) to a
// temp file, for sending as an audio turn in the chat.

import Foundation
import AVFoundation

@MainActor
final class AudioRecorder: NSObject, ObservableObject {
  @Published private(set) var isRecording = false

  private var recorder: AVAudioRecorder?
  private var fileURL: URL?

  /// Ask for mic permission (once). Returns whether granted.
  func requestPermission() async -> Bool {
    await withCheckedContinuation { continuation in
      AVAudioSession.sharedInstance().requestRecordPermission { granted in
        continuation.resume(returning: granted)
      }
    }
  }

  /// Start recording to a fresh temp WAV. Returns false if it couldn't start.
  func start() -> Bool {
    let session = AVAudioSession.sharedInstance()
    do {
      try session.setCategory(.playAndRecord, mode: .default)
      try session.setActive(true)
    } catch {
      return false
    }
    let url = FileManager.default.temporaryDirectory
      .appendingPathComponent("rec-\(UUID().uuidString).wav")
    let settings: [String: Any] = [
      AVFormatIDKey: kAudioFormatLinearPCM,
      AVSampleRateKey: 16_000.0,
      AVNumberOfChannelsKey: 1,
      AVLinearPCMBitDepthKey: 16,
      AVLinearPCMIsBigEndianKey: false,
      AVLinearPCMIsFloatKey: false,
    ]
    do {
      let recorder = try AVAudioRecorder(url: url, settings: settings)
      guard recorder.record() else { return false }
      self.recorder = recorder
      self.fileURL = url
      isRecording = true
      return true
    } catch {
      return false
    }
  }

  /// Stop recording and return the recorded file URL.
  @discardableResult
  func stop() -> URL? {
    recorder?.stop()
    recorder = nil
    isRecording = false
    try? AVAudioSession.sharedInstance().setActive(false)
    return fileURL
  }
}
