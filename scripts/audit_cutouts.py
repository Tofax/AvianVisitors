#!/usr/bin/env python3
"""AvianVisitors - audit illustration cutouts for suspicious transparency.

This is the backend worker for avian/api/cutout-review.php.

It scans the final RGBA illustrations, scores likely bad cutouts, and writes
one atomic JSON snapshot consumed by the admin review UI. It can also render
one diagnostic preview on demand without changing the source PNG.

Examples:
    python3 avian/scripts/audit_cutouts.py
    python3 avian/scripts/audit_cutouts.py --dir avian/assets/illustrations
    python3 avian/scripts/audit_cutouts.py --preview charadrius-dubius-2.png \
        --preview-output /tmp/preview.png
"""
from __future__ import annotations

import argparse
import json
import os
import sys
import time
from pathlib import Path
from typing import Any

import numpy as np
from PIL import Image, ImageDraw, ImageFilter, ImageFont


HERE = Path(__file__).resolve().parent
DEFAULT_ILLUS = HERE.parent / "assets" / "illustrations"
DEFAULT_OUTPUT = DEFAULT_ILLUS / ".cutout-audit.json"
DEFAULT_STATE = DEFAULT_ILLUS / ".cutout-audit.state.json"

ALPHA_TRANSPARENT = 16
PARTIAL_ALPHA_MAX = 220
MIN_HOLE_PIXELS = 40
SCHEMA_VERSION = 1


def atomic_write_json(path: Path, data: Any) -> None:
    """Write JSON without ever exposing a partially-written state file."""
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}")
    try:
        tmp.write_text(
            json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n",
            encoding="utf-8",
        )
        os.chmod(tmp, 0o664)
        os.replace(tmp, path)
    finally:
        try:
            tmp.unlink()
        except FileNotFoundError:
            pass


def write_state(path: Path, **values: Any) -> None:
    values["at"] = int(time.time())
    values["schema"] = SCHEMA_VERSION
    try:
        atomic_write_json(path, values)
    except OSError:
        # The audit result is more important than progress reporting.
        pass


def flood_exterior(alpha: np.ndarray, alpha_transparent: int) -> tuple[np.ndarray, np.ndarray]:
    """Return exterior transparency and enclosed transparent holes."""
    h, w = alpha.shape
    transparent = alpha <= alpha_transparent

    # 128 = transparent candidate
    #   0 = foreground / non-transparent
    # 255 = confirmed exterior transparency
    mask = Image.fromarray(
        np.where(transparent, 128, 0).astype(np.uint8)
    ).copy()

    seeds: list[tuple[int, int]] = []
    step_x = max(1, w // 64)
    step_y = max(1, h // 64)

    for x in range(0, w, step_x):
        seeds.append((x, 0))
        seeds.append((x, h - 1))
    for y in range(0, h, step_y):
        seeds.append((0, y))
        seeds.append((w - 1, y))

    seeds.extend([
        (0, 0), (w - 1, 0),
        (0, h - 1), (w - 1, h - 1),
    ])

    for seed in seeds:
        if mask.getpixel(seed) == 128:
            ImageDraw.floodfill(mask, seed, 255)

    flooded = np.asarray(mask)
    return flooded == 255, flooded == 128


def filename_parts(path: Path) -> tuple[str, int]:
    stem = path.stem
    if stem.endswith("-2"):
        return stem[:-2], 2
    return stem, 1


def score_level(score: float) -> str:
    if score >= 70:
        return "very_high"
    if score >= 40:
        return "high"
    if score >= 20:
        return "medium"
    if score >= 8:
        return "low"
    return "very_low"


def analyze_image(
    path: Path,
    raw_dir: Path,
    alpha_transparent: int = ALPHA_TRANSPARENT,
    partial_alpha_max: int = PARTIAL_ALPHA_MAX,
    min_hole_pixels: int = MIN_HOLE_PIXELS,
) -> tuple[dict[str, Any], np.ndarray]:
    with Image.open(path) as source:
        im = source.convert("RGBA")
    alpha = np.asarray(im.getchannel("A"))
    h, w = alpha.shape
    total = h * w

    _exterior, holes = flood_exterior(alpha, alpha_transparent)
    hole_pixels = int(holes.sum())

    opaque_pixels = int((alpha >= 250).sum())
    foreground_reference = opaque_pixels + hole_pixels
    hole_pct_foreground = (
        100.0 * hole_pixels / foreground_reference
        if foreground_reference else 0.0
    )

    partial = (alpha > alpha_transparent) & (alpha < partial_alpha_max)
    partial_pixels = int(partial.sum())
    partial_pct_total = 100.0 * partial_pixels / total if total else 0.0

    transparent_pixels = int((alpha <= alpha_transparent).sum())
    transparent_pct_total = 100.0 * transparent_pixels / total if total else 0.0
    opaque_pct_total = 100.0 * opaque_pixels / total if total else 0.0

    # Same heuristic validated by the workstation audit. Internal holes are
    # weighted most strongly; broad partial alpha is the secondary signal.
    hole_score = min(70.0, hole_pct_foreground * 8.0)
    partial_score = min(30.0, partial_pct_total * 3.0)
    score = hole_score + partial_score

    if hole_pixels >= min_hole_pixels:
        score += 8.0
    if hole_pct_foreground >= 0.5:
        score += 8.0
    if partial_pct_total >= 2.0:
        score += 6.0
    if partial_pct_total >= 10.0:
        score += 8.0

    score = min(100.0, score)
    suspicious = (
        hole_pixels >= min_hole_pixels
        or hole_pct_foreground >= 0.5
        or partial_pct_total >= 2.0
    )

    species_slug, pose = filename_parts(path)
    raw_path = raw_dir / path.name

    result = {
        "file": path.name,
        "slug": species_slug,
        "pose": pose,
        "score": round(score, 3),
        "level": score_level(score),
        "suspicious": suspicious,
        "hole_pixels": hole_pixels,
        "hole_pct": round(hole_pct_foreground, 4),
        "partial_pixels": partial_pixels,
        "partial_pct": round(partial_pct_total, 4),
        "transparent_pct": round(transparent_pct_total, 4),
        "opaque_pct": round(opaque_pct_total, 4),
        "width": w,
        "height": h,
        "has_raw": raw_path.is_file(),
        "mtime": int(path.stat().st_mtime),
    }
    return result, holes


def run_audit(root: Path, output: Path, state: Path) -> int:
    if not root.is_dir():
        write_state(state, running=False, ok=False, error=f"illustration directory not found: {root}")
        print(f"error: illustration directory not found: {root}", file=sys.stderr)
        return 2

    paths = sorted(p for p in root.glob("*.png") if p.is_file())
    if not paths:
        write_state(state, running=False, ok=False, error="no PNG illustrations found")
        print("error: no PNG illustrations found", file=sys.stderr)
        return 2

    raw_dir = root / "raw"
    started = int(time.time())
    write_state(state, running=True, ok=None, done=0, total=len(paths), started_at=started)

    items: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []

    for index, path in enumerate(paths, 1):
        try:
            result, _holes = analyze_image(path, raw_dir)
            items.append(result)
        except Exception as exc:
            errors.append({"file": path.name, "error": str(exc)})

        if index == 1 or index % 25 == 0 or index == len(paths):
            write_state(
                state,
                running=True,
                ok=None,
                done=index,
                total=len(paths),
                started_at=started,
            )

    items.sort(
        key=lambda r: (
            r["score"],
            r["hole_pct"],
            r["partial_pct"],
            r["hole_pixels"],
            r["file"],
        ),
        reverse=True,
    )

    level_counts = {key: 0 for key in ("very_high", "high", "medium", "low", "very_low")}
    suspicious_count = 0
    for item in items:
        level_counts[item["level"]] += 1
        if item["suspicious"]:
            suspicious_count += 1

    document = {
        "schema": SCHEMA_VERSION,
        "generated_at": int(time.time()),
        "root": str(root.resolve()),
        "total": len(paths),
        "analyzed": len(items),
        "errors": errors,
        "summary": {
            "suspicious": suspicious_count,
            "levels": level_counts,
        },
        "items": items,
    }

    try:
        atomic_write_json(output, document)
    except OSError as exc:
        write_state(state, running=False, ok=False, error=f"cannot write audit: {exc}")
        print(f"error: cannot write audit: {exc}", file=sys.stderr)
        return 1

    write_state(
        state,
        running=False,
        ok=True,
        done=len(paths),
        total=len(paths),
        started_at=started,
        finished_at=int(time.time()),
        errors=len(errors),
    )

    print(
        f"audited {len(items)}/{len(paths)} illustrations; "
        f"{suspicious_count} suspicious; {len(errors)} errors"
    )
    return 0


def dilate_binary(mask: np.ndarray, radius: int = 3) -> np.ndarray:
    if not mask.any():
        return mask.copy()
    img = Image.fromarray(mask.astype(np.uint8) * 255)
    img = img.filter(ImageFilter.MaxFilter(radius * 2 + 1))
    return np.asarray(img) > 127


def render_preview(root: Path, filename: str, output: Path, preview_size: int = 1100) -> int:
    # The PHP endpoint validates too, but keep the worker safe when invoked by hand.
    if not filename or Path(filename).name != filename:
        print("error: invalid filename", file=sys.stderr)
        return 2

    src = root / filename
    if not src.is_file():
        print(f"error: illustration not found: {filename}", file=sys.stderr)
        return 2

    result, holes = analyze_image(src, root / "raw")

    with Image.open(src) as source:
        original = source.convert("RGBA")

    ow, oh = original.size
    header_h = 112
    margin = 28
    canvas_w = preview_size
    canvas_h = preview_size + header_h

    # Strong background: transparency becomes immediately visible.
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (20, 205, 190, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((0, 0, canvas_w, header_h), fill=(245, 242, 234, 255))

    available_w = canvas_w - margin * 2
    available_h = canvas_h - header_h - margin * 2
    scale = min(available_w / ow, available_h / oh)
    nw = max(1, round(ow * scale))
    nh = max(1, round(oh * scale))
    bird = original.resize((nw, nh), Image.Resampling.LANCZOS)

    x0 = (canvas_w - nw) // 2
    y0 = header_h + (available_h - nh) // 2 + margin
    canvas.alpha_composite(bird, (x0, y0))

    hole_img = Image.fromarray(holes.astype(np.uint8) * 255)
    hole_img = hole_img.resize((nw, nh), Image.Resampling.NEAREST)
    hole_mask = np.asarray(hole_img) > 127
    outline_mask = dilate_binary(hole_mask, radius=3) & ~hole_mask

    overlay = np.zeros((nh, nw, 4), dtype=np.uint8)
    overlay[outline_mask] = (255, 230, 0, 235)
    overlay[hole_mask] = (255, 30, 30, 220)
    canvas.alpha_composite(Image.fromarray(overlay, "RGBA"), (x0, y0))

    font = ImageFont.load_default()
    title = result["file"]
    metrics = (
        f"score {result['score']:.2f} | {result['level']} | "
        f"forat {result['hole_pct']:.3f}% ({result['hole_pixels']} px) | "
        f"alpha parcial {result['partial_pct']:.3f}%"
    )
    draw.text((22, 24), title, fill=(30, 30, 30, 255), font=font)
    draw.text((22, 58), metrics, fill=(70, 70, 70, 255), font=font)

    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output, format="PNG")
    return 0


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path, default=DEFAULT_ILLUS)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--state", type=Path, default=DEFAULT_STATE)
    ap.add_argument("--preview", metavar="FILE")
    ap.add_argument("--preview-output", type=Path)
    args = ap.parse_args()

    root = args.dir.resolve()

    if args.preview is not None:
        if args.preview_output is None:
            ap.error("--preview requires --preview-output")
        return render_preview(root, args.preview, args.preview_output)

    return run_audit(root, args.output, args.state)


if __name__ == "__main__":
    raise SystemExit(main())
