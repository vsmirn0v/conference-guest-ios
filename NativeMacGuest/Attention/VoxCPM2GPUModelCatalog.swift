import Foundation

/// Independent MLX checkpoint for the existing VoxCPM2 saved-voice format.
/// Every download is fixed to one Hugging Face revision, size, and SHA-256.
/// This catalog alone does not download or enable the GPU backend.
enum VoxCPM2GPUModelCatalog {
    static let revision = "dc9e5c187858da5f4a13dc4c247e297339216381"
    static let id = "voxcpm2-mlx-4bit"
    static let kind = "voxcpm2_mlx"
    static let repository = "mlx-community/VoxCPM2-4bit"

    static let model: ListenModelCatalog.Model = {
        let base = "https://huggingface.co/\(repository)/resolve/\(revision)/"
        let entries: [(String, Int64, String)] = [
            ("config.json", 5_332, "91bff6db1be27bc0f4f2a287cca7a8fbb8b1d7a0b026a5dc4a71bc5f2f1ddcfb"),
            ("model.safetensors", 2_297_215_329, "25bddc99a7cc6d28214f12dd676ed0afa9b0a805d6477f85c275bb113cb8acee"),
            ("special_tokens_map.json", 1_632, "068594063e37662c02b21acf42ebb334ef6a74fb810e68a2368f88f08351de76"),
            ("tokenizer.json", 3_676_772, "f8984687e4a92a3503d521396d454b7d68e9fdaab2a0288eb3536c7c1aa4bc20"),
            ("tokenizer_config.json", 4_952, "466575c55f0cf49530666c2e46ed14f26237dbd227ba7f4bb3bbec93df90edfc"),
        ]
        let files = entries.map { name, size, digest in
            ListenModelCatalog.File(name: name, size: size, url: URL(string: base + name)!, sha256: digest)
        }
        return ListenModelCatalog.Model(
            id: id, role: VoiceCloneSupport.role, title: "VoxCPM2 (GPU)", kind: kind,
            featureDim: nil, languages: ["ru", "en"], licence: "Apache-2.0 (OpenBMB VoxCPM2; MLX conversion by mlx-community)",
            source: URL(string: "https://huggingface.co/\(repository)")!, files: files,
            config: ["revision": revision, "voiceRevision": VoxVoice.revision, "quantization": "4bit"]
        )
    }()
}
