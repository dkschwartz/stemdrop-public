"""Pre-download demucs model weights into HF_HOME.

Used by ModelManager to trigger the first-launch model download outside of a
separation job. Emits a single JSON line to stdout: either
{"event":"done"} on success or {"event":"error","message":...} on failure.
"""
import json
import os
import sys


def main() -> int:
    model_dir = os.environ.get("STEMDROP_MODEL_DIR")
    if model_dir:
        os.environ["HF_HOME"] = model_dir

    # Quality-first: pre-download both the fine-tuned 4-stem model (default)
    # and the six-stem model (used when guitar/piano is requested), so the
    # first real job never stalls on a download. Both are free/open weights.
    try:
        from demucs.pretrained import get_model

        get_model("htdemucs_ft")
        get_model("htdemucs_6s")
    except Exception as exc:  # noqa: BLE001
        print(json.dumps({"event": "error", "message": str(exc)}), flush=True)
        import traceback

        traceback.print_exc(file=sys.stderr)
        return 1

    print(json.dumps({"event": "done"}), flush=True)
    return 0


if __name__ == "__main__":
    sys.exit(main())
