import XCTest
@testable import RockNativeDesktop

final class VoxCPM2GPUModelCatalogTests: XCTestCase {
    func testCheckpointIsPinnedAndDistinctFromNeuralEngineModel() throws {
        let model = VoxCPM2GPUModelCatalog.model
        XCTAssertEqual(model.id, "voxcpm2-mlx-4bit")
        XCTAssertEqual(model.role, VoiceCloneSupport.role)
        XCTAssertEqual(model.kind, "voxcpm2_mlx")
        XCTAssertNotEqual(model.kind, VoiceCloneSupport.kind)
        XCTAssertEqual(model.config["revision"], "dc9e5c187858da5f4a13dc4c247e297339216381")
        XCTAssertEqual(model.config["voiceRevision"], VoxVoice.revision)
        XCTAssertEqual(model.size, 2_300_904_017)
        XCTAssertTrue(model.pinned)
        XCTAssertTrue(model.licence.contains("Apache-2.0"))
        XCTAssertEqual(Set(model.files.map(\.name)), ["config.json", "model.safetensors", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json"])
        for file in model.files {
            XCTAssertEqual(file.url.scheme, "https")
            XCTAssertEqual(file.url.host, "huggingface.co")
            XCTAssertEqual(file.url.path, "/mlx-community/VoxCPM2-4bit/resolve/dc9e5c187858da5f4a13dc4c247e297339216381/\(file.name)")
            XCTAssertGreaterThan(file.size, 0)
        }
        let weights = try XCTUnwrap(model.files.first { $0.name == "model.safetensors" })
        XCTAssertEqual(weights.size, 2_297_215_329)
        XCTAssertEqual(weights.sha256, "25bddc99a7cc6d28214f12dd676ed0afa9b0a805d6477f85c275bb113cb8acee")
    }

    func testGPUCheckpointDoesNotAppearAmongTranscriptionChoices() {
        let base = ListenModelCatalog(schemaVersion: 1, runtime: "fixture", models: [])
        let withGPU = base.including(VoxCPM2GPUModelCatalog.model).including(VoxCPM2GPUModelCatalog.model)
        XCTAssertEqual(withGPU.models.count, 1)
        XCTAssertTrue(withGPU.listen.isEmpty)
        XCTAssertNil(withGPU.vad)
    }
}
