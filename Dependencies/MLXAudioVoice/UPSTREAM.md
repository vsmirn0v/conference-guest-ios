# MLX audio voice runtime

This is a restricted copy of MLXAudioCore and the VoxCPM2 speech model from
[Neywa-Labs/mlx-audio-swift](https://github.com/Neywa-Labs/mlx-audio-swift),
commit `cf095e05a8cbb5aaceac92aeee0b2061b59ad30e`, under the accompanying MIT license.
Only the source needed by the local GPU voice worker is included. `VoxCPM2Model`
has a saved-latent entry point adapted to the existing VoxVoice prompt format,
with bounds and incomplete-generation checks. The package dependencies are pinned
in Package.swift; model weights are installed separately.
