#!/usr/bin/env bash
#
# bump-version.sh — check snap/snapcraft.yaml's exact-pinned apt packages
# against the upstream apt repositories declared in package-repositories,
# and bump any pin (and, if the version-source package moved, the top-level
# `version:` field) that is out of date.
#
# Usage:
#   scripts/bump-version.sh            # apply updates in place, print a summary
#   scripts/bump-version.sh --check    # report only; exit 10 if updates exist
#
# Requires: python3 with PyYAML, dpkg (for authoritative version comparison).
set -euo pipefail

# ---- config -----------------------------------------------------------
# VERSION_SOURCE_PKG is the stage-packages pin that this snap's top-level
# `version:` field is derived from. VERSION_STRIP_DEB_REVISION controls
# whether the trailing Debian revision (the final -<digits>) is dropped
# when deriving `version:` from that pin. Family convention:
#   MySQL-family repos:            true   (8.4.11-11-1.resolute -> 8.4.11-11)
#   PSMDB / valkey / PDPG repos:   false  (1:9.1.1-1.resolute   -> 9.1.1-1)
VERSION_SOURCE_PKG="percona-xtradb-cluster-server"
VERSION_STRIP_DEB_REVISION="true"
# ---- end config ---------------------------------------------------------

usage() {
  cat <<'USAGE'
Usage: bump-version.sh [--check]

  (no options)  Fetch upstream apt indexes, bump any out-of-date pin in
                snap/snapcraft.yaml in place, print a summary table, and
                exit 0 (whether or not anything changed).

  --check       Do not write anything. Print the same summary table of
                available updates. Exit 0 if everything is already
                up to date, exit 10 if updates are available, and any
                other nonzero exit code means the check itself failed.
USAGE
}

CHECK_ONLY="false"
for arg in "$@"; do
  case "$arg" in
    --check)
      CHECK_ONLY="true"
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "bump-version.sh: unknown argument: $arg" >&2
      usage >&2
      exit 1
      ;;
  esac
done

SCRIPT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" >/dev/null 2>&1 && pwd)"
REPO_ROOT="$(cd -- "${SCRIPT_DIR}/.." >/dev/null 2>&1 && pwd)"
SNAPCRAFT_YAML="${REPO_ROOT}/snap/snapcraft.yaml"

if [[ ! -f "${SNAPCRAFT_YAML}" ]]; then
  echo "bump-version.sh: cannot find snap/snapcraft.yaml at ${SNAPCRAFT_YAML}" >&2
  exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
  echo "bump-version.sh: python3 is required but was not found on PATH" >&2
  exit 1
fi

if ! command -v dpkg >/dev/null 2>&1; then
  echo "bump-version.sh: dpkg is required (for --compare-versions) but was not found on PATH" >&2
  exit 1
fi

exec python3 - "${SNAPCRAFT_YAML}" "${VERSION_SOURCE_PKG}" "${VERSION_STRIP_DEB_REVISION}" "${CHECK_ONLY}" <<'PYEOF'
import gzip
import os
import re
import subprocess
import sys
import tempfile
import time
import urllib.error
import urllib.request

try:
    import yaml
except ImportError:
    print("bump-version.sh: python3 module 'yaml' (PyYAML) is required", file=sys.stderr)
    sys.exit(1)

SNAPCRAFT_YAML, VERSION_SOURCE_PKG, STRIP_DEB_REVISION_STR, CHECK_ONLY_STR = sys.argv[1:5]
STRIP_DEB_REVISION = STRIP_DEB_REVISION_STR.strip().lower() == "true"
CHECK_ONLY = CHECK_ONLY_STR.strip().lower() == "true"

# Suffixes this snap family appends to a package's own upstream version to
# mark the Ubuntu release it was built for. Extend this if a sibling repo
# targets a different Ubuntu codename.
KNOWN_SUITE_SUFFIXES = (".resolute", ".noble")

RETRY_ATTEMPTS = 3
RETRY_BACKOFF_SECONDS = 2


class BumpError(Exception):
    """A user-facing, non-traceback error."""


def fail(message):
    raise BumpError(message)


def dpkg_compare(a, op, b):
    """Run `dpkg --compare-versions a op b`.

    dpkg exits 0/1 for true/false — but it *also* exits 0 or 1 (never a
    distinct code) when either version has bad syntax, after printing a
    "has bad syntax" warning to stderr and falling back to some best-effort
    ordering. Silently trusting that fallback would let a malformed
    upstream version get treated as "not newer" forever, so both that
    warning and any other unexpected exit code are treated as a hard
    failure instead of a quiet false.
    """
    result = subprocess.run(
        ["dpkg", "--compare-versions", a, op, b],
        stdout=subprocess.DEVNULL,
        stderr=subprocess.PIPE,
        text=True,
    )
    stderr = (result.stderr or "").strip()
    if "bad syntax" in stderr:
        fail(f"dpkg rejected a version while comparing '{a}' {op} '{b}': {stderr}")
    if result.returncode not in (0, 1):
        fail(
            f"dpkg --compare-versions '{a}' {op} '{b}' exited {result.returncode} "
            f"unexpectedly: {stderr or '(no diagnostic on stderr)'}"
        )
    return result.returncode == 0


def dpkg_max(current, candidates):
    """Return the dpkg-greatest version among [current] + candidates."""
    best = current
    for cand in candidates:
        if dpkg_compare(cand, "gt", best):
            best = cand
    return best


def version_from_pin(pin, strip_deb_revision):
    """Derive the snap's top-level `version:` value from a stage-packages pin.

    Rule: strip a leading epoch (`N:`), strip a trailing known suite suffix
    (`.resolute`, `.noble`), and — only when strip_deb_revision is true —
    also strip the final `-<digits>` Debian revision.
    """
    v = pin
    if ":" in v:
        epoch, rest = v.split(":", 1)
        if epoch.isdigit():
            v = rest
    for suffix in KNOWN_SUITE_SUFFIXES:
        if v.endswith(suffix):
            v = v[: -len(suffix)]
            break
    if strip_deb_revision:
        v = re.sub(r"-\d+$", "", v)
    return v


def load_yaml(path):
    with open(path, "r", newline="") as f:
        raw = f.read()
    try:
        data = yaml.safe_load(raw)
    except yaml.YAMLError as e:
        fail(f"could not parse {path} as YAML: {e}")
    if not isinstance(data, dict):
        fail(f"{path} did not parse to a YAML mapping at the top level")
    lines = raw.splitlines(keepends=True)
    return data, lines


def collect_pins(data):
    """name -> {"version": str, "parts": [part_name, ...]}"""
    pins = {}
    parts = data.get("parts") or {}
    if not isinstance(parts, dict):
        fail("snapcraft.yaml 'parts' is not a mapping")
    for part_name, part in parts.items():
        if not isinstance(part, dict):
            continue
        stage_packages = part.get("stage-packages") or []
        if not isinstance(stage_packages, list):
            continue
        for entry in stage_packages:
            if not isinstance(entry, str) or "=" not in entry:
                continue
            name, _, ver = entry.partition("=")
            name = name.strip()
            ver = ver.strip()
            if name in pins and pins[name]["version"] != ver:
                fail(
                    f"package '{name}' is pinned to conflicting versions across "
                    f"parts: '{pins[name]['version']}' (part '{pins[name]['parts'][0]}') "
                    f"vs '{ver}' (part '{part_name}')"
                )
            if name in pins:
                pins[name]["parts"].append(part_name)
            else:
                pins[name] = {"version": ver, "parts": [part_name]}
    return pins


def collect_repo_groups(data):
    """Return an ordered list of {"url", "suite", "components": [...]}
    groups, one per (repo entry, suite) pair found in package-repositories,
    with each group's components kept in declared order — the order
    component precedence is applied in; see fetch_all_candidates()."""
    repos = data.get("package-repositories") or []
    if not isinstance(repos, list):
        fail("snapcraft.yaml 'package-repositories' is not a list")
    groups = []
    for repo in repos:
        if not isinstance(repo, dict):
            continue
        if repo.get("type") != "apt":
            print(
                f"bump-version.sh: skipping non-apt package-repositories entry: {repo!r}",
                file=sys.stderr,
            )
            continue
        url = repo.get("url")
        suites = repo.get("suites")
        components = repo.get("components")
        if isinstance(suites, str):
            suites = [suites]
        if isinstance(components, str):
            components = [components]
        if not url or not suites or not components:
            print(
                f"bump-version.sh: skipping apt entry missing url/suites/components: {repo!r}",
                file=sys.stderr,
            )
            continue
        for suite in suites:
            groups.append({"url": url, "suite": suite, "components": list(components)})
    return groups


def index_url(url, suite, component):
    return f"{url.rstrip('/')}/dists/{suite}/{component}/binary-amd64/Packages.gz"


def fetch_bytes(url):
    last_err = None
    for attempt in range(1, RETRY_ATTEMPTS + 1):
        try:
            req = urllib.request.Request(url, headers={"User-Agent": "bump-version.sh"})
            with urllib.request.urlopen(req, timeout=60) as resp:
                return resp.read()
        except (urllib.error.URLError, OSError, TimeoutError) as e:
            last_err = e
            if attempt < RETRY_ATTEMPTS:
                time.sleep(RETRY_BACKOFF_SECONDS * attempt)
    fail(f"failed to fetch {url} after {RETRY_ATTEMPTS} attempts: {last_err}")


def parse_packages(text):
    """Parse a Debian Packages file into {package_name: [version, ...]}."""
    result = {}
    pkg = None
    ver = None
    for line in text.split("\n"):
        if line[:1] in (" ", "\t"):
            continue  # continuation line of a multi-line field
        if line == "":
            if pkg and ver:
                result.setdefault(pkg, []).append(ver)
            pkg = ver = None
            continue
        if ":" not in line:
            continue
        field, _, value = line.partition(":")
        field = field.strip()
        value = value.strip()
        if field == "Package":
            pkg = value
        elif field == "Version":
            ver = value
    if pkg and ver:
        result.setdefault(pkg, []).append(ver)
    return result


def rewrite_pin_line(body, name, old_version, new_version):
    pattern = re.compile(
        r"^(?P<indent>\s*-\s*)" + re.escape(f"{name}={old_version}") + r"(?P<rest>\s*(#.*)?)$"
    )
    m = pattern.match(body)
    if not m:
        return None
    return f"{m.group('indent')}{name}={new_version}{m.group('rest')}"


def split_eol(line):
    if line.endswith("\r\n"):
        return line[:-2], "\r\n"
    if line.endswith("\n"):
        return line[:-1], "\n"
    return line, ""


def rewrite_version_line(body, new_value):
    m = re.match(r"^(version:\s*)'([^']*)'\s*$", body)
    if m:
        return f"{m.group(1)}'{new_value}'"
    m = re.match(r'^(version:\s*)"([^"]*)"\s*$', body)
    if m:
        return f'{m.group(1)}"{new_value}"'
    m = re.match(r"^(version:\s*)(\S+)\s*$", body)
    if m:
        return f"{m.group(1)}{new_value}"
    return None


def print_table(rows, header):
    if not rows:
        return
    print(header)
    name_w = max(len(r[0]) for r in rows)
    old_w = max(len(r[1]) for r in rows)
    for name, old, new in rows:
        print(f"  {name.ljust(name_w)}  {old.ljust(old_w)}  -> {new}")


def run_self_check(pins, current_version):
    """Confirm VERSION_SOURCE_PKG's pin still derives the recorded
    version:. Called before any network access or write, so a broken
    derivation rule fails fast with nothing touched.
    """
    if VERSION_SOURCE_PKG not in pins:
        fail(
            f"VERSION_SOURCE_PKG '{VERSION_SOURCE_PKG}' has no exact-pinned entry in "
            "any part's stage-packages"
        )
    source_pin = pins[VERSION_SOURCE_PKG]["version"]
    derived_version = version_from_pin(source_pin, STRIP_DEB_REVISION)
    if derived_version != current_version:
        fail(
            "self-check failed: deriving the snap version from the "
            f"'{VERSION_SOURCE_PKG}' pin ('{source_pin}') gives '{derived_version}', "
            f"but snapcraft.yaml's version: is '{current_version}'. The version-"
            "derivation rule (epoch/suite-suffix/deb-revision stripping) no longer "
            "matches upstream's version format for this package. Nothing was changed. "
            "Update VERSION_SOURCE_PKG / VERSION_STRIP_DEB_REVISION or the derivation "
            "rule in scripts/bump-version.sh before running it again."
        )


def get_parsed_index(url, cache):
    """Fetch+parse `url`'s Packages.gz once, caching by URL so a component
    shared by more than one (url, suite) group is only fetched once."""
    if url not in cache:
        raw = fetch_bytes(url)
        try:
            text = gzip.decompress(raw).decode("utf-8", errors="replace")
        except OSError as e:
            fail(f"failed to gunzip {url}: {e}")
        cache[url] = parse_packages(text)
    return cache[url]


def resolve_group(group, pins, cache, candidates):
    """Apply component precedence within one (url, suite) group: a pinned
    package takes candidates only from the first component, in declared
    order, whose index contains it at all — later components in this same
    group are ignored for that package once an earlier one has it.

    This is what lets a package that's intentionally sourced from a later
    component (e.g. percona-valkey-ldap, published in `testing` only, as of
    writing) resolve correctly, while packages that already exist in an
    earlier component (e.g. `main`) ignore newer builds that happen to also
    sit in a later one purely because it was declared too. If Percona later
    syncs ldap's Ubuntu builds into `main`, this rule switches ldap to
    tracking `main` automatically — no code change needed here.
    """
    resolved = set()
    for component in group["components"]:
        url = index_url(group["url"], group["suite"], component)
        parsed = get_parsed_index(url, cache)
        for name in pins:
            if name in resolved:
                continue
            if name in parsed:
                candidates[name].extend(parsed[name])
                resolved.add(name)


def fetch_all_candidates(data, pins):
    """Fetch every apt index declared in package-repositories and return
    {pinned_name: [version, ...]}, with component precedence applied per
    (url, suite) group (see resolve_group()) and then merged across
    different groups/repo entries — i.e. dpkg-max in compute_updates() is
    only ever compared among candidates that already survived precedence."""
    groups = collect_repo_groups(data)
    if not groups:
        fail("no apt package-repositories entries found to check pins against")

    cache = {}
    candidates = {name: [] for name in pins}
    for group in groups:
        resolve_group(group, pins, cache, candidates)
    return candidates


def compute_updates(pins, candidates):
    """Return (updates, not_found).

    updates: sorted [(name, old, new), ...] for pins with a dpkg-newer
      candidate available in at least one fetched index.
    not_found: pin names with zero candidates in any fetched index.
    """
    updates = []
    not_found = []
    for name, info in sorted(pins.items()):
        old = info["version"]
        cands = candidates[name]
        if not cands:
            not_found.append(name)
            continue
        best = dpkg_max(old, cands)
        if best != old:
            updates.append((name, old, best))
    return updates, not_found


def warn_not_found(not_found):
    for name in not_found:
        print(
            f"bump-version.sh: warning: pinned package '{name}' was not found in any "
            "fetched apt index; leaving its pin unchanged",
            file=sys.stderr,
        )


def report_not_found(not_found):
    if not_found:
        print(
            f"bump-version.sh: {len(not_found)} pinned package(s) not found in any index: "
            + ", ".join(not_found)
        )


def apply_rewrite(raw_lines, updates, current_version):
    """Rewrite raw_lines for every update and, if VERSION_SOURCE_PKG moved,
    the top-level version: line. Returns
    (new_lines, version_bumped, new_version_value, source_update).
    """
    new_lines = list(raw_lines)
    for name, old, new in updates:
        replaced = 0
        for i, line in enumerate(new_lines):
            body, eol = split_eol(line)
            rewritten = rewrite_pin_line(body, name, old, new)
            if rewritten is not None:
                new_lines[i] = rewritten + eol
                replaced += 1
        if replaced == 0:
            fail(
                f"internal error: could not find a raw line matching "
                f"'{name}={old}' to rewrite (yaml parse and raw text disagree)"
            )

    version_bumped = False
    new_version_value = current_version
    source_update = next((u for u in updates if u[0] == VERSION_SOURCE_PKG), None)
    if source_update is not None:
        new_version_value = version_from_pin(source_update[2], STRIP_DEB_REVISION)
        replaced = 0
        for i, line in enumerate(new_lines):
            body, eol = split_eol(line)
            rewritten = rewrite_version_line(body, new_version_value)
            if rewritten is not None and body.lstrip().startswith("version:"):
                new_lines[i] = rewritten + eol
                replaced += 1
        if replaced != 1:
            fail(
                f"internal error: expected exactly one top-level 'version:' line, "
                f"found {replaced}"
            )
        version_bumped = True

    return new_lines, version_bumped, new_version_value, source_update


def post_write_sanity_ok(pins, source_update, new_version_value):
    """Re-derive from what was just written, as an internal-bug detector
    (data-format drift is already caught by run_self_check() beforehand;
    this only catches a bug in bump-version.sh's own rewrite logic)."""
    final_pin = source_update[2] if source_update is not None else pins[VERSION_SOURCE_PKG]["version"]
    return version_from_pin(final_pin, STRIP_DEB_REVISION) == new_version_value


TABLE_HEADER = "Package                          Old                   New"


def load_pins_and_current_version(path):
    data, raw_lines = load_yaml(path)
    pins = collect_pins(data)
    if not pins:
        fail("no exact-pinned (name=version) stage-packages entries found in snapcraft.yaml")
    current_version = data.get("version")
    if current_version is None:
        fail("snapcraft.yaml has no top-level 'version:' field")
    return data, raw_lines, pins, str(current_version)


def atomic_write(path, content):
    """Write `content` to `path` without ever leaving a partially-written
    file if the process dies mid-write: write to a temp file in the same
    directory (so the final step is a same-filesystem rename, which is
    atomic), then os.replace() it over `path`. Uses newline="" like the
    read side (see load_yaml()), so line endings are written back exactly
    as-is — a CRLF file stays CRLF, it is never translated to LF.
    """
    directory = os.path.dirname(path) or "."
    fd, tmp_path = tempfile.mkstemp(prefix=".bump-version.", suffix=".tmp", dir=directory)
    try:
        with os.fdopen(fd, "w", newline="") as f:
            f.write(content)
        os.replace(tmp_path, path)
    except BaseException:
        try:
            os.unlink(tmp_path)
        except OSError:
            pass
        raise


def write_updates(raw_lines, updates, current_version, pins):
    """Rewrite the file for `updates`, then re-verify with
    post_write_sanity_ok(). Returns (version_bumped, new_version_value) on
    success. On an internal sanity-check failure, prints a CRITICAL message
    and returns None — note the file has already been written at that
    point; see post_write_sanity_ok()'s docstring for why that can't be
    helped here.
    """
    new_lines, version_bumped, new_version_value, source_update = apply_rewrite(
        raw_lines, updates, current_version
    )

    atomic_write(SNAPCRAFT_YAML, "".join(new_lines))

    if not post_write_sanity_ok(pins, source_update, new_version_value):
        print(
            "bump-version.sh: CRITICAL: post-write sanity check failed — the file "
            f"was already rewritten, but re-deriving from the new "
            f"'{VERSION_SOURCE_PKG}' pin does not match the written version "
            f"'{new_version_value}'. This indicates a bug in bump-version.sh "
            f"itself. Please inspect and, if needed, revert {SNAPCRAFT_YAML}.",
            file=sys.stderr,
        )
        return None
    return version_bumped, new_version_value


def main():
    data, raw_lines, pins, current_version = load_pins_and_current_version(SNAPCRAFT_YAML)

    run_self_check(pins, current_version)

    candidates = fetch_all_candidates(data, pins)
    updates, not_found = compute_updates(pins, candidates)
    warn_not_found(not_found)

    if CHECK_ONLY:
        if not updates:
            print("bump-version.sh: already up to date")
            report_not_found(not_found)
            return 0
        print("bump-version.sh: updates available (--check, nothing written):")
        print_table(updates, TABLE_HEADER)
        report_not_found(not_found)
        return 10

    if not updates:
        print("bump-version.sh: already up to date")
        report_not_found(not_found)
        return 0

    result = write_updates(raw_lines, updates, current_version, pins)
    if result is None:
        return 3
    version_bumped, new_version_value = result

    print("bump-version.sh: applied updates:")
    print_table(updates, TABLE_HEADER)
    if version_bumped:
        print(f"bump-version.sh: version: '{current_version}' -> '{new_version_value}'")
    report_not_found(not_found)
    return 0


try:
    sys.exit(main())
except BumpError as e:
    print(f"bump-version.sh: error: {e}", file=sys.stderr)
    sys.exit(1)
PYEOF
