import CryptoKit
import Darwin
import Foundation

@main struct AcousticFileBridgeTests {
    static func main() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("acoustic-fd-tests-\(UUID())", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }
        func openFile(_ name: String, _ flags: Int32) -> Int32 {
            let fd = Darwin.open(directory.appendingPathComponent(name).path, flags | O_CREAT, mode_t(0o600))
            precondition(fd >= 3); return fd
        }
        let generation = UUID(), recordID = UUID()
        let command = openFile("command", O_RDWR), response = openFile("response", O_RDWR), archive = openFile("archive", O_WRONLY | O_APPEND)
        let wav = speechWAV()
        try wav.write(to: directory.appendingPathComponent("speech.wav"))
        let speech = Darwin.open(directory.appendingPathComponent("speech.wav").path, O_RDONLY)
        let bridge = try GuestAudioTestFileBridge(generation: generation, directory: directory,
            descriptors: .init(command: command, response: response, speech: speech, archive: archive))
        func expectCommand(_ expected: Data?) throws {
            let actual = try bridge.commandData(); precondition(actual == expected)
        }
        let payload = Data("{\"id\":\"\(UUID())\",\"operation\":\"snapshot\"}".utf8)
        let frame = try GuestAudioTestFileBridge.frame(payload, sequence: 1, generation: generation)
        replace(command, with: frame.dropLast())
        try expectCommand(nil)
        replace(command, with: frame); _ = lseek(command, 0, SEEK_END)
        try expectCommand(payload)
        let reply = Data("{\"requestID\":\"fixture\",\"succeeded\":true}".utf8)
        try bridge.mirrorResponse(reply)
        let replyFrame = try GuestAudioTestFileBridge.unframe(Data(contentsOf: directory.appendingPathComponent("response")), generation: generation, maximumPayload: 524_288)
        precondition(replyFrame.sequence == 1 && replyFrame.payload == reply)
        let second = try GuestAudioTestFileBridge.frame(payload, sequence: 2, generation: generation)
        replace(command, with: second); try expectCommand(payload)
        replace(command, with: frame); try expectCommand(nil)
        let old = try JSONDecoder().decode(GuestAudioTestFileBridge.Envelope.self, from: second)
        let mixed = GuestAudioTestFileBridge.Envelope(version: 1, sequence: 3, generation: old.generation,
            size: old.size, sha256: old.sha256, payload: old.payload)
        replace(command, with: try JSONEncoder().encode(mixed)); try expectCommand(nil)
        let wrongGeneration = try GuestAudioTestFileBridge.frame(payload, sequence: 3, generation: UUID())
        replace(command, with: wrongGeneration); try expectCommand(nil)
        _ = lseek(speech, 0, SEEK_END)
        let bytes = try bridge.speechData(); precondition(bytes == wav)
        let fromFD = try GuestAudioTestSpeech(data: bytes, source: "inherited descriptor")
        let fromURL = try GuestAudioTestSpeech(url: directory.appendingPathComponent("speech.wav"))
        precondition(fromFD.samples == fromURL.samples && fromFD.evidence["sha256"] as? String == fromURL.evidence["sha256"] as? String)
        try bridge.export(Data("{\"phase\":\"start\"}".utf8), as: .phaseStart(recordID))
        let recordingURL = directory.appendingPathComponent(GuestAudioTestFileBridge.Artifact.localReference(recordID).name)
        try wav.write(to: recordingURL)
        try await bridge.exportRecording(recordingURL, as: .localReference(recordID))
        let customRecordingURL = directory.appendingPathComponent(GuestAudioTestFileBridge.Artifact.customCapturePostProcessing(recordID).name)
        try wav.write(to: customRecordingURL)
        try await bridge.exportRecording(customRecordingURL, as: .customCapturePostProcessing(recordID))
        try bridge.export(reply, as: .phaseEnd(recordID))
        try await bridge.finishAndClose(); try await bridge.finishAndClose()
        for fd in [command, response, speech, archive] { precondition(fcntl(fd, F_GETFL) == -1 && errno == EBADF) }
        let archived = try Data(contentsOf: directory.appendingPathComponent("archive"))
        let allowedNames: Set<String> = [GuestAudioTestFileBridge.Artifact.phaseStart(recordID).name,
            GuestAudioTestFileBridge.Artifact.localReference(recordID).name,
            GuestAudioTestFileBridge.Artifact.customCapturePostProcessing(recordID).name,
            GuestAudioTestFileBridge.Artifact.phaseEnd(recordID).name]
        let records = try decodeArchive(archived, generation: generation, allowedNames: allowedNames)
        precondition(records.count == 4 && records[1].1 == wav && records[2].1 == wav)
        precondition(records[0].0 == GuestAudioTestFileBridge.Artifact.phaseStart(recordID).name)
        precondition(records[2].0 == GuestAudioTestFileBridge.Artifact.customCapturePostProcessing(recordID).name)
        precondition(records[3].0 == GuestAudioTestFileBridge.Artifact.phaseEnd(recordID).name)
        do { _ = try decodeArchive(archived.dropLast(), generation: generation, allowedNames: allowedNames); preconditionFailure("Truncation must fail") } catch {}
        var tampered = archived; tampered[tampered.count - 1] ^= 1
        do { _ = try decodeArchive(tampered, generation: generation, allowedNames: allowedNames); preconditionFailure("Hash mismatch must fail") } catch {}
        do { _ = try decodeArchive(archived + Data("trailing".utf8), generation: generation, allowedNames: allowedNames); preconditionFailure("Trailing bytes must fail") } catch {}
        do { _ = try decodeArchive(archived, generation: UUID(), allowedNames: allowedNames); preconditionFailure("Wrong generation must fail") } catch {}
        do { _ = try decodeArchive(archived, generation: generation, allowedNames: []); preconditionFailure("Unrecognized basename must fail") } catch {}
        let failedFD = openFile("failed-archive", O_WRONLY | O_APPEND)
        let failed = try GuestAudioTestFileBridge(generation: generation, directory: directory, descriptors: .init(archive: failedFD))
        try failed.export(reply, as: .phaseStart(recordID))
        do {
            try await failed.exportRecording(directory.appendingPathComponent("speech.wav"), as: .localReference(recordID))
            preconditionFailure("Arbitrary file export must fail")
        } catch GuestAudioTestBridgeError.invalidFrame {}
        do { try await failed.finishAndClose(); preconditionFailure("Export failure must remain sticky") }
        catch GuestAudioTestBridgeError.invalidFrame {}
        precondition(fcntl(failedFD, F_GETFL) == -1 && errno == EBADF)
        let failedArchiveData = try Data(contentsOf: directory.appendingPathComponent("failed-archive"))
        precondition(!failedArchiveData.isEmpty)
        let oversizedFD = openFile("oversized-archive", O_WRONLY | O_APPEND)
        let oversized = try GuestAudioTestFileBridge(generation: generation, directory: directory, descriptors: .init(archive: oversizedFD))
        do { try oversized.export(Data(count: 524_289), as: .telemetry); preconditionFailure("Oversized JSON must fail") }
        catch GuestAudioTestBridgeError.oversized {}
        do { try await oversized.finishAndClose(); preconditionFailure("Pre-enqueue failure must remain sticky") }
        catch GuestAudioTestBridgeError.oversized {}
        precondition(fcntl(oversizedFD, F_GETFL) == -1 && errno == EBADF)
        let aliased = openFile("alias", O_RDWR), duplicate = dup(aliased)
        do {
            _ = try GuestAudioTestFileBridge(generation: generation, directory: directory, descriptors: .init(command: aliased, response: duplicate))
            preconditionFailure("Descriptor aliases must fail")
        } catch GuestAudioTestBridgeError.descriptorAlias {}
        Darwin.close(aliased); Darwin.close(duplicate)
        let writableSpeech = openFile("speech.wav", O_RDWR)
        do {
            _ = try GuestAudioTestFileBridge(generation: generation, directory: directory, descriptors: .init(speech: writableSpeech))
            preconditionFailure("Writable speech descriptor must fail")
        } catch GuestAudioTestBridgeError.invalidDescriptor {}
        Darwin.close(writableSpeech)
        var pipes: [Int32] = [0, 0]; precondition(pipe(&pipes) == 0)
        do {
            _ = try GuestAudioTestFileBridge(generation: generation, directory: directory, descriptors: .init(command: pipes[0]))
            preconditionFailure("Blocking pipe must fail")
        } catch GuestAudioTestBridgeError.invalidDescriptor {}
        pipes.forEach { Darwin.close($0) }
        print("PASS: inherited regular FD validation, integrity-framed commands/responses, partial/mixed/replayed rejection, strict same-byte speech, allowlisted archive framing/hash/truncation and close-once")
    }
    static func replace(_ fd: Int32, with data: Data) {
        data.withUnsafeBytes { bytes in precondition(pwrite(fd, bytes.baseAddress, bytes.count, 0) == bytes.count) }
        precondition(ftruncate(fd, off_t(data.count)) == 0)
    }
    static func decodeArchive(_ data: Data, generation: UUID, allowedNames: Set<String>) throws -> [(String, Data)] {
        var offset = 0, result: [(String, Data)] = []
        while offset < data.count {
            guard let end = data[offset...].firstIndex(of: 10), end - offset <= 1023,
                  let header = try JSONSerialization.jsonObject(with: data[offset..<end]) as? [String: Any],
                  header["generation"] as? String == generation.uuidString,
                  let name = header["name"] as? String, allowedNames.contains(name), let count = header["size"] as? Int, count >= 0,
                  count <= 12_000_044, count <= data.count - end - 1, let digest = header["sha256"] as? String else { throw GuestAudioTestBridgeError.invalidFrame }
            let payload = Data(data[(end + 1)..<(end + 1 + count)])
            guard SHA256.hash(data: payload).map({ String(format: "%02x", $0) }).joined() == digest else { throw GuestAudioTestBridgeError.invalidFrame }
            result.append((name, payload)); offset = end + 1 + count
        }
        return result
    }
    static func speechWAV() -> Data {
        var data = Data("RIFF".utf8)
        func u32(_ value: UInt32) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        func u16(_ value: UInt16) { var value = value.littleEndian; withUnsafeBytes(of: &value) { data.append(contentsOf: $0) } }
        u32(996); data.append(Data("WAVEfmt ".utf8)); u32(16); u16(1); u16(1); u32(48_000); u32(96_000); u16(2); u16(16)
        data.append(Data("data".utf8)); u32(960)
        for _ in 0..<480 { u16(4096) }
        return data
    }
}
