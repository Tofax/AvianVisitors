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
from PIL import Image, ImageFilter

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

    The flood uses an adaptive paper model plus a narrow guard band around
    clearly non-paper pixels. Bright low-saturation paper remains passable so
    paper gradients and grain do not isolate large background regions.

    After the flood, only the main bird component and genuinely nearby
    detached pieces are retained. The final alpha is fully opaque in the bird
    interior and feathered only along the outer silhouette.
    """
    im = Image.open(src).convert("RGB")
    arr = np.asarray(im)

    h, w, _ = arr.shape

    # Diverses mostres del paper/fons. Això tolera millor gradients,
    # vinyetatge i petites variacions cromàtiques del render.
    patch = 20

    samples = [
        arr[:patch, :patch],                                      # superior esquerra
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
    rgb01 = rgb / 255.0

    rgb_max = rgb01.max(axis=2)
    rgb_min = rgb01.min(axis=2)

    value = rgb_max

    saturation = np.zeros_like(value)
    nz = rgb_max > 1e-6
    saturation[nz] = (rgb_max[nz] - rgb_min[nz]) / rgb_max[nz]

    # Distància de cada píxel al color de fons més semblant.
    distances = np.stack([
        np.sqrt(((rgb - c) ** 2).sum(axis=2))
        for c in paper_colors
    ])

    dist = distances.min(axis=0)

    # Variació real del paper a les franges exteriors.
    border = np.concatenate([
        dist[:40, :].ravel(),
        dist[-40:, :].ravel(),
        dist[:, :40].ravel(),
        dist[:, -40:].ravel(),
    ])

    paper_p90 = float(np.percentile(border, 90))
    paper_p95 = float(np.percentile(border, 95))
    paper_p99 = float(np.percentile(border, 99))

    # Llindars adaptatius.
    #
    # Important: no deixem que max_tol s'allunyi massa del paper real.
    # Amb ocells marrons/beix (com el gaig), toleràncies molt altes poden
    # classificar el plomatge clar com a paper encara que el flood sigui
    # "connectat a la vora".
    start_tol = float(max(10.0, min(22.0, paper_p90 + 2.0)))
    max_tol = float(min(72.0, max(36.0, paper_p99 + 6.0)))

    # ------------------------------------------------------------------
    # MÀSCARA DE PROTECCIÓ DEL PRIMER PLA
    # ------------------------------------------------------------------
    # Els píxels clarament diferents del paper són tinta/plomatge segur.
    # N'eliminem el gra aïllat i després els dilatem una mica per protegir
    # també els tons pàl·lids immediatament adjacents.
    strong_fg_tol = float(max(30.0, min(58.0, paper_p99 + 12.0)))
    strong_fg = dist >= strong_fg_tol

    strong_img = Image.fromarray(strong_fg.astype(np.uint8) * 255)

    # Opening del foreground: elimina puntets de gra petits sense unir-los.
    strong_img = (
        strong_img
        .filter(ImageFilter.MinFilter(3))
        .filter(ImageFilter.MaxFilter(3))
    )

    # Dues bandes de protecció:
    # - una més ampla per al matching cromàtic normal
    # - una més estreta per al paper molt clar
    protected_fg_color = np.asarray(
        strong_img.filter(ImageFilter.MaxFilter(5))
    ) > 127

    protected_fg_light = np.asarray(
        strong_img.filter(ImageFilter.MaxFilter(3))
    ) > 127

    # Protecció específica per a la neteja de forats interiors.
    # És una banda estreta al voltant del foreground segur que impedeix
    # que la neteja del paper entre potes mossegui potes, dits o plomes.
    protected_fg_holes = np.asarray(
        strong_img.filter(ImageFilter.MaxFilter(5))
    ) > 127

    # Les parts clarament acolorides (potes, bec, plomatge viu, etc.)
    # no poden ser paper crema encara que algun píxel clar de la textura
    # s'hi assembli per luminància.
    colored_fg = saturation > 0.35

    colored_img = Image.fromarray(
        colored_fg.astype(np.uint8) * 255
    )

    # Protegeix també els píxels clars immediatament adjacents al color.
    colored_guard = np.asarray(
        colored_img.filter(ImageFilter.MaxFilter(5))
    ) > 127

    protected_fg_holes |= colored_guard

    def flood_for_tol(test_tol: float):
        color_match = dist < test_tol

        # Paper crema: molt clar i amb poca saturació.
        # És deliberadament permissiu perquè després encara exigim
        # connectivitat amb l'exterior.
        light_paper = (
            (value > 0.68)
            & (saturation < 0.32)
        )

        # El matching cromàtic normal utilitza una protecció ampla.
        # El paper clar utilitza una protecció més estreta per mantenir
        # oberts espais fins entre potes, dits i plomes.
        passable = (
            (color_match & ~protected_fg_color)
            | (light_paper & ~protected_fg_light)
        )

        # No fem morfologia sobre el paper:
        # podria fragmentar el fons i impedir que el flood hi circuli.
        passable_for_flood = passable

        # 128 = paper candidat
        #   0 = foreground / barrera
        # 255 = paper exterior confirmat
        seeds = []

        step_x = max(1, w // 64)
        step_y = max(1, h // 64)

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

        ext = np.zeros((h, w), dtype=bool)
        q = deque()

        for x, y in seeds:
            if passable_for_flood[y, x] and not ext[y, x]:
                ext[y, x] = True
                q.append((x, y))

        neighbors8 = (
            (-1, -1), (0, -1), (1, -1),
            (-1,  0),           (1,  0),
            (-1,  1), (0,  1), (1,  1),
        )

        while q:
            cx, cy = q.popleft()

            for dx, dy in neighbors8:
                nx, ny = cx + dx, cy + dy

                if (
                    0 <= nx < w
                    and 0 <= ny < h
                    and passable_for_flood[ny, nx]
                    and not ext[ny, nx]
                ):
                    ext[ny, nx] = True
                    q.append((nx, ny))

        return ext, float(ext.mean()), passable_for_flood

    # Seqüència adaptativa de toleràncies. Passos petits perquè la detecció
    # de fuita sigui més sensible que amb salts de 4.
    tolerances = []

    t = start_tol
    while t <= max_tol:
        tolerances.append(float(t))
        t += 2.0

    if not tolerances or tolerances[-1] < max_tol:
        tolerances.append(max_tol)

    best_exterior = None
    best_frac = 0.0
    best_tol = None
    best_passable = None

    previous_frac = None
    previous_candidate = None

    for test_tol in tolerances:
        candidate, frac, candidate_passable = flood_for_tol(test_tol)

        if previous_frac is not None:
            jump = frac - previous_frac

            if previous_frac >= 0.35 and jump > 0.06:
                break

            newly_exterior = candidate & ~previous_candidate
            if newly_exterior.any():
                yy, xx = np.where(newly_exterior)

                edge_dist = np.minimum.reduce([
                    xx,
                    (w - 1) - xx,
                    yy,
                    (h - 1) - yy,
                    ])

                deep_ratio = float(
                    np.mean(
                        edge_dist > int(0.12 * min(h, w))
                    )
                )

                if (
                    previous_frac >= 0.35
                    and jump > 0.02
                    and deep_ratio > 0.55
                ):
                    break

        if frac > 0.90:
            break

        if frac > best_frac:
            best_exterior = candidate
            best_frac = frac
            best_tol = test_tol
            best_passable = candidate_passable.copy()

        previous_frac = frac
        previous_candidate = candidate

    exterior = best_exterior
    exterior_frac = best_frac
    tol = best_tol if best_tol is not None else start_tol

    if exterior is None or exterior_frac < 0.30:
        raise RuntimeError(
            f"cutout flood failed "
            f"(tol {tol:.1f}, "
            f"paper90 {paper_p90:.1f}, "
            f"paper95 {paper_p95:.1f}, "
            f"paper99 {paper_p99:.1f}, "
            f"exterior {100 * exterior_frac:.0f}%) - "
            f"raw kept for the upgrade pass"
        )

    debug_dir = dst.parent / "debug"
    debug_dir.mkdir(parents=True, exist_ok=True)

    # Distància respecte del paper.
    dist_debug = np.clip(
        dist / max(1.0, max_tol) * 255.0,
        0,
        255
    ).astype(np.uint8)

    Image.fromarray(dist_debug).save(
        debug_dir / f"{dst.stem}-dist.png"
    )

    # Paper candidat amb la tolerància final seleccionada.
    if best_passable is not None:
        Image.fromarray(
            best_passable.astype(np.uint8) * 255
        ).save(
            debug_dir / f"{dst.stem}-passable.png"
        )

    # Paper que finalment ha pogut assolir el flood.
    Image.fromarray(
        exterior.astype(np.uint8) * 255
    ).save(
        debug_dir / f"{dst.stem}-exterior.png"
    )

    # Protecció ampla usada pel color_match.
    Image.fromarray(
        protected_fg_color.astype(np.uint8) * 255
    ).save(
        debug_dir / f"{dst.stem}-protected-color.png"
    )

    # Protecció estreta usada pel light_paper.
    Image.fromarray(
        protected_fg_light.astype(np.uint8) * 255
    ).save(
        debug_dir / f"{dst.stem}-protected-light.png"
    )

    Image.fromarray(
        protected_fg_holes.astype(np.uint8) * 255
    ).save(
        debug_dir / f"{dst.stem}-protected-holes.png"
    )

    Image.fromarray(
        colored_guard.astype(np.uint8) * 255
    ).save(
        debug_dir / f"{dst.stem}-protected-color-detail.png"
    )

    # Tot el que no és paper exterior confirmat és foreground provisional.
    solid = ~exterior

    # ------------------------------------------------------------------
    # COMPONENTS DEL FOREGROUND
    # ------------------------------------------------------------------
    seen = np.zeros((h, w), dtype=bool)
    components = []

    for y in range(h):
        for x in range(w):
            if not solid[y, x] or seen[y, x]:
                continue

            q = deque([(x, y)])
            seen[y, x] = True
            comp = []
            touches_border = False

            while q:
                cx, cy = q.popleft()
                comp.append((cx, cy))

                if (
                    cx == 0 or cx == w - 1
                    or cy == 0 or cy == h - 1
                ):
                    touches_border = True

                for nx, ny in (
                        (cx - 1, cy),
                        (cx + 1, cy),
                        (cx, cy - 1),
                        (cx, cy + 1),
                ):
                    if (
                        0 <= nx < w
                        and 0 <= ny < h
                        and solid[ny, nx]
                        and not seen[ny, nx]
                    ):
                        seen[ny, nx] = True
                        q.append((nx, ny))

            components.append({
                "pixels": comp,
                "touches_border": touches_border,
            })

    # Qualsevol massa residual connectada al marc exterior és fons.
    interior_components = [
        c for c in components
        if not c["touches_border"]
    ]

    if not interior_components:
        raise RuntimeError(
            "cutout produced no interior foreground "
            "(all foreground touches image border)"
        )

    # L'ocell és el component interior principal.
    interior_components.sort(
        key=lambda c: len(c["pixels"]),
        reverse=True,
    )

    main = interior_components[0]["pixels"]
    clean = np.zeros((h, w), dtype=bool)

    for x, y in main:
        clean[y, x] = True

    main_ys, main_xs = np.where(clean)

    x0, x1 = main_xs.min(), main_xs.max()
    y0, y1 = main_ys.min(), main_ys.max()

    main_size = len(main)
    main_span = max(
        x1 - x0 + 1,
        y1 - y0 + 1,
        )

    # Màscara de proximitat real al component principal.
    #
    # El codi anterior només comparava bounding boxes. Això feia que qualsevol
    # taca de paper dins del rectangle global de l'ocell pogués considerar-se
    # "nearby". Ara exigim proximitat píxel-a-píxel.
    proximity = max(8, min(28, int(round(0.025 * main_span))))
    proximity_size = 2 * proximity + 1

    near_main = np.asarray(
        Image.fromarray(clean.astype(np.uint8) * 255)
        .filter(ImageFilter.MaxFilter(proximity_size))
    ) > 127

    # Recupera peces legítimes desconnectades: punta de cua, dits, plomes, etc.
    # Han de tocar la zona de proximitat real i tenir una mida raonable.
    for entry in interior_components[1:]:
        comp = entry["pixels"]

        if len(comp) < 24:
            continue

        reasonable_size = len(comp) < main_size * 0.40
        if not reasonable_size:
            continue

        is_near = any(near_main[y, x] for x, y in comp)

        if is_near:
            for x, y in comp:
                clean[y, x] = True

    # ------------------------------------------------------------------
    # PAPER TANCAT ENTRE POTES / DITS
    # ------------------------------------------------------------------
    # Algunes zones de paper són realment fons però queden completament
    # tancades per les potes o els peus, de manera que el flood exterior
    # no hi pot arribar.
    #
    # Només considerem components que:
    #   - ja eren paper candidat a best_passable,
    #   - no han estat assolits pel flood exterior,
    #   - són relativament petits,
    #   - i estan a la part inferior de la silueta.
    #
    # Això evita eliminar grans regions clares legítimes com pit o ventre.

    if best_passable is not None:
        enclosed_passable = best_passable & ~exterior & clean

        hole_tol = min(max_tol, paper_p95 + 4.0)

        strict_hole_like = (
            (
                (dist < hole_tol)
                & (saturation < 0.28)
            )
            | (
                (value > 0.74)
                & (saturation < 0.20)
            )
        )

        # Una zona amb color clarament saturat és molt probablement
        # plomatge, pota, bec, etc., no paper crema.
        strict_hole_like &= saturation < 0.35

        hole_seen = np.zeros((h, w), dtype=bool)

        bird_height = y1 - y0 + 1

        # Només considerem forats amb centre a la zona baixa de l'ocell.
        lower_limit = y0 + int(0.55 * bird_height)

        # Ignorem components petits: solen ser textura o detalls de l'ocell.
        min_hole_size = 512

        # Límit relatiu a la mida real del foreground principal.
        max_hole_size = max(
            256,
            int(main_size * 0.06)
        )

        for hy in range(h):
            for hx in range(w):
                if (
                    not enclosed_passable[hy, hx]
                    or hole_seen[hy, hx]
                ):
                    continue

                q = deque([(hx, hy)])
                hole_seen[hy, hx] = True
                hole = []

                while q:
                    cx, cy = q.popleft()
                    hole.append((cx, cy))

                    for nx, ny in (
                            (cx - 1, cy),
                            (cx + 1, cy),
                            (cx, cy - 1),
                            (cx, cy + 1),
                            (cx - 1, cy - 1),
                            (cx + 1, cy - 1),
                            (cx - 1, cy + 1),
                            (cx + 1, cy + 1),
                    ):
                        if (
                            0 <= nx < w
                            and 0 <= ny < h
                            and enclosed_passable[ny, nx]
                            and not hole_seen[ny, nx]
                        ):
                            hole_seen[ny, nx] = True
                            q.append((nx, ny))

                if len(hole) < min_hole_size:
                    continue

                if len(hole) > max_hole_size:
                    continue

                hole_xs = [px for px, py in hole]
                hole_ys = [py for px, py in hole]

                center_y = sum(hole_ys) / len(hole_ys)
                if center_y < lower_limit:
                    continue

                hx0, hx1 = min(hole_xs), max(hole_xs)
                hy0, hy1 = min(hole_ys), max(hole_ys)

                hole_w = hx1 - hx0 + 1
                hole_h = hy1 - hy0 + 1

                # Evita eliminar franges molt primes i allargades (potes).
                aspect = max(hole_w, hole_h) / max(1, min(hole_w, hole_h))
                if aspect > 3.0:
                    continue

                # Exigeix una forma mínimament compacta.
                bbox_area = hole_w * hole_h
                fill_ratio = len(hole) / max(1, bbox_area)
                if fill_ratio < 0.30:
                    continue

                # Exigeix que la major part del component realment sembli paper.
                paper_like_ratio = np.mean([
                    strict_hole_like[py, px]
                    for px, py in hole
                ])
                if paper_like_ratio < 0.82:
                    continue

                # El component global és un buit de paper vàlid, però pot haver absorbit
                # alguns píxels de la pota o dels dits. Només eliminem els píxels que
                # individualment continuen tenint aparença de paper.
                for px, py in hole:
                    if (
                        strict_hole_like[py, px]
                        and not protected_fg_holes[py, px]
                    ):
                        clean[py, px] = False

    # ------------------------------------------------------------------
    # REPARACIÓ DE PETITS FORATS INTERIORS
    # ------------------------------------------------------------------
    # El chroma pot deixar alguns píxels o petites illes transparents dins
    # del cos/plomes. Només omplim forats molt petits i completament
    # envoltats pel foreground.
    #
    # No actuem a la zona baixa de les potes, perquè allà els buits són
    # legítims i els volem conservar.

    pin_seen = np.zeros((h, w), dtype=bool)

    bird_height = y1 - y0 + 1
    leg_zone_y = y0 + int(0.62 * bird_height)

    # Prou petit per arreglar puntets, però no forats anatòmics.
    max_pinhole_size = 128

    for py in range(y0, y1 + 1):
        for px in range(x0, x1 + 1):
            if clean[py, px] or pin_seen[py, px]:
                continue

            q = deque([(px, py)])
            pin_seen[py, px] = True
            hole = []
            touches_bbox = False

            while q:
                cx, cy = q.popleft()
                hole.append((cx, cy))

                if (
                    cx == x0 or cx == x1
                    or cy == y0 or cy == y1
                ):
                    touches_bbox = True

                for nx, ny in (
                        (cx - 1, cy),
                        (cx + 1, cy),
                        (cx, cy - 1),
                        (cx, cy + 1),
                ):
                    if (
                        x0 <= nx <= x1
                        and y0 <= ny <= y1
                        and not clean[ny, nx]
                        and not pin_seen[ny, nx]
                    ):
                        pin_seen[ny, nx] = True
                        q.append((nx, ny))

            # Si comunica amb l'exterior de la silueta, no és un pinhole.
            if touches_bbox:
                continue

            if len(hole) > max_pinhole_size:
                continue

            hole_center_y = sum(py for px, py in hole) / len(hole)

            # No tanquem buits petits entre potes/dits.
            if hole_center_y >= leg_zone_y:
                continue

            for px, py in hole:
                clean[py, px] = True

    # No fem closing global del foreground:
    # pot segellar espais estrets legítims entre potes, dits o plomes.
    solid = clean.copy()

    # Interior completament opac.
    binary = solid.astype(np.uint8) * 255

    # Feather només a la silueta exterior.
    feather = np.asarray(
        Image.fromarray(binary).filter(
            ImageFilter.GaussianBlur(0.65)
        )
    ).copy()

    feather[~solid] = 0

    # Interior completament opac.
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