"""StemDrop separation engine CLI.

Invoked as: python3 -m stemdrop_engine --input <wav> --out <dir>
    --stems drums,vocals --model htdemucs_6s --device mps

Emits JSON lines on stdout only (see SPEC.md §3):
    {"event":"loading"}
    {"event":"progress","fraction":0.42}
    {"event":"stem","name":"drums","path":"…/drums.wav"}
    {"event":"done"}
    {"event":"error","message":"…"}

Nothing else may go to stdout. All diagnostics/tracebacks go to stderr.
"""
import argparse
import json
import os
import sys
import time

# Make this process its own process-group leader so the Swift side can
# signal the whole group (child + any grandchildren it spawns) on
# cancellation/termination without also hitting the parent app.
os.setpgrp()

# Point HF_HOME at the caller-supplied model dir *before* importing demucs,
# so weight downloads/lookups land there instead of ~/.cache.
_model_dir = os.environ.get("STEMDROP_MODEL_DIR")
if _model_dir:
    os.environ["HF_HOME"] = _model_dir

# Silence any tqdm progress bars demucs/torch might try to print to stdout.
os.environ.setdefault("TQDM_DISABLE", "1")

# Allow MPS ops without a Metal fallback to run on CPU instead of crashing,
# for any demucs/torch ops that don't yet have an MPS kernel. Must be set
# before torch is imported.
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


# Quality-first model selection (Daniel, 2026-09-19).
# htdemucs_ft is a bag of four per-stem fine-tunes and measures clearly better
# on vocals/drums/bass/other than the six-stem model, but it has no guitar or
# piano. htdemucs_6s is the only model that can produce guitar/piano, so it is
# used only when one of those is requested.
_QUALITY_MODEL = "htdemucs_ft"
_SIX_STEM_MODEL = "htdemucs_6s"
_SIX_STEM_ONLY = {"guitar", "piano"}
_DRUM_DETAIL_STEMS = {"kick", "snare", "cymbals"}


def _split_drum_detail(wav, sample_rate):
    """Split the Demucs drum stem into rough low, mid, and high bands."""
    import torch

    n_fft = 4096
    hop = 1024
    window = torch.hann_window(n_fft, device=wav.device)
    spectrum = torch.stft(
        wav, n_fft=n_fft, hop_length=hop, window=window,
        return_complex=True, center=True,
    )
    frequencies = torch.fft.rfftfreq(n_fft, d=1.0 / sample_rate).to(wav.device)
    bands = {
        "kick": frequencies <= 180.0,
        "snare": (frequencies > 180.0) & (frequencies < 4000.0),
        "cymbals": frequencies >= 4000.0,
    }
    return {
        name: torch.istft(
            spectrum * mask.view(1, -1, 1), n_fft=n_fft, hop_length=hop,
            window=window, length=wav.shape[-1],
        )
        for name, mask in bands.items()
    }


def _parse_args(argv):
    parser = argparse.ArgumentParser(prog="stemdrop_engine")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--stems", required=True, help="comma-separated stem list")
    parser.add_argument(
        "--model",
        default="auto",
        help="'auto' (default) picks htdemucs_ft, or htdemucs_6s when "
        "guitar/piano is requested; or name a demucs model explicitly",
    )
    parser.add_argument("--device", default="mps")
    return parser.parse_args(argv)


def _resolve_model(requested: str, stems) -> str:
    if requested != "auto":
        return requested
    if any(stem in _SIX_STEM_ONLY for stem in stems):
        return _SIX_STEM_MODEL
    return _QUALITY_MODEL


def _resolve_device(requested: str) -> str:
    if requested != "mps":
        return requested
    try:
        import torch

        if torch.backends.mps.is_available():
            return "mps"
    except Exception:  # noqa: BLE001
        pass
    return "cpu"


def main(argv=None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    stems = [s.strip() for s in args.stems.split(",") if s.strip()]

    try:
        device = _resolve_device(args.device)

        # tqdm writes to stderr by default, but be explicit: patch it off
        # in case demucs internals default to stdout.
        import tqdm

        tqdm.tqdm.__init__disable_patch = True  # no-op marker, kept for clarity
        _orig_tqdm_init = tqdm.tqdm.__init__

        def _quiet_tqdm_init(self, *a, **kw):
            kw["disable"] = True
            return _orig_tqdm_init(self, *a, **kw)

        tqdm.tqdm.__init__ = _quiet_tqdm_init

        from demucs.api import Separator, save_audio

        _emit({"event": "loading"})

        state = {"last_emit": 0.0}

        # A "bag" model (htdemucs_ft) applies several models in turn, and
        # demucs reports segment_offset/fraction per model — so a naive
        # fraction would reset to 0 once per model. Count the resets and
        # spread the progress evenly across the bag so the bar is monotonic.
        # bag_count is refined once the separator exists (below); the callback
        # only runs later, so the closure reads the updated value.
        bag_count = 1
        progress_state = {"completed": 0, "last": 0.0}

        def _overall_fraction(raw: float) -> float:
            if bag_count > 1 and raw + 0.01 < progress_state["last"]:
                progress_state["completed"] = min(progress_state["completed"] + 1, bag_count - 1)
            progress_state["last"] = raw
            overall = (progress_state["completed"] + raw) / bag_count
            return max(0.0, min(1.0, overall))

        def _callback(info: dict) -> None:
            audio_length = info.get("audio_length")
            segment_offset = info.get("segment_offset")
            if not audio_length:
                return
            raw = max(0.0, min(1.0, segment_offset / audio_length))
            now = time.monotonic()
            if now - state["last_emit"] >= 0.5:
                state["last_emit"] = now
                _emit({"event": "progress", "fraction": _overall_fraction(raw)})

        model = _resolve_model(args.model, stems)
        sys.stderr.write(f"stemdrop_engine: model={model} device={device} stems={','.join(stems)}\n")
        sys.stderr.flush()

        separator = Separator(model=model, device=device, callback=_callback)

        bag = getattr(getattr(separator, "model", None), "models", None)
        if bag:
            bag_count = max(1, len(bag))

        os.makedirs(args.out, exist_ok=True)

        _, separated = separator.separate_audio_file(args.input)

        detail = {}
        if any(name in _DRUM_DETAIL_STEMS for name in stems):
            detail = _split_drum_detail(separated["drums"], separator.samplerate)

        for name in stems:
            wav = detail.get(name, separated.get(name))
            if wav is None:
                continue
            out_path = os.path.join(args.out, f"{name}.wav")
            save_audio(wav, out_path, samplerate=separator.samplerate, as_float=True, bits_per_sample=32)
            _emit({"event": "stem", "name": name, "path": out_path})

        _emit({"event": "done"})
        return 0
    except Exception as exc:  # noqa: BLE001
        _emit({"event": "error", "message": str(exc)})
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
