#!/usr/bin/env bash
# Import successful job outputs, then explicitly assemble/verify the full matrix.
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
run="${1:?Usage: tool/import_ci_artifacts.sh <GitHub Actions run ID>}"
[[ "$run" =~ ^[0-9]+$ ]] || exit 64
repo=Telosnex/super_native_extensions
mkdir -p "$root/build"
dir="$(mktemp -d "$root/build/import-$run.XXXXXX")"
trap 'rm -rf "$dir"' EXIT
gh run download "$run" --repo "$repo" --dir "$dir" --pattern 'sne-*'
gh api "repos/$repo/actions/runs/$run" > "$dir/run.json"
python3 - "$dir" "$root" <<'PY'
import hashlib, json, pathlib, shutil, sys
source, root = map(pathlib.Path, sys.argv[1:])
run = json.loads((source / 'run.json').read_text())
for directory in sorted(source.glob('sne-*')):
    target = directory.name.removeprefix('sne-')
    metadata = json.loads((directory / 'build.json').read_text())
    relative = pathlib.PurePosixPath(metadata['path'])
    assert len(relative.parts) == 2 and relative.parts[0] == target
    binary = directory / relative.name
    assert hashlib.sha256(binary.read_bytes()).hexdigest() == metadata['sha256']
    metadata['ci_run'] = run['html_url']
    metadata['build_revision'] = run['head_sha']
    destination = root / 'native_artifacts' / target
    destination.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(binary, destination / relative.name)
    (destination / 'build.json').write_text(json.dumps(metadata, indent=2) + '\n')
    print('Imported', target, metadata['sha256'])
PY
