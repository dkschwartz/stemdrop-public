"""320 kbps CBR MP3 encoder (SPEC.md §13).

Invoked as: python3 -m stemdrop_engine.encode_mp3 --input <wav> --output <mp3>
    --bitrate 320

Reads a float32 or int16 PCM WAV (whatever `AudioExporter` hands it) and
encodes it with `lameenc`. Emits exactly one JSON line on stdout:
    {"event":"done"}
    {"event":"error","message":"…"}   (also exits non-zero)

Nothing else may go to stdout. Diagnostics/tracebacks go to stderr.
"""
import argparse
import json
import struct
import sys


def _emit(obj: dict) -> None:
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()


def _read_wav_manually(path: str):
    """Minimal RIFF/WAV parser: returns (int16 interleaved PCM bytes,
    channel count, sample rate). Handles 16-bit int PCM (format tag 1) and
    32-bit float PCM (format tag 3, what `AVAudioFile`/demucs write), since
    the stdlib `wave` module only understands PCM int and `soundfile` is
    not part of this engine's dependency set.
    """
    import numpy as np

    with open(path, "rb") as f:
        if f.read(4) != b"RIFF":
            raise ValueError("not a RIFF/WAV file")
        f.read(4)  # overall size, unused — we trust the data chunk size
        if f.read(4) != b"WAVE":
            raise ValueError("not a WAVE file")

        fmt_tag = None
        channels = None
        sample_rate = None
        bits_per_sample = None
        data = None

        while True:
            header = f.read(8)
            if len(header) < 8:
                break
            chunk_id, chunk_size = struct.unpack("<4sI", header)
            chunk_data = f.read(chunk_size)
            if chunk_size % 2 == 1:
                f.read(1)  # skip pad byte
            if chunk_id == b"fmt ":
                fmt_tag, channels, sample_rate, _, _, bits_per_sample = struct.unpack(
                    "<HHIIHH", chunk_data[:16]
                )
            elif chunk_id == b"data" and data is None:
                data = chunk_data

        if data is None or fmt_tag is None:
            raise ValueError("missing fmt/data chunk")

        if fmt_tag == 1 and bits_per_sample == 16:
            pcm16 = data
        elif fmt_tag == 3 and bits_per_sample == 32:
            floats = np.frombuffer(data, dtype="<f4")
            clipped = np.clip(floats, -1.0, 1.0)
            pcm16 = (clipped * 32767.0).astype("<i2").tobytes()
        elif fmt_tag == 1 and bits_per_sample == 32:
            ints = np.frombuffer(data, dtype="<i4")
            pcm16 = (ints >> 16).astype("<i2").tobytes()
        else:
            raise ValueError(f"unsupported WAV format tag={fmt_tag} bits={bits_per_sample}")

        return pcm16, channels, sample_rate


def _read_audio(path: str):
    """Prefers `soundfile` if it's ever added as a dependency; otherwise
    falls back to the manual WAV parser above (numpy is already a demucs
    dependency, so this needs no extra install)."""
    try:
        import soundfile as sf

        data, sample_rate = sf.read(path, dtype="int16", always_2d=True)
        channels = data.shape[1]
        return data.tobytes(), channels, sample_rate
    except ImportError:
        return _read_wav_manually(path)


def _parse_args(argv):
    parser = argparse.ArgumentParser(prog="stemdrop_engine.encode_mp3")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--bitrate", type=int, default=320)
    return parser.parse_args(argv)


def main(argv=None) -> int:
    args = _parse_args(sys.argv[1:] if argv is None else argv)

    try:
        import lameenc

        pcm16_bytes, channels, sample_rate = _read_audio(args.input)

        encoder = lameenc.Encoder()
        encoder.set_bit_rate(args.bitrate)
        encoder.set_in_sample_rate(sample_rate)
        encoder.set_channels(channels)
        encoder.set_quality(2)  # 2 = high quality (0 best/slowest .. 9 worst/fastest)
        encoder.set_vbr(lameenc.VBR_OFF)  # 320 kbps CBR per SPEC.md §13

        mp3_data = encoder.encode(pcm16_bytes)
        mp3_data += encoder.flush()

        with open(args.output, "wb") as out_file:
            out_file.write(mp3_data)

        _emit({"event": "done"})
        return 0
    except Exception as exc:  # noqa: BLE001
        _emit({"event": "error", "message": str(exc)})
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
