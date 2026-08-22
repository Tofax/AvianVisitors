#!/usr/bin/env python3

import json
import re
import urllib.parse
import urllib.request
from pathlib import Path

HERE = Path(__file__).resolve().parents[1]
ILLUSTRATIONS = HERE / "assets" / "illustrations"
OUTPUT = HERE / "frontend" / "names-ca.json"

API_BASE = "https://birdnet.cornell.edu/taxonomy/api/species/"

ALIASES = {
    "Leiothlypis lucidae": "Leiothlypis luciae",
    "Phalacrocorax auritus": "Nannopterum auritum",
    "Regulus calendula": "Corthylio calendula",
}

# Recollim una sola vegada cada espècie.
species = set()

for path in ILLUSTRATIONS.glob("*.png"):
    stem = path.stem

    # La segona pose acaba en "-2".
    stem = re.sub(r"-2$", "", stem)

    parts = stem.split("-")

    if len(parts) < 2:
        continue

    # Els assets d'Avian Visitors fan servir genus-species[-subspecies]
    sci = " ".join(parts)
    sci = sci[0].upper() + sci[1:]

    species.add(sci)

species = sorted(species)

print(f"Trobades {len(species)} espècies als assets")
print()

names = {}
missing = []
errors = []

for i, sci in enumerate(species, 1):
    api_sci = ALIASES.get(sci, sci)
    encoded = urllib.parse.quote(api_sci, safe="")
    url = API_BASE + encoded

    try:
        req = urllib.request.Request(
            url,
            headers={
                "User-Agent": "AvianVisitors-Catalan/1.0",
                "Accept": "application/json",
            },
        )

        with urllib.request.urlopen(req, timeout=15) as response:
            data = json.load(response)

        common_names = data.get("common_names") or {}

        ca = (
            common_names.get("ca")
            or common_names.get("ca_ES")
            or common_names.get("ca-ES")
        )

        if ca:
            names[sci] = ca
            print(f"[{i:3}/{len(species)}] OK   {sci} -> {ca}")
        else:
            missing.append(sci)
            print(f"[{i:3}/{len(species)}] --   {sci} -> sense nom català")

    except Exception as exc:
        errors.append((sci, str(exc)))
        print(f"[{i:3}/{len(species)}] ERR  {sci} -> {exc}")

OUTPUT.write_text(
    json.dumps(
        names,
        ensure_ascii=False,
        indent=2,
        sort_keys=True,
    ) + "\n",
    encoding="utf-8",
)

print()
print("=" * 60)
print(f"Espècies als assets : {len(species)}")
print(f"Noms catalans       : {len(names)}")
print(f"Sense nom català    : {len(missing)}")
print(f"Errors API          : {len(errors)}")
print(f"Fitxer generat      : {OUTPUT}")

if missing:
    print()
    print("Sense traducció catalana:")
    for sci in missing:
        print(f"  - {sci}")

if errors:
    print()
    print("Errors:")
    for sci, error in errors:
        print(f"  - {sci}: {error}")
