"""StemDrop vocal "second pass" cleanup engine CLI.

Takes an already-separated vocal stem and strips the leftover music/non-voice
residue in up to three stages, each independently switchable:

  1. Re-separation  — run the stem through Demucs again (1 or 2 passes) and
                      keep only its `vocals` output. Removes music that bleeds
                      through *while* the voice is singing.
  2. Voice gate     — Silero VAD marks where a voice is actually present; the
                      gaps between phrases are faded to silence. Removes the
                      little bits that live between words.
  3. Spectral denoise — a soft spectral gate against a per-bin noise floor
                      estimated from the quietest voiced frames. Trims the
                      low-level bed sitting under the voice.

Invoked as: python3 -m stemdrop_engine.cleanup --input <wav> --out <dir>
    --reseparate 1 --gate 1 --gate-threshold 0.5 --denoise 0.5 --device mps

Emits the same JSON lines as the separator (SPEC.md §3), so the Swift side
parses it with the existing collector:
    {"event":"loading"}
    {"event":"progress","fraction":0.42}
    {"event":"stem","name":"vocals","path":"…/vocals.wav"}
    {"event":"done"}
    {"event":"error","message":"…"}

Nothing else may go to stdout. All diagnostics/tracebacks go to stderr.
Output length always equals input length (SPEC.md §7).
"""
import argparse
import json
import os
import struct
import sys
import time

# Same process/env setup as __main__.py: own process group so the Swift side
# can SIGTERM the whole tree; HF_HOME under the app's model dir; no tqdm bars
# on stdout; MPS ops without a Metal kernel fall back to CPU.
os.setpgrp()

_model_dir = os.environ.get("STEMDROP_MODEL_DIR")
if _model_dir:
    os.environ["HF_HOME"] = _model_dir

os.environ.setdefault("TQDM_DISABLE", "1")
os.environ.setdefault("PYTORCH_ENABLE_MPS_FALLBACK", "1")

_VAD_MODEL_PATH = os.path.join(os.path.dirname(__file__), "data", "silero_vad.jit")
_VAD_SAMPLE_RATE = 16000
_VAD_CHUNK = 512            # Silero's fixed window at 16 kHz (32 ms)
_RESEPARATE_MODEL = "htdemucs_ft"
_LEVEL_MARGIN_DB = 18.0      # see voiced_frames()


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _log(msg: str) -> None:
    sys.stderr.write(f"stemdrop_cleanup: {msg}\n")
    sys.stderr.flush()


def _parse_args(argv):
    parser = argparse.ArgumentParser(prog="stemdrop_engine.cleanup")
    parser.add_argument("--input", required=True)
    parser.add_argument("--out", required=True)
    parser.add_argument("--reseparate", type=int, default=1, choices=[0, 1, 2],
                        help="Demucs re-separation passes (0 = off)")
    parser.add_argument("--gate", type=int, default=1, choices=[0, 1])
    parser.add_argument("--gate-threshold", type=float, default=0.5,
                        help="VAD speech probability threshold (0.1–0.9)")
    parser.add_argument("--gate-pad-ms", type=float, default=150.0,
                        help="keep this much audio either side of detected voice")
    parser.add_argument("--gate-fade-ms", type=float, default=40.0)
    parser.add_argument("--denoise", type=float, default=0.5,
                        help="spectral denoise amount 0–1 (0 = off)")
    parser.add_argument("--device", default="mps")
    return parser.parse_args(argv)


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


# ---------------------------------------------------------------------------
# WAV I/O

def read_wav(path: str):
    """Minimal RIFF/WAV reader → (torch.FloatTensor [channels, samples], sr).

    Handles the float32 WAV `AudioConverter` hands us, plus int16/int24/int32
    PCM so the module is also usable standalone on stems from elsewhere.
    torchaudio.load is deliberately avoided: its backend availability varies
    by build, and `soundfile` isn't in the engine's dependency set.
    """
    import numpy as np
    import torch

    with open(path, "rb") as f:
        if f.read(4) != b"RIFF":
            raise ValueError("not a RIFF/WAV file")
        f.read(4)
        if f.read(4) != b"WAVE":
            raise ValueError("not a WAVE file")

        fmt_tag = channels = sample_rate = bits = None
        data = None
        while True:
            header = f.read(8)
            if len(header) < 8:
                break
            chunk_id, chunk_size = struct.unpack("<4sI", header)
            chunk_data = f.read(chunk_size)
            if chunk_size % 2 == 1:
                f.read(1)
            if chunk_id == b"fmt ":
                fmt_tag, channels, sample_rate, _, _, bits = struct.unpack("<HHIIHH", chunk_data[:16])
                # WAVE_FORMAT_EXTENSIBLE: real tag lives in the sub-format GUID.
                if fmt_tag == 0xFFFE and len(chunk_data) >= 26:
                    fmt_tag = struct.unpack("<H", chunk_data[24:26])[0]
            elif chunk_id == b"data" and data is None:
                data = chunk_data

    if data is None or fmt_tag is None:
        raise ValueError("missing fmt/data chunk")

    if fmt_tag == 3 and bits == 32:
        samples = np.frombuffer(data, dtype="<f4").astype(np.float32)
    elif fmt_tag == 1 and bits == 16:
        samples = np.frombuffer(data, dtype="<i2").astype(np.float32) / 32768.0
    elif fmt_tag == 1 and bits == 32:
        samples = np.frombuffer(data, dtype="<i4").astype(np.float32) / 2147483648.0
    elif fmt_tag == 1 and bits == 24:
        raw = np.frombuffer(data, dtype=np.uint8)
        raw = raw[: len(raw) - len(raw) % 3].reshape(-1, 3)
        ints = (raw[:, 0].astype(np.int32)
                | (raw[:, 1].astype(np.int32) << 8)
                | (raw[:, 2].astype(np.int32) << 16))
        ints = np.where(ints & 0x800000, ints - 0x1000000, ints)
        samples = ints.astype(np.float32) / 8388608.0
    else:
        raise ValueError(f"unsupported WAV format tag={fmt_tag} bits={bits}")

    frames = len(samples) // channels
    wav = torch.from_numpy(samples[: frames * channels].reshape(frames, channels).T.copy())
    return wav, sample_rate


def write_wav(wav, path: str, sample_rate: int) -> None:
    from demucs.api import save_audio

    # clip="none": never rescale — the caller has already clamped to ±1 and
    # a gain change here would violate SPEC.md §7 (no normalization).
    save_audio(wav.cpu(), path, samplerate=sample_rate, clip="none", as_float=True, bits_per_sample=32)


# ---------------------------------------------------------------------------
# Stage 1: re-separation

def reseparate(wav, sample_rate: int, passes: int, device: str, progress) -> "torch.Tensor":
    """Runs `wav` through Demucs `passes` times, keeping only the vocals stem.

    `progress(fraction)` is called with 0–1 across all passes combined.
    """
    import tqdm

    _orig_tqdm_init = tqdm.tqdm.__init__

    def _quiet_tqdm_init(self, *a, **kw):
        kw["disable"] = True
        return _orig_tqdm_init(self, *a, **kw)

    tqdm.tqdm.__init__ = _quiet_tqdm_init

    from demucs.api import Separator

    # See __main__.py: htdemucs_ft is a bag of 4 models and demucs reports
    # per-model progress, so track the resets to keep the bar monotonic.
    state = {"pass": 0, "completed": 0, "last": 0.0, "last_emit": 0.0}
    bag_count = [1]

    def _callback(info: dict) -> None:
        audio_length = info.get("audio_length")
        segment_offset = info.get("segment_offset")
        if not audio_length:
            return
        raw = max(0.0, min(1.0, segment_offset / audio_length))
        if bag_count[0] > 1 and raw + 0.01 < state["last"]:
            state["completed"] = min(state["completed"] + 1, bag_count[0] - 1)
        state["last"] = raw
        within_pass = (state["completed"] + raw) / bag_count[0]
        now = time.monotonic()
        if now - state["last_emit"] >= 0.5:
            state["last_emit"] = now
            progress((state["pass"] + within_pass) / passes)

    separator = Separator(model=_RESEPARATE_MODEL, device=device, callback=_callback)
    _keep_only_vocals_model(separator)
    bag = getattr(getattr(separator, "model", None), "models", None)
    if bag:
        bag_count[0] = max(1, len(bag))

    current = wav
    for i in range(passes):
        state.update(pass_=None, completed=0, last=0.0)
        state["pass"] = i
        _log(f"re-separation pass {i + 1}/{passes} model={_RESEPARATE_MODEL} device={device}")
        _, separated = separator.separate_tensor(current, sample_rate)
        current = separated["vocals"].to("cpu")
        # Demucs may resample internally; keep the caller's rate and length.
        if separator.samplerate != sample_rate:
            import torchaudio.functional as F

            current = F.resample(current, separator.samplerate, sample_rate)
        current = _match_length(current, wav.shape[-1])
        progress((i + 1) / passes)
    return current


def _keep_only_vocals_model(separator) -> None:
    """htdemucs_ft is a bag of four per-stem fine-tunes with identity weights
    (verified 2026-09-20: weights[i][j] = 1 iff i == j), so the vocals output
    comes entirely from one sub-model. Dropping the other three gives a
    bit-identical vocals stem in a quarter of the time.
    """
    from demucs.apply import BagOfModels

    bag = getattr(separator, "_model", None) or getattr(separator, "model", None)
    if not isinstance(bag, BagOfModels) or "vocals" not in bag.sources:
        return
    vi = bag.sources.index("vocals")
    kept = [(m, w) for m, w in zip(bag.models, bag.weights) if w[vi] > 0]
    if not kept or len(kept) == len(bag.models):
        return
    trimmed = BagOfModels([m for m, _ in kept], weights=[w for _, w in kept],
                          segment=getattr(bag, "segment", None))
    if hasattr(separator, "_model"):
        separator._model = trimmed
    else:
        separator.model = trimmed
    _log(f"re-separation: using {len(kept)} of {len(bag.models)} bag models (vocals only)")


def _match_length(x, n: int):
    import torch

    if x.shape[-1] == n:
        return x
    if x.shape[-1] > n:
        return x[..., :n]
    return torch.nn.functional.pad(x, (0, n - x.shape[-1]))


# ---------------------------------------------------------------------------
# Stage 2: VAD gate

def vad_speech_probs(wav, sample_rate: int, progress=None, lanes: int = 8):
    """Silero VAD speech probability per 32 ms frame (mono mixdown).

    The model is stateful (LSTM) so chunks must go in order, but each batch
    row carries its own state — so the audio is cut into `lanes` equal
    segments and chunk i of every segment goes through in one batched call.
    ~8× fewer calls than a single sequential pass; the only cost is one
    chunk of lost context at each segment seam.
    """
    import torch
    import torchaudio.functional as F

    model = torch.jit.load(_VAD_MODEL_PATH, map_location="cpu")
    model.eval()
    model.reset_states()

    mono = wav.mean(dim=0).to("cpu")
    if sample_rate != _VAD_SAMPLE_RATE:
        mono = F.resample(mono, sample_rate, _VAD_SAMPLE_RATE)
    n = mono.shape[-1]
    n_frames = (n + _VAD_CHUNK - 1) // _VAD_CHUNK
    lanes = max(1, min(lanes, n_frames))
    per_lane = (n_frames + lanes - 1) // lanes
    padded = torch.nn.functional.pad(mono, (0, lanes * per_lane * _VAD_CHUNK - n))
    lanes_view = padded.view(lanes, per_lane, _VAD_CHUNK)

    probs = torch.empty(lanes, per_lane)
    with torch.no_grad():
        for i in range(per_lane):
            probs[:, i] = model(lanes_view[:, i, :], _VAD_SAMPLE_RATE).view(-1)
            if progress and i % 50 == 0:
                progress(i / per_lane)
    return probs.reshape(-1)[:n_frames]


def frame_levels_db(wav, n_frames: int):
    """RMS level in dBFS of the mono mixdown, one value per VAD frame."""
    import torch

    mono = wav.mean(dim=0).to("cpu")
    hop = max(1, mono.shape[-1] // n_frames)
    usable = mono[: n_frames * hop]
    if usable.shape[-1] < n_frames * hop:
        usable = torch.nn.functional.pad(usable, (0, n_frames * hop - usable.shape[-1]))
    rms = usable.view(n_frames, hop).pow(2).mean(dim=1).sqrt()
    return 20.0 * torch.log10(rms + 1e-9)


def voiced_frames(probs, levels_db, threshold: float, level_margin_db: float = _LEVEL_MARGIN_DB):
    """Hybrid voice decision: VAD says voice, OR the frame is loud enough.

    Silero is a *speech* detector; on sung vocals it under-fires on sustained
    notes (measured 2026-09-20 on a pop stem: at 0.5 it dropped 60% of the
    frames above −30 dBFS). In a Demucs vocal stem anything within
    `level_margin_db` of the confident-voice level is voice — residue sits
    far below — so those frames are kept regardless of the VAD. With the
    18 dB default that kept 0% of loud frames from being cut while still
    gating 98.6% of frames under −45 dBFS on the same stem.
    """
    by_vad = probs >= threshold
    confident = probs >= max(threshold, 0.5)
    if not bool(confident.any()):
        return by_vad
    voice_level = float(levels_db[confident].median())
    return by_vad | (levels_db >= voice_level - level_margin_db)


def gate_envelope(voiced, n_samples: int, sample_rate: int, pad_ms: float, fade_ms: float):
    """Turns a per-frame voiced mask into a 0–1 sample envelope.

    Each voiced region is widened by `pad_ms` on both sides (which also
    closes any gap shorter than 2×pad), then the step envelope is smoothed
    with a `fade_ms` moving average so the gate ramps instead of clicking.
    """
    import torch

    voiced = voiced.float()
    frame_ms = 1000.0 * _VAD_CHUNK / _VAD_SAMPLE_RATE
    pad_frames = int(round(pad_ms / frame_ms))
    if pad_frames > 0 and voiced.numel() > 0:
        voiced = torch.nn.functional.max_pool1d(
            voiced.view(1, 1, -1), kernel_size=2 * pad_frames + 1, stride=1, padding=pad_frames
        ).view(-1)

    # Frame mask → per-sample step envelope at the output rate.
    env = torch.nn.functional.interpolate(
        voiced.view(1, 1, -1), size=n_samples, mode="nearest"
    ).view(-1)

    # Moving average via cumulative sum (a conv1d with a ~1800-tap kernel
    # over 15M samples took ~70 s; this is O(n)).
    fade_len = int(round(fade_ms / 1000.0 * sample_rate))
    if fade_len > 1:
        left = fade_len // 2
        right = fade_len - 1 - left
        padded = torch.cat([env[:1].expand(left), env, env[-1:].expand(right)])
        csum = torch.cat([torch.zeros(1), padded.cumsum(0)])
        env = (csum[fade_len:] - csum[:-fade_len]) / fade_len
    return env.clamp(0.0, 1.0)


def apply_gate(wav, sample_rate: int, threshold: float, pad_ms: float, fade_ms: float, progress=None):
    probs = vad_speech_probs(wav, sample_rate, progress=progress)
    levels = frame_levels_db(wav, probs.numel())
    voiced = voiced_frames(probs, levels, threshold)
    vad_pct = 100.0 * float((probs >= threshold).float().mean()) if probs.numel() else 0.0
    voiced_pct = 100.0 * float(voiced.float().mean()) if voiced.numel() else 0.0
    _log(f"gate: VAD {vad_pct:.1f}% / VAD+level {voiced_pct:.1f}% of frames voiced at threshold {threshold:.2f}")
    if voiced_pct == 0.0:
        # No voice found anywhere (instrumental, or threshold far too high):
        # silencing the whole file would be worse than leaving it alone.
        _log("gate: no voiced frames — gate skipped, audio left unchanged")
        return wav, None
    env = gate_envelope(voiced, wav.shape[-1], sample_rate, pad_ms, fade_ms)
    return wav * env.unsqueeze(0), env


# ---------------------------------------------------------------------------
# Stage 3: spectral denoise

def spectral_denoise(wav, amount: float, active_env=None, n_fft: int = 2048, hop: int = 512):
    """Soft spectral gate. `amount` 0–1 scales how far below-floor bins are
    pulled down (1 = fully removed, 0.5 = −6 dB).

    Noise floor per frequency bin = 20th percentile of that bin's magnitude
    over *active* frames (frames the gate left open, if a gate envelope is
    given — otherwise all non-silent frames), so the silence the gate just
    created doesn't drag the floor estimate to zero. Bins within 3 dB of the
    floor are treated as bed and attenuated; bins 9 dB or more above it are
    untouched; the mask is smoothed a little across time and frequency to
    avoid musical-noise flutter.
    """
    import torch

    n = wav.shape[-1]
    window = torch.hann_window(n_fft)
    out = torch.empty_like(wav)
    eps = 1e-8

    for c in range(wav.shape[0]):
        spec = torch.stft(wav[c], n_fft=n_fft, hop_length=hop, window=window,
                          center=True, return_complex=True)          # [F, T]
        mag = spec.abs()
        mag_db = 20.0 * torch.log10(mag + eps)

        frame_energy = mag.pow(2).sum(dim=0)
        if active_env is not None:
            frame_open = torch.nn.functional.interpolate(
                active_env.view(1, 1, -1), size=mag.shape[1], mode="nearest").view(-1) > 0.5
        else:
            frame_open = torch.ones_like(frame_energy, dtype=torch.bool)
        active = frame_open & (frame_energy > eps)
        if int(active.sum()) < 4:
            out[c] = wav[c]
            continue

        floor_db = torch.quantile(mag_db[:, active], 0.2, dim=1, keepdim=True)  # [F, 1]

        # 0 at ≤ +3 dB above floor, 1 at ≥ +9 dB above floor, linear between.
        mask = ((mag_db - floor_db - 3.0) / 6.0).clamp(0.0, 1.0)
        mask = torch.nn.functional.avg_pool2d(
            mask.view(1, 1, *mask.shape), kernel_size=(5, 3), stride=1, padding=(2, 1)
        ).view(*mask.shape)

        gain = 1.0 - amount * (1.0 - mask)
        cleaned = torch.istft(spec * gain, n_fft=n_fft, hop_length=hop, window=window,
                              center=True, length=n)
        out[c] = cleaned
    return out


# ---------------------------------------------------------------------------

def _stage_weights(reseparate: int, gate: bool, denoise: float):
    """Progress share per enabled stage (re-separation dominates the time)."""
    weights = []
    if reseparate > 0:
        weights.append(("reseparate", 0.8))
    if gate:
        weights.append(("gate", 0.12))
    if denoise > 0:
        weights.append(("denoise", 0.08))
    total = sum(w for _, w in weights) or 1.0
    return [(name, w / total) for name, w in weights]


def main(argv=None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)
    try:
        import torch

        torch.set_grad_enabled(False)
        device = _resolve_device(args.device)

        _emit({"event": "loading"})

        wav, sample_rate = read_wav(args.input)
        n_samples = wav.shape[-1]
        _log(f"input {wav.shape[0]}ch {n_samples} frames @ {sample_rate} Hz; "
             f"reseparate={args.reseparate} gate={args.gate} thr={args.gate_threshold} "
             f"denoise={args.denoise}")

        stages = _stage_weights(args.reseparate, bool(args.gate), args.denoise)
        done_before = 0.0
        last_emit = [0.0]

        def _stage_progress(weight):
            def cb(fraction: float) -> None:
                now = time.monotonic()
                if now - last_emit[0] >= 0.5 or fraction >= 1.0:
                    last_emit[0] = now
                    overall = done_before + weight * max(0.0, min(1.0, fraction))
                    _emit({"event": "progress", "fraction": max(0.0, min(1.0, overall))})
            return cb

        env = None
        for name, weight in stages:
            cb = _stage_progress(weight)
            if name == "reseparate":
                wav = reseparate(wav, sample_rate, args.reseparate, device, cb)
            elif name == "gate":
                wav, env = apply_gate(wav, sample_rate, args.gate_threshold,
                                      args.gate_pad_ms, args.gate_fade_ms, progress=cb)
            elif name == "denoise":
                wav = spectral_denoise(wav, max(0.0, min(1.0, args.denoise)), active_env=env)
            done_before += weight
            _emit({"event": "progress", "fraction": min(1.0, done_before)})

        wav = _match_length(wav, n_samples).clamp(-1.0, 1.0)

        os.makedirs(args.out, exist_ok=True)
        out_path = os.path.join(args.out, "vocals.wav")
        write_wav(wav, out_path, sample_rate)
        _emit({"event": "stem", "name": "vocals", "path": out_path})
        _emit({"event": "done"})
        return 0
    except Exception as exc:  # noqa: BLE001
        _emit({"event": "error", "message": str(exc)})
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
