# StemDrop

StemDrop is a macOS app for separating audio into stems and cleaning vocal stems.

## Build

Requires macOS 14 or later, Swift 6, and an Apple Silicon Mac. Run `swift build` and `swift test` from this folder. The Python engine dependencies are listed in `Engine/requirements.txt`; `Engine/build_engine.sh` packages the engine for a local app bundle. Run `Scripts/bundle.sh` after packaging the engine to create the app bundle.

The bundled Silero VAD model is distributed under its MIT license in `Engine/stemdrop_engine/data/SILERO_VAD_LICENSE`. Other model weights are downloaded by the app when needed.
