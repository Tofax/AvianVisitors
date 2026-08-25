#!/usr/bin/env python3
"""AvianVisitors - generate one species' illustrations on the Pi itself.

The on-demand path behind the atlas "generate illustration" button
(avian/api/generate.php). Runs the same Gemini render pregen.py does,
then an instant chroma cutout instead of BiRefNet - the flood-fill
approach needs only Pillow + numpy, both already on a BirdNET-Pi,
where the ~1GB BiRefNet model does not fit.

The raw cream-ground render is kept in illustrations/raw/ so a later
workstation pass (avian/scripts/upgrade_cutouts.py) can re-cut it with
BiRefNet at full quality. Each instant cut is recorded in
illustrations/cuts.json ({slug: "chroma"}); the upgrade pass clears
entries as it replaces them, and the menu badge counts what's left.

Usage:
    GEMINI_API_KEY=... python3 generate_one.py --sci 'Calypte anna' --com "Anna's Hummingbird"
    ... --force        # re-render even if the illustration exists
"""
from __future__ import annotations
import argparse
import fcntl
import json
import os
import subprocess
import sys
import time
from collections import deque
from pathlib import Path

import numpy as np
from PIL import Image, ImageDraw, ImageFilter

HERE = Path(__file__).resolve().parent
sys.path.insert(0, str(HERE))
import pregen  # noqa: E402  (reuses gen_one + the reference machinery)

ILLUS = HERE.parent / "assets" / "illustrations"
RAW = ILLUS / "raw"
CUTS = ILLUS / "cuts.json"
STATE = ILLUS / ".generate.state.json"
GENERATION_LOCK = Path(os.environ.get(
    "AVIAN_GENERATION_LOCK", "/run/lock/avian-generation.lock"
))


def write_state(**kw) -> None:
    """Single-writer progress file for generate.php's status action."""
    kw["at"] = int(time.time())
    try:
        STATE.write_text(json.dumps(kw) + "\n")
    except OSError:
        pass


def chroma_cut(src: Path, dst: Path) -> None:
    """Instant cutout for a cream-ground render.

    Only paper connected to the image border becomes transparent.
    A conservative adaptive threshold plus a small connectivity barrier
    prevents the flood from leaking through pale or weakly inked parts of
    white birds.

    Small disconnected foreground islands caused by paper grain are removed
    after the flood. The final alpha is fully opaque in the bird interior and
    feathered only along the outer silhouette.
    """
    im = Image.open(src).convert("RGB")
    arr = np.asarray(im)

    h, w, _ = arr.shape

    # Diverses mostres del paper/fons. Això tolera millor gradients,
    # vinyetatge i petites variacions cromàtiques del render.
    patch = 20

    samples = [
        arr[:patch, :patch],                                      # cantonada SE? superior esquerra
        arr[:patch, -patch:],                                     # superior dreta
        arr[-patch:, :patch],                                     # inferior esquerra
        arr[-patch:, -patch:],                                    # inferior dreta

        arr[:patch, w // 2 - patch:w // 2 + patch],               # centre superior
        arr[-patch:, w // 2 - patch:w // 2 + patch],              # centre inferior
        arr[h // 2 - patch:h // 2 + patch, :patch],               # centre esquerra
        arr[h // 2 - patch:h // 2 + patch, -patch:],              # centre dreta
    ]

    paper_colors = np.array([
        np.median(s.reshape(-1, 3), axis=0)
        for s in samples
    ], dtype=np.float32)

    rgb = arr.astype(np.float32)

    # Distància de cada píxel al color de fons més semblant.
    distances = np.stack([
        np.sqrt(((rgb - c) ** 2).sum(axis=2))
        for c in paper_colors
    ])

    dist = distances.min(axis=0)

    # Measure genuine paper variation on the outer strips.
    border = np.concatenate([
        dist[:40, :].ravel(),
        dist[-40:, :].ravel(),
        dist[:, :40].ravel(),
        dist[:, -40:].ravel(),
    ])

    paper_p90 = float(np.percentile(border, 90))
    paper_p95 = float(np.percentile(border, 95))
    paper_p99 = float(np.percentile(border, 99))

    # No fem servir un únic llindar global fix. Alguns renders tenen
    # gradient, vinyetatge o textura del paper molt més marcada.
    #
    # Provem diversos llindars de forma progressiva i ens quedem amb
    # l'últim resultat estable abans que el flood comenci a créixer
    # bruscament cap a l'interior de l'ocell.
    start_tol = float(max(12.0, min(24.0, paper_p90 + 3.0)))
    max_tol = float(min(82.0, max(36.0, paper_p99 + 10.0)))

    def flood_for_tol(test_tol: float):
        passable = dist < test_tol

        # Tanquem canals molt fins perquè un contorn pàl·lid o dèbil no
        # permeti que el flood entri dins de l'ocell.
        pass_img = Image.fromarray(
            passable.astype(np.uint8) * 255
        ).filter(ImageFilter.MinFilter(3))

        passable_for_flood = np.asarray(pass_img) > 127

        # 128 = paper candidat
        #   0 = foreground / barrera
        # 255 = paper exterior confirmat
        m = Image.fromarray(
            np.where(passable_for_flood, 128, 0).astype(np.uint8)
        ).copy()

        seeds = []

        step_x = max(1, w // 48)
        step_y = max(1, h // 48)

        for x in range(0, w, step_x):
            seeds.append((x, 0))
            seeds.append((x, h - 1))

        for y in range(0, h, step_y):
            seeds.append((0, y))
            seeds.append((w - 1, y))

        seeds.extend([
            (0, 0),
            (w - 1, 0),
            (0, h - 1),
            (w - 1, h - 1),
        ])

        for s in seeds:
            if m.getpixel(s) == 128:
                ImageDraw.floodfill(m, s, 255)

        ext = np.asarray(m) == 255
        return ext, float(ext.mean())

    # Construïm una seqüència adaptativa de toleràncies.
    tolerances = []

    t = start_tol
    while t <= max_tol:
        tolerances.append(float(t))
        t += 4.0

    if not tolerances or tolerances[-1] < max_tol:
        tolerances.append(max_tol)

    best_exterior = None
    best_frac = 0.0
    best_tol = None

    previous_frac = 0.0

    for test_tol in tolerances:
        candidate, frac = flood_for_tol(test_tol)

        # Si de cop el flood creix molt, probablement acaba de travessar
        # el contorn i està entrant dins de plomatge clar.
        jump = frac - previous_frac

        if previous_frac >= 0.25 and jump > 0.18:
            break

        # No acceptem una màscara que deixi gairebé tota la imatge com a
        # fons: seria un senyal clar que ens hem menjat l'ocell.
        if frac > 0.93:
            break

        if frac > best_frac:
            best_exterior = candidate
            best_frac = frac
            best_tol = test_tol

        previous_frac = frac

        # Normalment les il·lustracions tenen molt fons. Quan ja n'hem
        # recuperat una quantitat raonable no cal continuar augmentant
        # agressivament la tolerància.
        if frac >= 0.55:
            break

    exterior = best_exterior
    exterior_frac = best_frac
    tol = best_tol if best_tol is not None else start_tol

    if exterior is None or exterior_frac < 0.40:
        raise RuntimeError(
            f"cutout flood failed "
            f"(tol {tol:.1f}, "
            f"paper90 {paper_p90:.1f}, "
            f"paper95 {paper_p95:.1f}, "
            f"paper99 {paper_p99:.1f}, "
            f"exterior {100 * exterior_frac:.0f}%) - "
            f"raw kept for the upgrade pass"
        )

    # Everything not connected to external paper is foreground.
    solid = ~exterior

    # Conserva només els components foreground rellevants.
    # El fons crema residual sol quedar com grans regions separades
    # que toquen la vora o ocupen zones perifèriques.
    seen = np.zeros((h, w), dtype=bool)
    components = []

    for y in range(h):
        for x in range(w):
            if not solid[y, x] or seen[y, x]:
                continue

            q = deque([(x, y)])
            seen[y, x] = True
            comp = []

            while q:
                cx, cy = q.popleft()
                comp.append((cx, cy))

                for nx, ny in (
                        (cx - 1, cy), (cx + 1, cy),
                        (cx, cy - 1), (cx, cy + 1)
                ):
                    if (
                        0 <= nx < w and 0 <= ny < h
                        and solid[ny, nx]
                        and not seen[ny, nx]
                    ):
                        seen[ny, nx] = True
                        q.append((nx, ny))

            components.append(comp)

    if not components:
        raise RuntimeError("cutout produced no foreground")

    # El component principal hauria de ser l'ocell.
    components.sort(key=len, reverse=True)
    main = components[0]

    clean = np.zeros((h, w), dtype=bool)

    for x, y in main:
        clean[y, x] = True

    # Accepta també components petits molt propers al principal
    # (potes, plomes separades, etc.).
    main_ys, main_xs = np.where(clean)
    x0, x1 = main_xs.min(), main_xs.max()
    y0, y1 = main_ys.min(), main_ys.max()

    margin = int(0.08 * max(x1 - x0 + 1, y1 - y0 + 1))

    for comp in components[1:]:
        if len(comp) < 32:
            continue

        xs = [p[0] for p in comp]
        ys = [p[1] for p in comp]

        cx0, cx1 = min(xs), max(xs)
        cy0, cy1 = min(ys), max(ys)

        nearby = (
            cx1 >= x0 - margin and
            cx0 <= x1 + margin and
            cy1 >= y0 - margin and
            cy0 <= y1 + margin
        )

        if nearby:
            for x, y in comp:
                clean[y, x] = True

    solid = clean

    # Fully opaque interior.
    binary = solid.astype(np.uint8) * 255

    # Feather only the outer silhouette.
    feather = np.asarray(
        Image.fromarray(binary).filter(
            ImageFilter.GaussianBlur(0.65)
        )
    ).copy()

    feather[~solid] = 0

    # Make the interior fully opaque.
    feather[solid & (feather >= 220)] = 255

    rgba = np.dstack([arr, feather]).astype(np.uint8)

    fg = feather > 40
    ys, xs = np.where(fg)

    if not len(ys):
        raise RuntimeError(
            "cutout produced an empty image (bad ground?)"
        )

    y0 = ys.min()
    y1 = ys.max() + 1
    x0 = xs.min()
    x1 = xs.max() + 1

    pad = round(
        0.03 * max(y1 - y0, x1 - x0)
    )

    y0 = max(0, y0 - pad)
    x0 = max(0, x0 - pad)
    y1 = min(h, y1 + pad)
    x1 = min(w, x1 + pad)

    Image.fromarray(
        rgba[y0:y1, x0:x1],
        "RGBA"
    ).save(dst)


def record_cut(slug: str, kind: str) -> None:
    cuts = {}
    if CUTS.exists():
        try:
            cuts = json.loads(CUTS.read_text())
        except ValueError:
            cuts = {}
    cuts[slug] = kind
    CUTS.write_text(json.dumps(cuts, indent=0, sort_keys=True) + "\n")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--sci", required=True)
    ap.add_argument("--com", required=True)
    ap.add_argument("--force", action="store_true")
    ap.add_argument("--pose", type=int, choices=(1, 2),
                    help="render only one pose (default: both)")
    ap.add_argument("--sleep", type=float, default=6.0,
                    help="seconds between the two Gemini calls")
    args = ap.parse_args()

    key = os.environ.get("GEMINI_API_KEY", "")
    if not key:
        print("error: GEMINI_API_KEY required in the environment", file=sys.stderr)
        return 2

    # generate.php holds this lock while spawning us. Blocking here is
    # intentional: the API only waits for a live PID, releases its descriptor,
    # and then this worker owns the same lock through every PNG/index mutation.
    # The updater takes the lock only after its separate root update lock, while
    # generation never takes that update lock, so there is no lock-order cycle.
    try:
        generation_lock = GENERATION_LOCK.open("r+")
        fcntl.flock(generation_lock.fileno(), fcntl.LOCK_EX)
    except OSError as exc:
        print(f"error: illustration generation lock unavailable: {exc}", file=sys.stderr)
        return 2

    sci, com = args.sci.strip(), args.com.strip()
    slug = pregen.slugify(sci)
    ILLUS.mkdir(parents=True, exist_ok=True)
    RAW.mkdir(parents=True, exist_ok=True)
    write_state(running=True, sci=sci, com=com, pose=args.pose, step="render")

    try:
        prompt = pregen.load_prompt(HERE / "prompt.template.md")
        notes = pregen.load_species_notes(HERE / "species-notes.json")
        refs = HERE.parent / "assets" / "references"
        pos_ref = pregen.ensure_reference(refs, slug, sci, com)
        anti_key = pregen.select_anti_ref_key(sci)
        anti = pregen.load_anti_ref(refs, anti_key) if anti_key else None

        made = []
        have = []   # poses already on disk - may still need mask registration
        poses = (args.pose,) if args.pose else (1, 2)
        for pose in poses:
            fname = f"{slug}.png" if pose == 1 else f"{slug}-{pose}.png"
            out = ILLUS / fname
            if out.exists() and not args.force:
                print(f"[skip] {fname} exists")
                have.append(fname)
                continue
            style_path = refs / "styles" / pregen.select_style_ref(sci, pose)
            if not style_path.exists():
                # The curated style refs are gitignored and absent on
                # installs; a canonical bundled illustration anchors the
                # style instead (the fix for watercolor drift).
                style_path = ILLUS / ("turdus-migratorius.png" if pose == 1
                                      else "turdus-migratorius-2.png")
                if not style_path.exists():
                    style_path = None
            png = pregen.gen_one(key, prompt, sci, com, pose,
                                 positive_ref=pos_ref,
                                 anti_ref=anti, anti_ref_key=anti_key if anti else None,
                                 species_note=notes.get(sci),
                                 style_ref=style_path)
            raw_path = RAW / fname
            raw_path.write_bytes(png)          # keep the raw for the upgrade pass
            chroma_cut(raw_path, out)
            record_cut(fname[:-4], "chroma")
            made.append(fname)
            print(f"[ok] {fname} ({len(png) // 1024}KB raw, chroma cut)")
            if pose == 1:
                if 2 in poses:
                    write_state(running=True, sci=sci, com=com, pose=args.pose, step="render flight")
                    time.sleep(args.sleep)

        if made or have:
            # Register skipped-but-present poses too: a run that rendered
            # pose 1 then died before this step would otherwise leave the
            # perched mask unregistered forever (the retry skips the file).
            # Re-merging a registered slug is idempotent, so this also
            # self-heals installs already stuck that way.
            write_state(running=True, sci=sci, com=com, pose=args.pose, step="masks")
            slugs = [f[:-4] for f in made + have]
            r = subprocess.run([sys.executable, str(HERE / "build_masks.py"), "--add", *slugs])
            if r.returncode != 0:
                raise RuntimeError("build_masks --add failed")
    except Exception as e:
        write_state(running=False, sci=sci, com=com, pose=args.pose, ok=False, error=str(e))
        print(f"error: {e}", file=sys.stderr)
        return 1

    write_state(running=False, sci=sci, com=com, pose=args.pose, ok=True, made=made)
    print(f"done: {len(made)} rendered for {sci}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
