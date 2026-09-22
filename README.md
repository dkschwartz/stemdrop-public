# StemDrop

StemDrop is a macOS app for separating audio into stems and cleaning vocal stems.

## Download and use

StemDrop requires an Apple Silicon Mac running macOS 14 or later.

1. [Download the standalone app ZIP](https://github.com/dkschwartz/stemdrop-public/releases/download/v0.1.2/StemDrop-Apple-Silicon.zip), unzip it, and drag `StemDrop.app` into Applications.
2. Open StemDrop. If macOS blocks it, try opening it once, then go to **System Settings → Privacy & Security → Open Anyway**. This build is not Apple notarized. [Apple explains this step](https://support.apple.com/en-us/102445).
3. Select the stems you want, drag in an audio file or click **Choose Songs…**, then click **Split**. The app downloads its separation model when first needed, so keep your internet connection on for the first run.

The Kick, Snare, and Cymbals checkboxes create rough low, mid, and high frequency versions of the separated Drums stem. They are useful for quick edits, but they are not individually trained instrument isolation models; each output can contain other drum sounds in the same frequency range.

## Build

Requires macOS 14 or later, Swift 6, and an Apple Silicon Mac. Run `swift build` and `swift test` from this folder. The Python engine dependencies are listed in `Engine/requirements.txt`; `Engine/build_engine.sh` packages the engine for a local app bundle. Run `Scripts/bundle.sh` after packaging the engine to create the app bundle.

The bundled Silero VAD model is distributed under its MIT license in `Engine/stemdrop_engine/data/SILERO_VAD_LICENSE`. Other model weights are downloaded by the app when needed.
