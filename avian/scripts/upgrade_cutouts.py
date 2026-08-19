#!/usr/bin/env python3
"""AvianVisitors - upgrade the Pi's instant cutouts to BiRefNet quality.

Run on a workstation or laptop, not the Pi. The on-Pi generate path
(generate_one.py) cuts new birds with a quick chroma flood - good
enough to draw, rough at the edges. This pulls each such bird's raw
cream-ground render from the Pi over HTTP, mattes it locally with
BiRefNet (the ~1GB model the Pi can't fit), pushes the refined cutouts
back over ssh, and rebuilds their masks in place. cuts.json entries
clear as birds are upgraded, which also clears the menu notification.

Usage:
    python3 upgrade_cutouts.py --pi <user>@birdnet.local

Needs:  pip install rembg onnxruntime scipy pillow numpy
The first run downloads the BiRefNet model (~1GB) to ~/.u2net/.
"""
from __future__ import annotations
import argparse
import json
import subprocess
import sys
import tempfile
import urllib.request
from pathlib import Path

CREAM_TOL = 11   # near-paper distance (matches the repo cutout pipeline)
PLUMAGE = 18     # beyond this distance from paper counts as inked body


def birefnet_cut(src: Path, dst: Path, sess) -> None:
    """BiRefNet matte + exterior-cream peel + belly fill. A filled region
    whose boundary is mostly not plumage is a between-legs pocket, not a
    belly, and is rejected. Same approach the bundled set was cut with."""
    import numpy as np
    from PIL import Image, ImageFilter
    from rembg import remove
    from scipy import ndimage

    im = Image.open(src).convert("RGB")
    arr = np.asarray(im)
    h, w, _ = arr.shape
    a = np.asarray(remove(im, session=sess))[:, :, 3]
    corners = np.concatenate([arr[:15, :15].reshape(-1, 3), arr[:15, -15:].reshape(-1, 3),
                              arr[-15:, :15].reshape(-1, 3), arr[-15:, -15:].reshape(-1, 3)])
    paper = np.median(corners, axis=0)
    dist = np.sqrt(((arr - paper) ** 2).sum(2))
    passable = (a < 100) | (dist < CREAM_TOL)
    lbl, _n = ndimage.label(passable)
    border = set(lbl[0, :]) | set(lbl[-1, :]) | set(lbl[:, 0]) | set(lbl[:, -1])
    border.discard(0)
    exterior = np.isin(lbl, list(border))
    base = (a >= 100) & ~exterior
    solid = ndimage.binary_fill_holes(base)
    added = solid & ~base
    plumage = (a >= 100) & (dist > PLUMAGE)
    al, an = ndimage.label(added)
    reject = np.zeros_like(solid)
    for i in range(1, an + 1):
        C = al == i
        ring = ndimage.binary_dilation(C, iterations=3) & ~C & ~exterior
        if ring.sum() == 0 or plumage[ring].mean() < 0.30:
            reject |= C
    solid = solid & ~reject
    L, m = ndimage.label(solid)
    if m > 1:
        sizes = ndimage.sum(np.ones_like(L), L, range(1, m + 1))
        solid = (L == int(np.argmax(sizes)) + 1)
    inside = ndimage.binary_erosion(solid, iterations=2)
    af = a.copy(); af[inside] = 255; af[~solid] = 0
    af = np.maximum(np.asarray(Image.fromarray(af).filter(ImageFilter.GaussianBlur(0.4))),
                    (inside * 255).astype(np.uint8))
    af[~solid] = 0
    rgba = np.dstack([arr, af]).astype(np.uint8)
    fg = af > 40
    ys, xs = np.where(fg)
    y0, y1, x0, x1 = ys.min(), ys.max() + 1, xs.min(), xs.max() + 1
    pad = round(0.03 * max(y1 - y0, x1 - x0))
    y0 = max(0, y0 - pad); x0 = max(0, x0 - pad)
    y1 = min(h, y1 + pad); x1 = min(w, x1 + pad)
    Image.fromarray(rgba[y0:y1, x0:x1], "RGBA").save(dst)


def fetch(url: str) -> bytes:
    with urllib.request.urlopen(url, timeout=30) as r:
        return r.read()


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__,
                                 formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--pi", required=True, metavar="USER@HOST",
                    help="ssh target for the Pi (e.g. pi@birdnet.local)")
    ap.add_argument("--repo", default="BirdNET-Pi",
                    help="repo dir on the Pi, relative to its $HOME (default BirdNET-Pi)")
    args = ap.parse_args()

    if "@" not in args.pi:
        print("error: --pi must be user@host", file=sys.stderr)
        return 2
    host = args.pi.split("@", 1)[1]
    base = f"http://{host}/avian/assets/illustrations"

    try:
        from rembg import new_session  # noqa: F401
        import scipy  # noqa: F401
    except ImportError as e:
        print(f"error: missing dependency ({e.name}). Run:\n"
              "    pip install rembg onnxruntime scipy pillow numpy", file=sys.stderr)
        return 2

    try:
        cuts = json.loads(fetch(f"{base}/cuts.json"))
    except Exception as e:
        print(f"error: could not fetch cuts.json from {host}: {e}", file=sys.stderr)
        return 1
    slugs = sorted(k for k, v in cuts.items() if v == "chroma")
    if not slugs:
        print("nothing to upgrade - no instant cutouts recorded")
        return 0
    print(f"{len(slugs)} instant cutout(s) to upgrade: {', '.join(slugs)}")

    from rembg import new_session
    sess = new_session("birefnet-general")

    tmp = Path(tempfile.mkdtemp(prefix="av-upgrade-"))
    done, failed = [], []
    for slug in slugs:
        try:
            raw = fetch(f"{base}/raw/{slug}.png")
            src = tmp / f"{slug}.raw.png"
            src.write_bytes(raw)
            out = tmp / f"{slug}.png"
            birefnet_cut(src, out, sess)
            done.append(slug)
            print(f"  [ok] {slug}")
        except Exception as e:
            failed.append(slug)
            print(f"  [fail] {slug}: {e}", file=sys.stderr)
    if not done:
        print("nothing upgraded", file=sys.stderr)
        return 1

    # Push through a staging dir, then mv into place on the Pi: the files
    # being replaced were created by php-fpm (owned by caddy), so a direct
    # scp overwrite fails; a rename into the group-writable dir doesn't.
    # cuts.json is only pruned after the masks rebuild succeeds, so a
    # failed run stays retryable instead of "nothing to upgrade".
    repo = args.repo.rstrip("/")
    stage = f"{repo}/avian/assets/illustrations/.upgrade-stage"
    for s in done:
        cuts.pop(s, None)
    cj = tmp / "cuts.json"
    cj.write_text(json.dumps(cuts, indent=0, sort_keys=True) + "\n")
    print(f"pushing {len(done)} cutout(s) to {args.pi}:{stage}/")
    if subprocess.run(["ssh", args.pi, f"mkdir -p {stage}"]).returncode != 0:
        print("error: ssh mkdir failed", file=sys.stderr)
        return 1
    files = [str(tmp / f"{s}.png") for s in done] + [str(cj)]
    if subprocess.run(["scp", "-q", *files, f"{args.pi}:{stage}/"]).returncode != 0:
        print("error: scp failed", file=sys.stderr)
        return 1
    # Braces, not parentheses: a subshell would drop the P assignment.
    remote = (f"cd {repo}"
              f" && {{ test -x birdnet/bin/python3 && P=birdnet/bin/python3 || P=python3; }}"
              f" && mv -f avian/assets/illustrations/.upgrade-stage/*.png avian/assets/illustrations/"
              f" && $P avian/scripts/build_masks.py --add {' '.join(done)}"
              f" && mv -f avian/assets/illustrations/.upgrade-stage/cuts.json avian/assets/illustrations/"
              f" && rmdir avian/assets/illustrations/.upgrade-stage")
    if subprocess.run(["ssh", args.pi, remote]).returncode != 0:
        print("error: remote install failed (staged files remain in .upgrade-stage; rerun after fixing)",
              file=sys.stderr)
        return 1

    print(f"done: {len(done)} upgraded" + (f", {len(failed)} failed" if failed else ""))
    print("hard-refresh the collage (or wait for the next poll) to see the new edges")
    return 0


if __name__ == "__main__":
    sys.exit(main())
