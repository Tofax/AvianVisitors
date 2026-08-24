#!/usr/bin/env python3
"""AvianVisitors - audit and repair illustration cutouts.

Backend worker for avian/api/cutout-review.php.

Modes:
  (default)          audit every final PNG and write .cutout-audit.json
  --preview FILE     render one diagnostic preview without changing artwork
  --refresh FILE     re-audit one final PNG and update the audit snapshot
  --recut FILE       rebuild one final PNG from illustrations/raw/ with the
                     current chroma_cut(), refresh masks, then refresh audit
"""
from __future__ import annotations

import argparse
import fcntl
import json
import os
import subprocess
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
DEFAULT_AUDIT_LOCK = DEFAULT_ILLUS / ".cutout-audit.lock"
GENERATION_LOCK = Path(os.environ.get("AVIAN_GENERATION_LOCK", "/run/lock/avian-generation.lock"))

ALPHA_TRANSPARENT = 16
PARTIAL_ALPHA_MAX = 220
MIN_HOLE_PIXELS = 40
SCHEMA_VERSION = 1


def atomic_write_json(path: Path, data: Any) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_name(f".{path.name}.tmp.{os.getpid()}.{time.time_ns()}")
    try:
        tmp.write_text(json.dumps(data, ensure_ascii=False, separators=(",", ":")) + "\n", encoding="utf-8")
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
        pass


def flood_exterior(alpha: np.ndarray, alpha_transparent: int) -> tuple[np.ndarray, np.ndarray]:
    h, w = alpha.shape
    transparent = alpha <= alpha_transparent
    mask = Image.fromarray(np.where(transparent, 128, 0).astype(np.uint8)).copy()
    seeds: list[tuple[int, int]] = []
    step_x = max(1, w // 64)
    step_y = max(1, h // 64)
    for x in range(0, w, step_x):
        seeds.extend(((x, 0), (x, h - 1)))
    for y in range(0, h, step_y):
        seeds.extend(((0, y), (w - 1, y)))
    seeds.extend(((0, 0), (w - 1, 0), (0, h - 1), (w - 1, h - 1)))
    for seed in seeds:
        if mask.getpixel(seed) == 128:
            ImageDraw.floodfill(mask, seed, 255)
    flooded = np.asarray(mask)
    return flooded == 255, flooded == 128


def filename_parts(path: Path) -> tuple[str, int]:
    stem = path.stem
    return (stem[:-2], 2) if stem.endswith("-2") else (stem, 1)


def valid_filename(filename: str) -> bool:
    if not filename or Path(filename).name != filename or not filename.endswith(".png"):
        return False
    stem = filename[:-4]
    parts = stem.split("-")
    if parts and parts[-1] == "2":
        parts = parts[:-1]
    return len(parts) >= 2 and all(part and part.isalnum() and part.lower() == part for part in parts)


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


def analyze_image(path: Path, raw_dir: Path,
                  alpha_transparent: int = ALPHA_TRANSPARENT,
                  partial_alpha_max: int = PARTIAL_ALPHA_MAX,
                  min_hole_pixels: int = MIN_HOLE_PIXELS) -> tuple[dict[str, Any], np.ndarray]:
    with Image.open(path) as source:
        im = source.convert("RGBA")
    alpha = np.asarray(im.getchannel("A"))
    h, w = alpha.shape
    total = h * w
    _exterior, holes = flood_exterior(alpha, alpha_transparent)
    hole_pixels = int(holes.sum())
    opaque_pixels = int((alpha >= 250).sum())
    foreground_reference = opaque_pixels + hole_pixels
    hole_pct_foreground = 100.0 * hole_pixels / foreground_reference if foreground_reference else 0.0
    partial = (alpha > alpha_transparent) & (alpha < partial_alpha_max)
    partial_pixels = int(partial.sum())
    partial_pct_total = 100.0 * partial_pixels / total if total else 0.0
    transparent_pixels = int((alpha <= alpha_transparent).sum())
    transparent_pct_total = 100.0 * transparent_pixels / total if total else 0.0
    opaque_pct_total = 100.0 * opaque_pixels / total if total else 0.0

    score = min(70.0, hole_pct_foreground * 8.0) + min(30.0, partial_pct_total * 3.0)
    if hole_pixels >= min_hole_pixels:
        score += 8.0
    if hole_pct_foreground >= 0.5:
        score += 8.0
    if partial_pct_total >= 2.0:
        score += 6.0
    if partial_pct_total >= 10.0:
        score += 8.0
    score = min(100.0, score)
    suspicious = hole_pixels >= min_hole_pixels or hole_pct_foreground >= 0.5 or partial_pct_total >= 2.0

    species_slug, pose = filename_parts(path)
    result = {
        "file": path.name,
        "slug": species_slug,
        "pose": pose,
        "score": round(score, 3),
        "level": score_level(score),
        "suspicious": suspicious,
        "review_candidate": score >= 40.0,
        "very_likely_bad": score >= 70.0,
        "hole_pixels": hole_pixels,
        "hole_pct": round(hole_pct_foreground, 4),
        "partial_pixels": partial_pixels,
        "partial_pct": round(partial_pct_total, 4),
        "transparent_pct": round(transparent_pct_total, 4),
        "opaque_pct": round(opaque_pct_total, 4),
        "width": w,
        "height": h,
        "has_raw": (raw_dir / path.name).is_file(),
        "mtime": int(path.stat().st_mtime),
    }
    return result, holes


def summary_for(items: list[dict[str, Any]]) -> dict[str, Any]:
    levels = {key: 0 for key in ("very_high", "high", "medium", "low", "very_low")}
    suspicious = candidates = very_likely = 0
    for item in items:
        level = item.get("level")
        if level in levels:
            levels[level] += 1
        suspicious += int(bool(item.get("suspicious")))
        candidates += int(bool(item.get("review_candidate")))
        very_likely += int(bool(item.get("very_likely_bad")))
    return {"suspicious": suspicious, "review_candidates": candidates,
            "very_likely_bad": very_likely, "levels": levels}


def sort_items(items: list[dict[str, Any]]) -> None:
    items.sort(key=lambda r: (r.get("score", 0), r.get("hole_pct", 0),
                              r.get("partial_pct", 0), r.get("hole_pixels", 0),
                              r.get("file", "")), reverse=True)


def audit_lock_path(output: Path) -> Path:
    return output.with_name(".cutout-audit.lock")


def write_snapshot(output: Path, document: dict[str, Any]) -> None:
    lock_path = audit_lock_path(output)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        atomic_write_json(output, document)


def update_snapshot_item(root: Path, output: Path, item: dict[str, Any]) -> None:
    lock_path = audit_lock_path(output)
    lock_path.parent.mkdir(parents=True, exist_ok=True)
    with lock_path.open("a+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        document: dict[str, Any] = {}
        if output.is_file():
            try:
                loaded = json.loads(output.read_text(encoding="utf-8"))
                if isinstance(loaded, dict):
                    document = loaded
            except (OSError, ValueError):
                document = {}
        items = [x for x in document.get("items", [])
                 if isinstance(x, dict) and x.get("file") != item["file"]]
        items.append(item)
        sort_items(items)
        document.update({
            "schema": SCHEMA_VERSION,
            "generated_at": int(time.time()),
            "root": str(root.resolve()),
            "total": len(items),
            "analyzed": len(items),
            "summary": summary_for(items),
            "items": items,
        })
        if not isinstance(document.get("errors"), list):
            document["errors"] = []
        atomic_write_json(output, document)


def inspect_and_update(root: Path, output: Path, filename: str) -> dict[str, Any]:
    if not valid_filename(filename):
        raise ValueError("invalid illustration filename")
    path = root / filename
    if not path.is_file():
        raise FileNotFoundError(f"illustration not found: {filename}")
    item, _holes = analyze_image(path, root / "raw")
    update_snapshot_item(root, output, item)
    return item


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

    started = int(time.time())
    write_state(state, running=True, ok=None, done=0, total=len(paths), started_at=started)
    items: list[dict[str, Any]] = []
    errors: list[dict[str, str]] = []
    for index, path in enumerate(paths, 1):
        try:
            result, _holes = analyze_image(path, root / "raw")
            items.append(result)
        except Exception as exc:
            errors.append({"file": path.name, "error": str(exc)})
        if index == 1 or index % 25 == 0 or index == len(paths):
            write_state(state, running=True, ok=None, done=index, total=len(paths), started_at=started)
    sort_items(items)
    document = {"schema": SCHEMA_VERSION, "generated_at": int(time.time()),
                "root": str(root.resolve()), "total": len(paths), "analyzed": len(items),
                "errors": errors, "summary": summary_for(items), "items": items}
    try:
        write_snapshot(output, document)
    except OSError as exc:
        write_state(state, running=False, ok=False, error=f"cannot write audit: {exc}")
        print(f"error: cannot write audit: {exc}", file=sys.stderr)
        return 1
    write_state(state, running=False, ok=True, done=len(paths), total=len(paths),
                started_at=started, finished_at=int(time.time()), errors=len(errors))
    print(f"audited {len(items)}/{len(paths)} illustrations; "
          f"{document['summary']['suspicious']} suspicious; {len(errors)} errors")
    return 0


def dilate_binary(mask: np.ndarray, radius: int = 3) -> np.ndarray:
    if not mask.any():
        return mask.copy()
    img = Image.fromarray(mask.astype(np.uint8) * 255).filter(ImageFilter.MaxFilter(radius * 2 + 1))
    return np.asarray(img) > 127


def render_preview(root: Path, filename: str, output: Path, preview_size: int = 1100) -> int:
    if not valid_filename(filename):
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
    header_h, margin = 112, 28
    canvas_w, canvas_h = preview_size, preview_size + header_h
    canvas = Image.new("RGBA", (canvas_w, canvas_h), (20, 205, 190, 255))
    draw = ImageDraw.Draw(canvas)
    draw.rectangle((0, 0, canvas_w, header_h), fill=(245, 242, 234, 255))
    available_w = canvas_w - margin * 2
    available_h = canvas_h - header_h - margin * 2
    scale = min(available_w / ow, available_h / oh)
    nw, nh = max(1, round(ow * scale)), max(1, round(oh * scale))
    bird = original.resize((nw, nh), Image.Resampling.LANCZOS)
    x0 = (canvas_w - nw) // 2
    y0 = header_h + (available_h - nh) // 2 + margin
    canvas.alpha_composite(bird, (x0, y0))
    hole_img = Image.fromarray(holes.astype(np.uint8) * 255).resize((nw, nh), Image.Resampling.NEAREST)
    hole_mask = np.asarray(hole_img) > 127
    outline_mask = dilate_binary(hole_mask, radius=3) & ~hole_mask
    overlay = np.zeros((nh, nw, 4), dtype=np.uint8)
    overlay[outline_mask] = (255, 230, 0, 235)
    overlay[hole_mask] = (255, 30, 30, 220)
    canvas.alpha_composite(Image.fromarray(overlay, "RGBA"), (x0, y0))
    font = ImageFont.load_default()
    draw.text((22, 24), result["file"], fill=(30, 30, 30, 255), font=font)
    metrics = (f"score {result['score']:.2f} | {result['level']} | "
               f"forat {result['hole_pct']:.3f}% ({result['hole_pixels']} px) | "
               f"alpha parcial {result['partial_pct']:.3f}%")
    draw.text((22, 58), metrics, fill=(70, 70, 70, 255), font=font)
    output.parent.mkdir(parents=True, exist_ok=True)
    canvas.convert("RGB").save(output, format="PNG")
    return 0


def recut_one(root: Path, output: Path, filename: str) -> dict[str, Any]:
    if not valid_filename(filename):
        raise ValueError("invalid illustration filename")
    raw = root / "raw" / filename
    dst = root / filename
    if not raw.is_file():
        raise FileNotFoundError(f"raw not found: {filename}")
    # Share the same lock as generate_one.py/updater: artwork and masks must be
    # observed as one consistent mutation.
    with GENERATION_LOCK.open("r+") as lock:
        fcntl.flock(lock.fileno(), fcntl.LOCK_EX)
        sys.path.insert(0, str(HERE))
        from generate_one import chroma_cut  # local import avoids Gemini work
        chroma_cut(raw, dst)
        slug = filename[:-4]
        proc = subprocess.run(
            [sys.executable, str(HERE / "build_masks.py"), "--add", slug],
            cwd=str(HERE.parent.parent), capture_output=True, text=True,
        )
        if proc.returncode != 0:
            detail = (proc.stderr or proc.stdout or "build_masks --add failed").strip()
            raise RuntimeError(detail)
    return inspect_and_update(root, output, filename)


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--dir", type=Path, default=DEFAULT_ILLUS)
    ap.add_argument("--output", type=Path, default=DEFAULT_OUTPUT)
    ap.add_argument("--state", type=Path, default=DEFAULT_STATE)
    modes = ap.add_mutually_exclusive_group()
    modes.add_argument("--preview", metavar="FILE")
    modes.add_argument("--refresh", metavar="FILE")
    modes.add_argument("--recut", metavar="FILE")
    ap.add_argument("--preview-output", type=Path)
    args = ap.parse_args()
    root = args.dir.resolve()
    try:
        if args.preview is not None:
            if args.preview_output is None:
                ap.error("--preview requires --preview-output")
            return render_preview(root, args.preview, args.preview_output)
        if args.refresh is not None:
            item = inspect_and_update(root, args.output, args.refresh)
            print(json.dumps({"ok": True, "item": item}, ensure_ascii=False))
            return 0
        if args.recut is not None:
            item = recut_one(root, args.output, args.recut)
            print(json.dumps({"ok": True, "item": item}, ensure_ascii=False))
            return 0
        return run_audit(root, args.output, args.state)
    except Exception as exc:
        print(json.dumps({"ok": False, "error": str(exc)}, ensure_ascii=False), file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
