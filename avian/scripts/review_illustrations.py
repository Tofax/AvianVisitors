#!/usr/bin/env python3
# AvianVisitors illustration fork reviewer v2
from __future__ import annotations

import argparse
import csv
import hashlib
import html
import json
import os
import re
import shutil
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
import secrets
import threading
import webbrowser
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from concurrent.futures import ThreadPoolExecutor, as_completed
from dataclasses import dataclass
from pathlib import Path
from typing import Any

VERSION = "2.2.1"
UPSTREAM = "Twarner491/AvianVisitors"
GITHUB_API = "https://api.github.com"
EBIRD_API = "https://api.ebird.org/v2"
ILLUS_PREFIX = "avian/assets/illustrations/"
USER_AGENT = f"AvianVisitors-Illustration-Review/{VERSION}"

EBIRD_KEYS = ("EBIRD_API_KEY", "EBIRD_KEY")
GITHUB_KEYS = (
  "GH_TOKEN", "GITHUB_TOKEN", "GITHUB_PAT",
  "GITHUB_API_TOKEN", "GITHUB_ACCESS_TOKEN",
  "GITHUB_PERSONAL_ACCESS_TOKEN",
)
PROJECT_CONFIGS = (
  "birdnet.conf", ".env", ".env.local",
  "avian/.env", "avian/.env.local",
  "config/.env", "config/secrets.env",
)

@dataclass(frozen=True)
class Credential:
  value: str
  source: str

@dataclass(frozen=True)
class Species:
  code: str
  scientific_name: str
  common_name: str
  slug: str

def slugify(value: str) -> str:
  return re.sub(r"[^a-z0-9]+", "-", value.lower()).strip("-")

def safe_name(value: str) -> str:
  return re.sub(r"[^A-Za-z0-9._-]+", "-", value).strip("-") or "x"

def project_root() -> Path:
  script = Path(__file__).resolve()
  if script.parent.name == "scripts" and script.parent.parent.name == "avian":
    return script.parent.parent.parent
  return Path.cwd().resolve()

def parse_assignment_file(path: Path) -> dict[str, str]:
  result: dict[str, str] = {}
  try:
    lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
  except OSError:
    return result

  pattern = re.compile(r"^\s*(?:export\s+)?([A-Za-z_][A-Za-z0-9_]*)\s*=\s*(.*?)\s*$")
  for raw in lines:
    if not raw.strip() or raw.lstrip().startswith("#"):
      continue
    m = pattern.match(raw)
    if not m:
      continue
    key, value = m.groups()
    value = value.strip()
    if value and value[0] not in ("'", '"'):
      value = re.split(r"\s+#", value, maxsplit=1)[0].strip()
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
      value = value[1:-1]
    if value:
      result[key] = value
  return result

def project_config_files(root: Path) -> list[Path]:
  return [root / rel for rel in PROJECT_CONFIGS if (root / rel).is_file()]

def find_project_secret(root: Path, names: tuple[str, ...]) -> Credential | None:
  for path in project_config_files(root):
    values = parse_assignment_file(path)
    for name in names:
      value = values.get(name, "").strip()
      if value:
        return Credential(value, f"{path} ({name})")
  return None

def find_env_secret(names: tuple[str, ...]) -> Credential | None:
  for name in names:
    value = os.environ.get(name, "").strip()
    if value:
      return Credential(value, f"environment ({name})")
  return None

def github_from_gh() -> Credential | None:
  exe = shutil.which("gh")
  if not exe:
    return None
  try:
    proc = subprocess.run([exe, "auth", "token"], capture_output=True, text=True, check=True, timeout=15)
  except Exception:
    return None
  token = proc.stdout.strip()
  return Credential(token, "GitHub CLI (gh auth token)") if token else None

def github_from_git_credentials() -> Credential | None:
  exe = shutil.which("git")
  if not exe:
    return None
  try:
    proc = subprocess.run(
        [exe, "credential", "fill"],
        input="protocol=https\nhost=github.com\n\n",
        capture_output=True, text=True, timeout=15
    )
  except Exception:
    return None
  if proc.returncode != 0:
    return None
  values: dict[str, str] = {}
  for line in proc.stdout.splitlines():
    if "=" in line:
      key, value = line.split("=", 1)
      values[key.strip()] = value.strip()
  token = values.get("password", "")
  return Credential(token, "Git credential helper (github.com)") if token else None

def resolve_ebird(explicit: str, root: Path) -> Credential | None:
  if explicit.strip():
    return Credential(explicit.strip(), "--ebird-key")
  return find_project_secret(root, EBIRD_KEYS) or find_env_secret(EBIRD_KEYS)

def resolve_github(explicit: str, root: Path) -> Credential | None:
  if explicit.strip():
    return Credential(explicit.strip(), "--github-token")
  return (
      find_project_secret(root, GITHUB_KEYS)
      or find_env_secret(GITHUB_KEYS)
      or github_from_gh()
      or github_from_git_credentials()
  )

def request_json(url: str, headers: dict[str, str] | None = None, timeout: int = 60, retries: int = 3) -> Any:
  h = {"User-Agent": USER_AGENT, "Accept": "application/json"}
  if headers:
    h.update(headers)
  for attempt in range(retries):
    try:
      req = urllib.request.Request(url, headers=h)
      with urllib.request.urlopen(req, timeout=timeout) as response:
        return json.load(response)
    except urllib.error.HTTPError as exc:
      if exc.code in (429, 500, 502, 503, 504) and attempt + 1 < retries:
        delay = exc.headers.get("Retry-After", "")
        time.sleep(min(int(delay) if delay.isdigit() else 2 ** attempt, 20))
        continue
      body = ""
      try:
        body = exc.read().decode("utf-8", "replace")[:500]
      except Exception:
        pass
      raise RuntimeError(f"HTTP {exc.code}: {url}: {body}") from exc
    except (urllib.error.URLError, TimeoutError) as exc:
      if attempt + 1 < retries:
        time.sleep(min(2 ** attempt, 8))
        continue
      raise RuntimeError(f"Request failed: {url}: {exc}") from exc
  raise RuntimeError(f"Request failed: {url}")

def request_bytes(url: str, headers: dict[str, str] | None = None, timeout: int = 120) -> bytes:
  h = {"User-Agent": USER_AGENT}
  if headers:
    h.update(headers)
  req = urllib.request.Request(url, headers=h)
  with urllib.request.urlopen(req, timeout=timeout) as response:
    return response.read()

def github_headers(token: str) -> dict[str, str]:
  return {
    "Accept": "application/vnd.github+json",
    "Authorization": f"Bearer {token}",
    "X-GitHub-Api-Version": "2022-11-28",
  }

def ebird_headers(token: str) -> dict[str, str]:
  return {"X-eBirdApiToken": token}

def github_rate_limit(token: str) -> tuple[int, int, int]:
  payload = request_json(f"{GITHUB_API}/rate_limit", github_headers(token))
  core = payload.get("resources", {}).get("core", {})
  return (
    int(core.get("remaining", 0) or 0),
    int(core.get("limit", 0) or 0),
    int(core.get("reset", 0) or 0),
  )

def ebird_species(region: str, locale: str, token: str) -> tuple[list[Species], list[str]]:
  codes = request_json(
      f"{EBIRD_API}/product/spplist/{urllib.parse.quote(region, safe='')}",
      ebird_headers(token),
  )
  if not isinstance(codes, list):
    raise RuntimeError("Unexpected eBird regional species response.")
  wanted = {str(code) for code in codes}
  query = urllib.parse.urlencode({"fmt": "json", "cat": "species", "locale": locale})
  taxonomy = request_json(
      f"{EBIRD_API}/ref/taxonomy/ebird?{query}",
      ebird_headers(token),
  )
  if not isinstance(taxonomy, list):
    raise RuntimeError("Unexpected eBird taxonomy response.")
  found: dict[str, Species] = {}
  for row in taxonomy:
    code = str(row.get("speciesCode", "")).strip()
    if code not in wanted:
      continue
    sci = str(row.get("sciName", "")).strip()
    common = str(row.get("comName", "")).strip() or sci
    if sci:
      found[code] = Species(code, sci, common, slugify(sci))
  unresolved = sorted(wanted - set(found))
  species = sorted(found.values(), key=lambda s: (s.common_name.casefold(), s.scientific_name.casefold()))
  return species, unresolved

def parse_labels(path: Path) -> set[str]:
  result: set[str] = set()
  for raw in path.read_text(encoding="utf-8", errors="replace").splitlines():
    line = raw.strip()
    if not line or line.startswith("#"):
      continue
    if "|" in line:
      sci = line.split("|", 1)[0]
    elif "_" in line:
      sci = line.split("_", 1)[0]
    elif "," in line:
      sci = line.split(",", 1)[0]
    else:
      continue
    if sci.strip():
      result.add(slugify(sci.strip()))
  return result

def list_repositories(token: str) -> list[dict[str, Any]]:
  headers = github_headers(token)
  upstream = request_json(f"{GITHUB_API}/repos/{UPSTREAM}", headers)
  result = [{
    "full_name": upstream["full_name"],
    "default_branch": upstream["default_branch"],
    "fork": False,
  }]
  page = 1
  while True:
    q = urllib.parse.urlencode({"per_page": 100, "page": page, "sort": "newest"})
    batch = request_json(f"{GITHUB_API}/repos/{UPSTREAM}/forks?{q}", headers)
    if not batch:
      break
    for repo in batch:
      result.append({
        "full_name": repo["full_name"],
        "default_branch": repo["default_branch"],
        "fork": True,
      })
    if len(batch) < 100:
      break
    page += 1
  return result[:1] + sorted(result[1:], key=lambda r: r["full_name"].casefold())

def scan_repository(repo: dict[str, Any], token: str) -> dict[str, Any]:
  name = repo["full_name"]
  branch = repo["default_branch"]
  branch_ref = urllib.parse.quote(branch, safe="")
  tree = request_json(
      f"{GITHUB_API}/repos/{name}/git/trees/{branch_ref}?recursive=1",
      github_headers(token),
      timeout=120,
  )
  files: dict[str, str] = {}
  for item in tree.get("tree", []):
    if item.get("type") != "blob":
      continue
    path = str(item.get("path", ""))
    if not path.startswith(ILLUS_PREFIX):
      continue
    filename = path[len(ILLUS_PREFIX):]
    if "/" in filename or not filename.lower().endswith(".png"):
      continue
    blob = str(item.get("sha", "")).strip()
    if blob:
      files[filename] = blob
  return {
    "default_branch": branch,
    "fork": repo["fork"],
    "files": files,
    "truncated": bool(tree.get("truncated")),
    "error": "",
  }

def scan_all_repositories(token: str) -> dict[str, Any]:
  repos = list_repositories(token)
  print(f"[github] repositories to scan: {len(repos)}", file=sys.stderr)
  data: dict[str, Any] = {}
  for index, repo in enumerate(repos, 1):
    name = repo["full_name"]
    print(f"[github] {index:>3}/{len(repos)} {name}", file=sys.stderr)
    try:
      data[name] = scan_repository(repo, token)
    except Exception as exc:
      data[name] = {
        "default_branch": repo["default_branch"],
        "fork": repo["fork"],
        "files": {},
        "truncated": False,
        "error": str(exc),
      }
      print(f"[github] ERROR {name}: {exc}", file=sys.stderr)
  return {
    "schema": 2,
    "created_at": int(time.time()),
    "upstream": UPSTREAM,
    "repos": data,
  }

def valid_cache(payload: dict[str, Any], hours: int) -> tuple[bool, str]:
  if payload.get("schema") != 2:
    return False, "old schema"
  created = int(payload.get("created_at", 0) or 0)
  if time.time() - created > max(hours, 0) * 3600:
    return False, "expired"
  repos = payload.get("repos")
  if not isinstance(repos, dict) or not repos:
    return False, "empty"
  for info in repos.values():
    if info.get("error"):
      return False, "contains repo errors"
    if info.get("truncated"):
      return False, "contains truncated repository trees"
    if not isinstance(info.get("files"), dict):
      return False, "missing blob metadata"
  return True, "ok"

def load_index(cache: Path, token: str, refresh: bool, hours: int) -> dict[str, Any]:
  if cache.is_file() and not refresh:
    try:
      payload = json.loads(cache.read_text(encoding="utf-8"))
      ok, reason = valid_cache(payload, hours)
      if ok:
        age = (time.time() - payload["created_at"]) / 3600
        print(f"[github] using v2 cache ({age:.1f} h old)", file=sys.stderr)
        return payload
      print(f"[github] ignoring cache: {reason}", file=sys.stderr)
    except Exception as exc:
      print(f"[github] ignoring unreadable cache: {exc}", file=sys.stderr)
  payload = scan_all_repositories(token)
  cache.parent.mkdir(parents=True, exist_ok=True)
  cache.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
  return payload

def expected_filename(slug: str, pose: int) -> str:
  return f"{slug}.png" if pose == 1 else f"{slug}-2.png"

def collect_occurrences(species: list[Species], repo_index: dict[str, Any]) -> list[dict[str, Any]]:
  wanted: dict[str, tuple[Species, int]] = {}
  for bird in species:
    wanted[expected_filename(bird.slug, 1)] = (bird, 1)
    wanted[expected_filename(bird.slug, 2)] = (bird, 2)
  result: list[dict[str, Any]] = []
  for repo_name, info in repo_index["repos"].items():
    for filename, blob in info.get("files", {}).items():
      match = wanted.get(filename)
      if not match:
        continue
      bird, pose = match
      result.append({
        "slug": bird.slug,
        "pose": pose,
        "filename": filename,
        "blob_sha": blob,
        "repo": repo_name,
        "branch": info["default_branch"],
        "is_upstream": repo_name == UPSTREAM,
      })
  return result

def group_variants(occurrences: list[dict[str, Any]]) -> list[dict[str, Any]]:
  groups: dict[tuple[str, int, str], dict[str, Any]] = {}
  for occ in occurrences:
    key = (occ["slug"], int(occ["pose"]), occ["blob_sha"])
    if key not in groups:
      groups[key] = {
        "slug": occ["slug"],
        "pose": int(occ["pose"]),
        "filename": occ["filename"],
        "blob_sha": occ["blob_sha"],
        "sources": [],
      }
    groups[key]["sources"].append({
      "repo": occ["repo"],
      "branch": occ["branch"],
      "is_upstream": occ["is_upstream"],
    })
  for group in groups.values():
    group["sources"].sort(key=lambda s: (not s["is_upstream"], s["repo"].casefold()))
  return sorted(groups.values(), key=lambda g: (g["slug"], g["pose"], g["blob_sha"]))

def github_file(repo: str, branch: str, filename: str, token: str) -> bytes:
  path = ILLUS_PREFIX + filename
  encoded = "/".join(urllib.parse.quote(p, safe="") for p in path.split("/"))
  q = urllib.parse.urlencode({"ref": branch})
  headers = github_headers(token)
  headers["Accept"] = "application/vnd.github.raw"
  return request_bytes(f"{GITHUB_API}/repos/{repo}/contents/{encoded}?{q}", headers)

def raw_url(repo: str, branch: str, filename: str) -> str:
  """
  Build a direct raw.githubusercontent.com URL.

  Preserve '/' in branch names. Encoding the whole branch with safe=""
  turns feature/foo into feature%2Ffoo, which raw.githubusercontent.com
  does not reliably resolve as the branch path.
  """
  path = ILLUS_PREFIX + filename
  encoded_branch = urllib.parse.quote(branch, safe="/-._~")
  encoded_path = "/".join(
      urllib.parse.quote(part, safe="-._~")
      for part in path.split("/")
  )
  return (
      "https://raw.githubusercontent.com/"
      + repo
      + "/"
      + encoded_branch
      + "/"
      + encoded_path
  )

def download_raw_variant(
    repo: str,
    branch: str,
    filename: str,
    *,
    retries: int = 6,
    timeout: int = 120,
) -> bytes:
  """
  Download a PNG from raw.githubusercontent.com rather than the GitHub REST
  Contents API. This avoids spending one REST API request for every image.

  404 is treated as permanent for that representative. 403/429/5xx and
  network timeouts are retried with exponential backoff.
  """
  url = raw_url(repo, branch, filename)
  headers = {
    "User-Agent": USER_AGENT,
    "Accept": "image/png,image/*;q=0.9,*/*;q=0.1",
    "Cache-Control": "no-cache",
  }

  last_error: Exception | None = None

  for attempt in range(retries):
    try:
      req = urllib.request.Request(url, headers=headers)
      with urllib.request.urlopen(req, timeout=timeout) as response:
        data = response.read()

      # Validate immediately so HTML pages / rate-limit responses cannot
      # be cached as if they were PNG files.
      png_dimensions(data)
      return data

    except urllib.error.HTTPError as exc:
      last_error = exc

      # A 404 on a direct raw URL is not expected to recover by waiting.
      if exc.code == 404:
        raise RuntimeError(
            f"raw HTTP 404: {repo}@{branch}/{filename}"
        ) from exc

      if exc.code in (403, 408, 429, 500, 502, 503, 504):
        if attempt + 1 < retries:
          retry_after = exc.headers.get("Retry-After", "")
          if retry_after.isdigit():
            delay = min(int(retry_after), 60)
          else:
            delay = min(2 ** attempt, 30)
          time.sleep(delay)
          continue

      raise RuntimeError(
          f"raw HTTP {exc.code}: {repo}@{branch}/{filename}"
      ) from exc

    except (urllib.error.URLError, TimeoutError) as exc:
      last_error = exc
      if attempt + 1 < retries:
        time.sleep(min(2 ** attempt, 30))
        continue
      raise RuntimeError(
          f"raw download failed: {repo}@{branch}/{filename}: {exc}"
      ) from exc

    except ValueError as exc:
      # Invalid/non-PNG body. It may be a transient proxy/rate-limit page,
      # so retry before giving up.
      last_error = exc
      if attempt + 1 < retries:
        time.sleep(min(2 ** attempt, 30))
        continue
      raise RuntimeError(
          f"raw response is not a valid PNG: "
          f"{repo}@{branch}/{filename}: {exc}"
      ) from exc

  raise RuntimeError(
      f"raw download failed after {retries} attempts: "
      f"{repo}@{branch}/{filename}: {last_error}"
  )


def png_dimensions(data: bytes) -> tuple[int, int]:
  if not data.startswith(b"\x89PNG\r\n\x1a\n"):
    raise ValueError("Not a PNG.")
  if len(data) < 24 or data[12:16] != b"IHDR":
    raise ValueError("Invalid PNG header.")
  return int.from_bytes(data[16:20], "big"), int.from_bytes(data[20:24], "big")

def download_variant(group: dict[str, Any], assets: Path, token: str, refresh: bool) -> dict[str, Any]:
  pose_dir = assets / group["slug"] / f"pose{group['pose']}"
  pose_dir.mkdir(parents=True, exist_ok=True)
  dst = pose_dir / f"{group['blob_sha']}.png"
  representative = group["sources"][0]
  if refresh or not dst.is_file():
    data = download_raw_variant(
        representative["repo"],
        representative["branch"],
        group["filename"],
    )
    tmp = dst.with_suffix(".tmp")
    tmp.write_bytes(data)
    tmp.replace(dst)
  else:
    data = dst.read_bytes()
    try:
      png_dimensions(data)
    except ValueError:
      # Never keep a corrupt/incomplete cached download.
      dst.unlink(missing_ok=True)
      data = download_raw_variant(
          representative["repo"],
          representative["branch"],
          group["filename"],
      )
      tmp = dst.with_suffix(".tmp")
      tmp.write_bytes(data)
      tmp.replace(dst)
  width, height = png_dimensions(data)
  sha256 = hashlib.sha256(data).hexdigest()
  sources = []
  for source in group["sources"]:
    sources.append({
      **source,
      "raw_url": raw_url(source["repo"], source["branch"], group["filename"]),
    })
  return {
    **group,
    "sha256": sha256,
    "width": width,
    "height": height,
    "bytes": len(data),
    "path": dst,
    "sources": sources,
  }

def local_info(illustrations: Path, slug: str, pose: int) -> dict[str, Any]:
  path = illustrations / expected_filename(slug, pose)
  if not path.is_file():
    return {"exists": False, "sha256": "", "filename": path.name}
  digest = hashlib.sha256(path.read_bytes()).hexdigest()
  return {"exists": True, "sha256": digest, "filename": path.name}

def status(local1: dict, local2: dict, pose1: list, pose2: list) -> str:
  if local1["exists"] and local2["exists"]:
    return "local_complete"
  if local1["exists"] or local2["exists"]:
    return "local_partial_with_options" if pose1 or pose2 else "local_partial"
  if pose1 and pose2:
    return "remote_complete"
  if pose1 or pose2:
    return "remote_partial"
  return "missing"

STATUS_LABEL = {
  "local_complete": "Local completa",
  "local_partial_with_options": "Local parcial + opcions remotes",
  "local_partial": "Local parcial",
  "remote_complete": "Disponible als forks",
  "remote_partial": "Disponible parcialment als forks",
  "missing": "No trobada",
}

def make_report(
    species: list[Species],
    variants: list[dict[str, Any]],
    illustrations: Path,
    review_dir: Path,
    repo_index: dict[str, Any],
    region: str,
    locale: str,
    unresolved: list[str],
    errors: list[dict[str, Any]],
    occurrence_count: int,
) -> dict[str, Any]:
  lookup: dict[tuple[str, int], list[dict[str, Any]]] = {}
  for variant in variants:
    lookup.setdefault((variant["slug"], variant["pose"]), []).append(variant)

  rows = []
  statuses: dict[str, int] = {}

  for bird in species:
    local1 = local_info(illustrations, bird.slug, 1)
    local2 = local_info(illustrations, bird.slug, 2)
    poses: dict[str, list[dict[str, Any]]] = {"1": [], "2": []}

    for pose in (1, 2):
      local_hash = local1["sha256"] if pose == 1 else local2["sha256"]
      for variant in lookup.get((bird.slug, pose), []):
        poses[str(pose)].append({
          "filename": variant["filename"],
          "blob_sha": variant["blob_sha"],
          "sha256": variant["sha256"],
          "width": variant["width"],
          "height": variant["height"],
          "bytes": variant["bytes"],
          "image": variant["path"].relative_to(review_dir).as_posix(),
          "matches_local": bool(local_hash and local_hash == variant["sha256"]),
          "sources": variant["sources"],
        })
      poses[str(pose)].sort(
          key=lambda v: (
            not any(s["is_upstream"] for s in v["sources"]),
            -len(v["sources"]),
            v["blob_sha"],
          )
      )

    state = status(local1, local2, poses["1"], poses["2"])
    statuses[state] = statuses.get(state, 0) + 1
    repo1 = {s["repo"] for v in poses["1"] for s in v["sources"]}
    repo2 = {s["repo"] for v in poses["2"] for s in v["sources"]}

    rows.append({
      "code": bird.code,
      "scientific_name": bird.scientific_name,
      "common_name": bird.common_name,
      "slug": bird.slug,
      "status": state,
      "status_label": STATUS_LABEL[state],
      "local": {"pose1": local1, "pose2": local2},
      "summary": {
        "pose1_variants": len(poses["1"]),
        "pose2_variants": len(poses["2"]),
        "repos_any": len(repo1 | repo2),
        "repos_complete_pair": len(repo1 & repo2),
      },
      "poses": poses,
    })

  rows.sort(key=lambda b: (b["common_name"].casefold(), b["scientific_name"].casefold()))
  return {
    "schema": 2,
    "generator_version": VERSION,
    "generated_at": int(time.time()),
    "region": region,
    "locale": locale,
    "upstream": UPSTREAM,
    "counts": {
      "species": len(rows),
      "repos_scanned": len(repo_index["repos"]),
      "remote_occurrences": occurrence_count,
      "distinct_variants": len(variants),
      "download_errors": len(errors),
      "unresolved_ebird_codes": len(unresolved),
      "statuses": statuses,
    },
    "unresolved_ebird_codes": unresolved,
    "errors": errors,
    "species": rows,
  }

HTML_TEMPLATE = '''<!doctype html>
<html lang="ca">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>AvianVisitors - revisio d'il·lustracions</title>
<style>
:root{--bg:#f4f6fa;--panel:#fff;--line:#dce2ec;--text:#202531;--muted:#697386;--accent:#3859dc;--soft:#edf1ff;--ok:#176b3a;--okbg:#e8f7ee;--warn:#875800;--warnbg:#fff3d9;--bad:#9b2424;--badbg:#fde9e9}
*{box-sizing:border-box}body{margin:0;font-family:system-ui,-apple-system,"Segoe UI",sans-serif;background:var(--bg);color:var(--text)}
button,input{font:inherit}a{color:var(--accent);text-decoration:none}a:hover{text-decoration:underline}
.app{display:grid;grid-template-columns:350px 1fr;min-height:100vh}.side{background:#fff;border-right:1px solid var(--line)}
.head{padding:18px;border-bottom:1px solid var(--line);position:sticky;top:0;background:#fff;z-index:2}.head h1{font-size:1.15rem;margin:0}
.search{width:100%;padding:10px 12px;margin:13px 0;border:1px solid var(--line);border-radius:10px}
.filters,.badges,.actions{display:flex;gap:6px;flex-wrap:wrap}.filter,.btn{border:1px solid var(--line);background:#fff;border-radius:999px;padding:6px 9px;cursor:pointer}
.filter.active{background:var(--soft);border-color:var(--accent);color:var(--accent)}.btn{border-radius:10px;padding:9px 12px}.btn.primary{background:var(--accent);color:#fff;border-color:var(--accent)}
.stats{display:grid;grid-template-columns:1fr 1fr;gap:7px;margin-top:10px}.stat{border:1px solid var(--line);border-radius:10px;padding:8px;font-size:.8rem}
.list{padding:10px;display:flex;flex-direction:column;gap:7px}.row{padding:11px;border:1px solid var(--line);border-radius:12px;background:#fff;cursor:pointer}
.row.active{background:var(--soft);border-color:var(--accent)}.latin{font-style:italic;color:var(--muted);font-size:.86rem;margin:3px 0 7px}
.badge{display:inline-flex;padding:4px 8px;border-radius:999px;background:#eef1f5;color:#596274;font-size:.74rem}.ok{background:var(--okbg);color:var(--ok)}.warn{background:var(--warnbg);color:var(--warn)}.bad{background:var(--badbg);color:var(--bad)}
.content{padding:22px;min-width:0}.card{background:#fff;border:1px solid var(--line);border-radius:16px}.hero{padding:20px}.heroTop{display:flex;justify-content:space-between;gap:15px}.hero h2{margin:0 0 4px}
.pose{padding:16px;margin-top:16px}.poseHead{display:flex;justify-content:space-between;gap:10px;align-items:center}.variants{display:grid;grid-template-columns:repeat(auto-fill,minmax(250px,1fr));gap:14px;margin-top:12px}
.variant{border:1px solid var(--line);border-radius:14px;overflow:hidden}.preview{aspect-ratio:1/1;background:#f0f2f7;display:flex;align-items:center;justify-content:center}.preview img{max-width:100%;max-height:100%}
.body{padding:12px}.sources{font-size:.86rem;padding-left:18px}.small{font-size:.78rem;color:var(--muted)}pre{white-space:pre-wrap;word-break:break-word;background:#101524;color:#eef2ff;padding:12px;border-radius:10px}
@media(max-width:1000px){.app{grid-template-columns:1fr}.side{border-right:0;border-bottom:1px solid var(--line)}.head{position:relative}}
</style>
</head>
<body>
<div class="app">
<aside class="side">
<div class="head">
<h1>AvianVisitors - {{REGION}}</h1>
<div class="small">Revisio de variants dels forks - v{{VERSION}}</div>
<input id="search" class="search" placeholder="Cerca especie...">
<div id="filters" class="filters"></div>
<div class="stats">
<div class="stat"><b>{{SPECIES_COUNT}}</b><br>especies</div>
<div class="stat"><b>{{REPO_COUNT}}</b><br>repositoris</div>
<div class="stat"><b>{{OCCURRENCE_COUNT}}</b><br>aparicions</div>
<div class="stat"><b>{{VARIANT_COUNT}}</b><br>variants diferents</div>
</div>
</div>
<div id="list" class="list"></div>
</aside>
<main id="content" class="content"></main>
</div>
<script id="data" type="application/json">{{DATA}}</script>
<script>
const report=JSON.parse(document.getElementById('data').textContent);
const birds=report.species, bySlug=new Map(birds.map(b=>[b.slug,b]));
const key=`avian-review-v2:${report.region}`;
let selected=(()=>{try{return JSON.parse(localStorage.getItem(key)||'{}')}catch{return {}}})();
let active=birds[0]?.slug||'', query='', filter='all';
const filters=[['all','Totes'],['remote_complete','Als forks'],['remote_partial','Remota parcial'],['local_complete','Local completa'],['local_partial_with_options','Local + opcions'],['local_partial','Local parcial'],['missing','No trobada']];
const esc=s=>String(s).replaceAll('&','&amp;').replaceAll('<','&lt;').replaceAll('>','&gt;').replaceAll('"','&quot;');
function cls(s){return s==='missing'?'bad':(s.includes('partial')?'warn':'ok')}
function visible(){const q=query.trim().toLowerCase();return birds.filter(b=>(filter==='all'||b.status===filter)&&(!q||`${b.common_name} ${b.scientific_name} ${b.slug}`.toLowerCase().includes(q)))}
function renderFilters(){document.getElementById('filters').innerHTML=filters.map(([v,l])=>`<button class="filter ${filter===v?'active':''}" data-f="${v}">${l}</button>`).join('');document.querySelectorAll('[data-f]').forEach(x=>x.onclick=()=>{filter=x.dataset.f;const v=visible();if(v.length&&!v.some(b=>b.slug===active))active=v[0].slug;renderFilters();renderList();renderDetail()})}
function renderList(){const v=visible(),el=document.getElementById('list');el.innerHTML=v.map(b=>`<div class="row ${b.slug===active?'active':''}" data-s="${esc(b.slug)}"><b>${esc(b.common_name)}</b><div class="latin">${esc(b.scientific_name)}</div><div class="badges"><span class="badge ${cls(b.status)}">${esc(b.status_label)}</span><span class="badge">P1 ${b.summary.pose1_variants}</span><span class="badge">P2 ${b.summary.pose2_variants}</span></div></div>`).join('')||'<div class="small">Cap resultat.</div>';el.querySelectorAll('[data-s]').forEach(x=>x.onclick=()=>{active=x.dataset.s;renderList();renderDetail()})}
function variantCard(b,pose,v,i){const checked=selected?.[b.slug]?.[String(pose)]?.blob_sha===v.blob_sha;return `<article class="variant"><div class="preview"><img loading="lazy" src="${esc(v.image)}"></div><div class="body"><div><b>Variant ${i+1}</b> <span class="small">${esc(v.blob_sha.slice(0,12))}...</span></div><div class="badges"><span class="badge">${v.width}x${v.height}</span><span class="badge">${v.sources.length} fork(s)</span>${v.matches_local?'<span class="badge ok">igual que local</span>':''}</div><label class="badge"><input type="radio" name="${esc(b.slug)}-${pose}" data-pick data-slug="${esc(b.slug)}" data-pose="${pose}" data-blob="${esc(v.blob_sha)}" ${checked?'checked':''}> tria</label><ul class="sources">${v.sources.map(s=>`<li><a target="_blank" rel="noreferrer" href="${esc(s.raw_url)}">${esc(s.repo)}</a> <span class="small">@${esc(s.branch)}</span>${s.is_upstream?' <span class="badge">upstream</span>':''}</li>`).join('')}</ul></div></article>`}
function poseBlock(b,pose){const v=b.poses[String(pose)]||[],fn=pose===1?`${b.slug}.png`:`${b.slug}-2.png`;return `<section class="card pose"><div class="poseHead"><h3>Pose ${pose}</h3><span class="badge">${esc(fn)}</span></div>${v.length?`<div class="variants">${v.map((x,i)=>variantCard(b,pose,x,i)).join('')}</div>`:'<p class="small">No trobada a cap fork escanejat.</p>'}</section>`}
function exportAll(){const blob=new Blob([JSON.stringify({schema:1,region:report.region,selections:selected},null,2)],{type:'application/json'}),a=document.createElement('a');a.href=URL.createObjectURL(blob);a.download=`illustration-selection-${report.region}.json`;a.click();setTimeout(()=>URL.revokeObjectURL(a.href),1000)}
async function applySelection(){
  if(location.protocol==='file:'){
    alert("Per aplicar canvis cal obrir aquesta web amb el servidor local de review_illustrations.py (--serve).");
    return;
  }
  const total=Object.values(selected).reduce((n,p)=>n+Object.keys(p||{}).length,0);
  if(!total){
    alert("No has seleccionat cap variant.");
    return;
  }
  if(!confirm(`S'aplicaran ${total} imatge(s) a avian/assets/illustrations/. Es fara una copia de seguretat dels fitxers substituits. Continuar?`)){
    return;
  }
  const button=document.getElementById('apply');
  if(button){button.disabled=true;button.textContent='Aplicant...'}
  try{
    const response=await fetch('/api/apply',{
      method:'POST',
      headers:{'Content-Type':'application/json','X-Avian-Review-Token':window.AVIAN_REVIEW_TOKEN||''},
      body:JSON.stringify({selections:selected})
    });
    const data=await response.json().catch(()=>({}));
    if(!response.ok||!data.ok){
      throw new Error(data.error||`HTTP ${response.status}`);
    }
    const lines=[
      `Aplicacio completada.`,
      `Afegides: ${data.added}`,
      `Substituides: ${data.replaced}`,
      `Sense canvis: ${data.unchanged}`,
      `Backup: ${data.backup_dir||'no necessari'}`,
      `Masks: ${data.masks_status}`
    ];
    alert(lines.join('\n'));
    location.reload();
  }catch(error){
    alert(`No s'ha pogut aplicar la seleccio: ${error.message}`);
  }finally{
    if(button){button.disabled=false;button.textContent='Aplica al projecte'}
  }
}
function renderDetail(){const v=visible(),el=document.getElementById('content');if(!v.length){el.innerHTML='<div class="card hero">Cap especie.</div>';return}const b=bySlug.get(active)||v[0];active=b.slug;el.innerHTML=`<section class="card hero"><div class="heroTop"><div><h2>${esc(b.common_name)}</h2><div class="latin">${esc(b.scientific_name)}</div><div class="badges"><span class="badge ${cls(b.status)}">${esc(b.status_label)}</span><span class="badge ${b.local.pose1.exists?'ok':'bad'}">Local P1 ${b.local.pose1.exists?'si':'no'}</span><span class="badge ${b.local.pose2.exists?'ok':'bad'}">Local P2 ${b.local.pose2.exists?'si':'no'}</span><span class="badge">${b.summary.repos_any} repos</span></div></div><div class="actions"><button id="clear" class="btn">Esborra seleccio</button><button id="export" class="btn">Exporta seleccions</button><button id="apply" class="btn primary">Aplica al projecte</button></div></div><pre>${esc(JSON.stringify(selected[b.slug]||{},null,2))}</pre></section>${poseBlock(b,1)}${poseBlock(b,2)}`;el.querySelectorAll('[data-pick]').forEach(x=>x.onchange=()=>{const bird=bySlug.get(x.dataset.slug),pose=x.dataset.pose,variant=bird.poses[pose].find(v=>v.blob_sha===x.dataset.blob);selected[bird.slug]??={};selected[bird.slug][pose]={blob_sha:variant.blob_sha,sha256:variant.sha256,filename:variant.filename,image:variant.image,sources:variant.sources};localStorage.setItem(key,JSON.stringify(selected));renderDetail()});document.getElementById('clear').onclick=()=>{delete selected[b.slug];localStorage.setItem(key,JSON.stringify(selected));renderDetail()};document.getElementById('export').onclick=exportAll;document.getElementById('apply').onclick=applySelection}
document.getElementById('search').oninput=e=>{query=e.target.value;const v=visible();if(v.length&&!v.some(b=>b.slug===active))active=v[0].slug;renderList();renderDetail()};
renderFilters();renderList();renderDetail();
</script>
</body>
</html>
'''

def build_html(report: dict[str, Any]) -> str:
  data = json.dumps(report, ensure_ascii=False).replace("</", "<\\/")
  return (
    HTML_TEMPLATE
    .replace("{{REGION}}", html.escape(report["region"]))
    .replace("{{VERSION}}", VERSION)
    .replace("{{SPECIES_COUNT}}", str(report["counts"]["species"]))
    .replace("{{REPO_COUNT}}", str(report["counts"]["repos_scanned"]))
    .replace("{{OCCURRENCE_COUNT}}", str(report["counts"]["remote_occurrences"]))
    .replace("{{VARIANT_COUNT}}", str(report["counts"]["distinct_variants"]))
    .replace("{{DATA}}", data)
  )

def write_summary(path: Path, report: dict[str, Any]) -> None:
  fields = [
    "common_name", "scientific_name", "slug", "status",
    "local_pose1", "local_pose2", "pose1_variants",
    "pose2_variants", "repos_any", "repos_complete_pair",
  ]
  with path.open("w", encoding="utf-8-sig", newline="") as handle:
    writer = csv.DictWriter(handle, fieldnames=fields)
    writer.writeheader()
    for bird in report["species"]:
      writer.writerow({
        "common_name": bird["common_name"],
        "scientific_name": bird["scientific_name"],
        "slug": bird["slug"],
        "status": bird["status"],
        "local_pose1": "yes" if bird["local"]["pose1"]["exists"] else "no",
        "local_pose2": "yes" if bird["local"]["pose2"]["exists"] else "no",
        "pose1_variants": bird["summary"]["pose1_variants"],
        "pose2_variants": bird["summary"]["pose2_variants"],
        "repos_any": bird["summary"]["repos_any"],
        "repos_complete_pair": bird["summary"]["repos_complete_pair"],
      })


def validate_selected_asset(review_dir: Path, relative_image: str) -> Path:
  """Resolve a selected review image safely inside review_dir/assets."""
  if not relative_image:
    raise ValueError("selection has no image path")
  candidate = (review_dir / relative_image).resolve()
  assets_root = (review_dir / "assets").resolve()
  try:
    candidate.relative_to(assets_root)
  except ValueError as exc:
    raise ValueError("selected image is outside the review assets directory") from exc
  if not candidate.is_file():
    raise FileNotFoundError(f"selected image not found: {candidate}")
  data = candidate.read_bytes()
  png_dimensions(data)
  return candidate


def apply_selection_to_project(
    selections: dict[str, Any],
    *,
    review_dir: Path,
    illustrations: Path,
    repo_root: Path,
) -> dict[str, Any]:
  """
  Apply browser selections to the real illustration directory.

  Existing destination PNGs are backed up before replacement. Files already
  identical to the selected image are left untouched.
  """
  if not isinstance(selections, dict):
    raise ValueError("invalid selections payload")

  timestamp = time.strftime("%Y%m%d-%H%M%S")
  backup_dir = repo_root / "avian" / "reports" / "illustration-backups" / timestamp
  backup_used = False
  added = 0
  replaced = 0
  unchanged = 0
  applied: list[dict[str, Any]] = []

  illustrations.mkdir(parents=True, exist_ok=True)

  for slug, poses in sorted(selections.items()):
    if not re.fullmatch(r"[a-z0-9]+(?:-[a-z0-9]+)*", str(slug)):
      raise ValueError(f"invalid species slug: {slug!r}")
    if not isinstance(poses, dict):
      raise ValueError(f"invalid pose selection for {slug}")

    for pose_key, choice in sorted(poses.items()):
      if pose_key not in ("1", "2"):
        raise ValueError(f"invalid pose {pose_key!r} for {slug}")
      if not isinstance(choice, dict):
        raise ValueError(f"invalid selected variant for {slug} pose {pose_key}")

      source = validate_selected_asset(review_dir, str(choice.get("image", "")))
      pose = int(pose_key)
      destination = illustrations / expected_filename(str(slug), pose)

      source_hash = hashlib.sha256(source.read_bytes()).hexdigest()

      if destination.is_file():
        destination_hash = hashlib.sha256(destination.read_bytes()).hexdigest()
        if source_hash == destination_hash:
          unchanged += 1
          applied.append({
            "slug": slug,
            "pose": pose,
            "action": "unchanged",
            "destination": str(destination),
          })
          continue

        backup_dir.mkdir(parents=True, exist_ok=True)
        backup_target = backup_dir / destination.name
        shutil.copy2(destination, backup_target)
        backup_used = True
        replaced += 1
        action = "replaced"
      else:
        added += 1
        action = "added"

      temporary = destination.with_suffix(destination.suffix + ".tmp")
      shutil.copy2(source, temporary)
      # Validate copied bytes before atomic replacement.
      png_dimensions(temporary.read_bytes())
      temporary.replace(destination)

      applied.append({
        "slug": slug,
        "pose": pose,
        "action": action,
        "destination": str(destination),
      })

  masks_status = "not run"
  masks_output = ""
  masks_script = repo_root / "avian" / "scripts" / "build_masks.py"

  if added or replaced:
    if masks_script.is_file():
      proc = subprocess.run(
          [sys.executable, str(masks_script)],
          cwd=str(repo_root),
          capture_output=True,
          text=True,
          timeout=300,
      )
      masks_output = ((proc.stdout or "") + ("\n" + proc.stderr if proc.stderr else "")).strip()
      if proc.returncode == 0:
        masks_status = "regenerated"
      else:
        masks_status = f"failed (exit {proc.returncode})"
    else:
      masks_status = "build_masks.py not found"
  else:
    masks_status = "unchanged; regeneration unnecessary"

  return {
    "ok": True,
    "added": added,
    "replaced": replaced,
    "unchanged": unchanged,
    "backup_dir": str(backup_dir) if backup_used else "",
    "masks_status": masks_status,
    "masks_output": masks_output[-4000:],
    "applied": applied,
  }


def serve_review_site(
    *,
    review_dir: Path,
    illustrations: Path,
    repo_root: Path,
    host: str,
    port: int,
    open_browser: bool,
) -> None:
  """Serve the generated review UI and a same-origin local apply endpoint."""
  review_root = review_dir.resolve()
  token = secrets.token_urlsafe(32)

  class ReviewHandler(BaseHTTPRequestHandler):
    server_version = "AvianReview/2.2.1"

    def log_message(self, fmt: str, *args: Any) -> None:
      print("[server] " + (fmt % args), file=sys.stderr)

    def _json(self, status: int, payload: dict[str, Any]) -> None:
      body = json.dumps(payload, ensure_ascii=False).encode("utf-8")
      self.send_response(status)
      self.send_header("Content-Type", "application/json; charset=utf-8")
      self.send_header("Content-Length", str(len(body)))
      self.send_header("Cache-Control", "no-store")
      self.end_headers()
      self.wfile.write(body)

    def _serve_file(self, path: Path, content_type: str) -> None:
      try:
        data = path.read_bytes()
      except OSError:
        self.send_error(404)
        return
      self.send_response(200)
      self.send_header("Content-Type", content_type)
      self.send_header("Content-Length", str(len(data)))
      self.send_header("Cache-Control", "no-store")
      self.end_headers()
      self.wfile.write(data)

    def do_GET(self) -> None:
      parsed = urllib.parse.urlsplit(self.path)
      request_path = urllib.parse.unquote(parsed.path)

      if request_path in ("/", "/index.html"):
        index = review_root / "index.html"
        try:
          page = index.read_text(encoding="utf-8")
        except OSError:
          self.send_error(404)
          return
        injection = (
            "<script>window.AVIAN_REVIEW_TOKEN="
            + json.dumps(token)
            + ";</script>"
        )
        page = page.replace("</head>", injection + "</head>", 1)
        data = page.encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)
        return

      relative = request_path.lstrip("/")
      candidate = (review_root / relative).resolve()
      try:
        candidate.relative_to(review_root)
      except ValueError:
        self.send_error(403)
        return

      if candidate.suffix.lower() == ".png":
        self._serve_file(candidate, "image/png")
      elif candidate.suffix.lower() == ".json":
        self._serve_file(candidate, "application/json; charset=utf-8")
      elif candidate.suffix.lower() == ".csv":
        self._serve_file(candidate, "text/csv; charset=utf-8")
      else:
        self.send_error(404)

    def do_POST(self) -> None:
      parsed = urllib.parse.urlsplit(self.path)
      if parsed.path != "/api/apply":
        self.send_error(404)
        return

      # The endpoint only exists on the local server, is same-origin from
      # the review page, and additionally requires a per-run random token.
      if self.headers.get("X-Avian-Review-Token", "") != token:
        self._json(403, {"ok": False, "error": "invalid review token"})
        return

      try:
        length = int(self.headers.get("Content-Length", "0"))
      except ValueError:
        self._json(400, {"ok": False, "error": "invalid content length"})
        return

      if length <= 0 or length > 5_000_000:
        self._json(400, {"ok": False, "error": "invalid request size"})
        return

      try:
        body = self.rfile.read(length)
        payload = json.loads(body.decode("utf-8"))
        result = apply_selection_to_project(
            payload.get("selections", {}),
            review_dir=review_root,
            illustrations=illustrations,
            repo_root=repo_root,
        )
      except Exception as exc:
        self._json(400, {"ok": False, "error": str(exc)})
        return

      self._json(200, result)

  server = ThreadingHTTPServer((host, port), ReviewHandler)
  url = f"http://{host}:{server.server_port}/"

  print()
  print("=== Local review server ===")
  print(f"URL:                         {url}")
  print("Apply target:                avian/assets/illustrations/")
  print("Press Ctrl+C to stop.")

  if open_browser:
    threading.Timer(0.5, lambda: webbrowser.open(url)).start()

  try:
    server.serve_forever()
  except KeyboardInterrupt:
    print("\n[server] stopped")
  finally:
    server.server_close()


def args_parser() -> argparse.Namespace:
  parser = argparse.ArgumentParser()
  parser.add_argument("--region", required=True)
  parser.add_argument("--locale", default="ca")
  parser.add_argument("--labels", type=Path)
  parser.add_argument("--ebird-key", default="")
  parser.add_argument("--github-token", default="")
  parser.add_argument("--refresh", action="store_true", help="re-scan GitHub forks; omit to reuse a complete cache")
  parser.add_argument("--refresh-assets", action="store_true")
  parser.add_argument("--cache-hours", type=int, default=24)
  parser.add_argument("--workers", type=int, default=6)
  parser.add_argument("--max-species", type=int, default=0)
  parser.add_argument("--serve", action="store_true", help="generate/update the review, then serve it locally with apply support")
  parser.add_argument("--serve-existing", action="store_true", help="serve an already generated review without eBird/GitHub requests")
  parser.add_argument("--host", default="127.0.0.1", help="local review server host (default: 127.0.0.1)")
  parser.add_argument("--port", type=int, default=8765, help="local review server port (default: 8765)")
  parser.add_argument("--no-browser", action="store_true", help="do not automatically open the review page")
  parser.add_argument("--version", action="version", version=VERSION)
  return parser.parse_args()

def main() -> int:
  args = args_parser()
  root = project_root()
  avian = root / "avian"
  illustrations = avian / "assets" / "illustrations"
  reports = avian / "reports"
  review_dir = reports / f"illustration-review-{safe_name(args.region)}"
  assets = review_dir / "assets"
  cache = reports / "fork-illustration-index-v2.json"

  review_dir.mkdir(parents=True, exist_ok=True)
  assets.mkdir(parents=True, exist_ok=True)

  print(f"[review] AvianVisitors illustration reviewer v{VERSION}", file=sys.stderr)
  print(f"[project] root: {root}", file=sys.stderr)

  if args.serve_existing:
    index_path = review_dir / "index.html"
    data_path = review_dir / "review-data.json"
    if not index_path.is_file() or not data_path.is_file():
      print(
          f"error: existing review not found at {review_dir}. "
          "Run the normal review generation first.",
          file=sys.stderr,
      )
      return 2

    serve_review_site(
        review_dir=review_dir,
        illustrations=illustrations,
        repo_root=root,
        host=args.host,
        port=args.port,
        open_browser=not args.no_browser,
    )
    return 0

  ebird = resolve_ebird(args.ebird_key, root)
  github = resolve_github(args.github_token, root)

  print(f"[auth] eBird credentials: {ebird.source if ebird else 'NOT FOUND'}", file=sys.stderr)
  print(f"[auth] GitHub credentials: {github.source if github else 'NOT FOUND'}", file=sys.stderr)

  if not ebird:
    print("error: eBird credential not found.", file=sys.stderr)
    return 2
  if not github:
    print("error: GitHub credential not found. Anonymous scanning is disabled.", file=sys.stderr)
    return 2

  try:
    remaining, limit, reset = github_rate_limit(github.value)
  except Exception as exc:
    print(f"error: GitHub authentication failed: {exc}", file=sys.stderr)
    return 2

  print(f"[github] API rate limit: {remaining}/{limit} remaining", file=sys.stderr)
  if remaining < 150:
    reset_text = time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(reset)) if reset else "unknown"
    print(f"error: only {remaining} GitHub API requests remain; reset {reset_text}.", file=sys.stderr)
    return 2

  print(f"[ebird] loading species for {args.region}...", file=sys.stderr)
  try:
    species, unresolved = ebird_species(args.region, args.locale, ebird.value)
  except Exception as exc:
    print(f"error: eBird request failed: {exc}", file=sys.stderr)
    return 2

  if unresolved:
    print(f"[ebird] warning: {len(unresolved)} unresolved code(s) in taxonomy", file=sys.stderr)

  if args.labels:
    labels = args.labels.expanduser()
    if not labels.is_file():
      print(f"error: labels file not found: {labels}", file=sys.stderr)
      return 2
    allowed = parse_labels(labels)
    before = len(species)
    species = [s for s in species if s.slug in allowed]
    print(f"[labels] {len(species)}/{before} regional species kept", file=sys.stderr)

  if args.max_species > 0:
    species = species[:args.max_species]

  print(f"[ebird] final species count: {len(species)}", file=sys.stderr)

  try:
    repo_index = load_index(cache, github.value, args.refresh, args.cache_hours)
  except Exception as exc:
    print(f"error: GitHub scan failed: {exc}", file=sys.stderr)
    return 2

  problems = [
    f"{repo}: {info.get('error') or 'truncated tree'}"
    for repo, info in repo_index["repos"].items()
    if info.get("error") or info.get("truncated")
  ]
  if problems:
    print("error: repository index is incomplete; review not generated.", file=sys.stderr)
    for problem in problems[:20]:
      print(f"  - {problem}", file=sys.stderr)
    return 1

  occurrences = collect_occurrences(species, repo_index)
  groups = group_variants(occurrences)

  print(f"[review] remote file occurrences found: {len(occurrences)}", file=sys.stderr)
  print("[review] image transport: raw.githubusercontent.com (REST API not used for PNG downloads)", file=sys.stderr)
  print(
      f"[review] distinct remote images to download: {len(groups)} "
      f"(deduplicated from {len(occurrences)} fork occurrences)",
      file=sys.stderr,
  )

  downloaded: list[dict[str, Any]] = []
  errors: list[dict[str, Any]] = []

  with ThreadPoolExecutor(max_workers=max(1, min(args.workers, 12))) as pool:
    futures = {
      pool.submit(download_variant, group, assets, github.value, args.refresh_assets): group
      for group in groups
    }
    total = len(futures)

    for n, future in enumerate(as_completed(futures), 1):
      group = futures[future]
      try:
        downloaded.append(future.result())
      except Exception as exc:
        errors.append({
          "slug": group["slug"],
          "pose": group["pose"],
          "blob_sha": group["blob_sha"],
          "sources": group["sources"],
          "error": str(exc),
        })
      if n % 25 == 0 or n == total:
        print(f"[review] downloaded/checked {n}/{total} distinct image(s)", file=sys.stderr)

  report = make_report(
      species, downloaded, illustrations, review_dir, repo_index,
      args.region, args.locale, unresolved, errors, len(occurrences),
  )

  (review_dir / "review-data.json").write_text(
      json.dumps(report, ensure_ascii=False, indent=2) + "\n",
      encoding="utf-8",
      )
  (review_dir / "errors.json").write_text(
      json.dumps(errors, ensure_ascii=False, indent=2) + "\n",
      encoding="utf-8",
      )
  write_summary(review_dir / "summary.csv", report)
  (review_dir / "index.html").write_text(build_html(report), encoding="utf-8")

  print()
  print("=== AvianVisitors illustration review ===")
  print(f"Version:                  {VERSION}")
  print(f"Species:                  {report['counts']['species']}")
  print(f"Repositories scanned:     {report['counts']['repos_scanned']}")
  print(f"Remote occurrences:       {report['counts']['remote_occurrences']}")
  print(f"Distinct variants:        {report['counts']['distinct_variants']}")
  print(f"Download errors:          {report['counts']['download_errors']}")
  print(f"Website:                  {review_dir / 'index.html'}")
  print(f"Summary:                  {review_dir / 'summary.csv'}")
  print(f"Data:                     {review_dir / 'review-data.json'}")

  if args.serve and not errors:
    serve_review_site(
        review_dir=review_dir,
        illustrations=illustrations,
        repo_root=root,
        host=args.host,
        port=args.port,
        open_browser=not args.no_browser,
    )

  return 1 if errors else 0

if __name__ == "__main__":
  raise SystemExit(main())
