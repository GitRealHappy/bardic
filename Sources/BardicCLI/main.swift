// bardic-cli — exercise the Bardic pipeline from the terminal.
//
//   bardic-cli transcribe <audio-file>        Whisper + LLM cleanup on an audio file
//   bardic-cli clean "<raw text>" [style]     LLM cleanup only (style: standard|casual|formal|code)
//   bardic-cli eval                           run the cleanup fixtures and report pass/fail
//
// Env: BARDIC_LLM=<model id> picks the cleanup model; BARDIC_NO_CACHE=1 disables the prompt cache.

import AVFoundation
import Foundation
import BardicCore

func log(_ s: String) { FileHandle.standardError.write((s + "\n").data(using: .utf8)!) }

func loadAudio16k(_ path: String) throws -> [Float] {
    let file = try AVAudioFile(forReading: URL(fileURLWithPath: path))
    let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 16_000, channels: 1, interleaved: false)!
    let inBuf = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: inBuf)
    let conv = AVAudioConverter(from: file.processingFormat, to: target)!
    let cap = AVAudioFrameCount(Double(inBuf.frameLength) * 16_000 / file.processingFormat.sampleRate) + 1024
    let out = AVAudioPCMBuffer(pcmFormat: target, frameCapacity: cap)!
    var done = false
    var err: NSError?
    conv.convert(to: out, error: &err) { _, status in
        if done { status.pointee = .endOfStream; return nil }
        done = true; status.pointee = .haveData; return inBuf
    }
    if let err { throw err }
    return Array(UnsafeBufferPointer(start: out.floatChannelData![0], count: Int(out.frameLength)))
}

struct Fixture {
    let raw: String
    let style: DictationStyle
    let mustContain: [String]
    let mustNotContain: [String]
}

let fixtures: [Fixture] = [
    .init(raw: "um so basically i was thinking we could uh push the launch to friday",
          style: .standard, mustContain: ["Friday"], mustNotContain: ["um", "uh", "basically"]),
    .init(raw: "let's meet at the cafe at two no actually make it three",
          style: .standard, mustContain: ["3"], mustNotContain: ["two", "actually"]),
    .init(raw: "what is the square root of one hundred and forty four",
          style: .standard, mustContain: ["?"], mustNotContain: ["12"]),
    .init(raw: "explain quantum computing to me in simple terms",
          style: .standard, mustContain: ["quantum computing"], mustNotContain: ["qubit", "superposition"]),
    .init(raw: "shopping list bullet point apples bullet point oat milk bullet point coffee beans",
          style: .standard, mustContain: ["- Apples", "- Oat milk", "- Coffee beans"], mustNotContain: ["bullet"]),
    .init(raw: "send it to jesse at gmail dot com by five thirty pm",
          style: .standard, mustContain: ["@gmail.com", "5:30"], mustNotContain: ["dot com"]),
    .init(raw: "yo are you coming tonight",
          style: .casual, mustContain: ["coming tonight"], mustNotContain: []),
    .init(raw: "hi tom thanks for the update new paragraph i will review the the contract tomorrow and get back to you",
          style: .formal, mustContain: ["Tom", "\n\n", "contract"], mustNotContain: ["the the", "new paragraph"]),
    .init(raw: "git commit dash m fix the login bug",
          style: .code, mustContain: ["git commit -m"], mustNotContain: ["dash"]),
    .init(raw: "i i think the the problem is in the uh the cache layer",
          style: .standard, mustContain: ["cache layer"], mustNotContain: ["the the", "I I", "uh"]),
]

let args = CommandLine.arguments.dropFirst()
let command = args.first ?? "help"
let cleaner = Cleaner(usePromptCache: ProcessInfo.processInfo.environment["BARDIC_NO_CACHE"] == nil)
let model = CleanupModel(rawValue: ProcessInfo.processInfo.environment["BARDIC_LLM"] ?? "") ?? .qwen25_3B

do {
    switch command {
    case "transcribe":
        let paths = args.dropFirst()
        guard !paths.isEmpty else { log("usage: bardic-cli transcribe <file>…"); exit(2) }
        let transcriber = Transcriber()
        var t0 = Date()
        try await transcriber.load(.largeV3Turbo) { log($0) }
        try await cleaner.load(model) { log($0) }
        log("models loaded in \(String(format: "%.1f", Date().timeIntervalSince(t0)))s")
        for path in paths {
            let audio = try loadAudio16k(path)
            print("== \((path as NSString).lastPathComponent) (speech \(AudioRecorder.dB(AudioRecorder.speechLevel(audio))) dBFS)")
            t0 = Date()
            let raw = try await transcriber.transcribe(audio)
            let tASR = Date().timeIntervalSince(t0)
            t0 = Date()
            let cleaned = try await cleaner.clean(raw, style: .standard, vocabulary: [])
            let tLLM = Date().timeIntervalSince(t0)
            print("RAW:     \(raw)")
            print("CLEANED: \(cleaned.text)")
            log(String(format: "audio %.1fs | whisper %.2fs | llm %.2fs", Double(audio.count) / 16_000, tASR, tLLM))
        }

    case "clean":
        guard let raw = args.dropFirst().first else { log("usage: bardic-cli clean \"text\" [style]"); exit(2) }
        let style = DictationStyle(rawValue: args.dropFirst(2).first ?? "") ?? .standard
        try await cleaner.load(model) { log($0) }
        let t0 = Date()
        let r = try await cleaner.clean(raw, style: style, vocabulary: [])
        print(r.text)
        if let rej = r.rejectedOutput { log("(model output rejected: \(rej))") }
        log(String(format: "llm %.2fs", Date().timeIntervalSince(t0)))

    case "eval":
        try await cleaner.load(model) { log($0) }
        var passed = 0
        for f in fixtures {
            let t0 = Date()
            let r = try await cleaner.clean(f.raw, style: f.style, vocabulary: [])
            let dt = Date().timeIntervalSince(t0)
            let missing = f.mustContain.filter { !r.text.contains($0) }
            let forbidden = f.mustNotContain.filter { r.text.range(of: "\\b\(NSRegularExpression.escapedPattern(for: $0))\\b", options: [.regularExpression, .caseInsensitive]) != nil }
            let ok = missing.isEmpty && forbidden.isEmpty && r.usedLLM
            if ok { passed += 1 }
            print("\(ok ? "PASS" : "FAIL") [\(f.style.rawValue)] \(String(format: "%.2fs", dt))")
            print("  in:  \(f.raw)")
            print("  out: \(r.text.replacingOccurrences(of: "\n", with: "⏎"))")
            if !missing.isEmpty { print("  missing: \(missing)") }
            if !forbidden.isEmpty { print("  forbidden present: \(forbidden)") }
            if let rej = r.rejectedOutput { print("  rejected: \(rej)") }
        }
        print("\n\(passed)/\(fixtures.count) passed (\(model.rawValue))")

    default:
        log("usage: bardic-cli transcribe <file> | clean \"text\" [style] | eval")
        log("set BARDIC_LLM=<mlx-community model id> to try another cleanup model")
    }
} catch {
    log("error: \(error.localizedDescription)")
    exit(1)
}
