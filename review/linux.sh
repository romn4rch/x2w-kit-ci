#!/usr/bin/env bash
# Independent review of one pull request head on Linux: LLVM 15 binary fixtures, Python controls,
# form coverage, and a truncation -> round-to-nearest negative control.
set -u
OUT=/tmp/review-out
mkdir -p "$OUT"
HERE="$(cd "$(dirname "$0")" && pwd)"
. "$HERE/target.env"
log() { echo "$*" | tee -a "$OUT/summary.txt"; }
run() {
  local name=$1; shift
  local t0; t0=$(date +%s)
  "$@" > "$OUT/$name.txt" 2>&1
  local code=$?
  log "$name: exit $code, $(( $(date +%s) - t0 )) s"
  return 0
}
log "runner: $(lsb_release -ds 2>/dev/null) $(uname -m)"
git clone -q https://github.com/R0Y00/Xbox2Windows /tmp/src
cd /tmp/src
git fetch -q origin "pull/$PR/head:pr$PR"
log "pr head ref: $(git rev-parse "pr$PR")"
git checkout -q "$SHA"
log "head under test: $(git rev-parse HEAD)"
log "merge base with main: $(git merge-base HEAD origin/main)"
log "current main: $(git rev-parse origin/main)"
git checkout -q -b mergetest origin/main
if git -c user.name=r -c user.email=r@example.invalid merge --no-commit --no-ff "$SHA" > "$OUT/merge.txt" 2>&1; then
  log "merge into current main: clean"
else
  log "merge into current main: conflicts in $(git diff --name-only --diff-filter=U | tr '\n' ' ')"
fi
git merge --abort > /dev/null 2>&1 || git reset -q --hard
git checkout -q "$SHA"
sudo apt-get update -q > "$OUT/apt.txt" 2>&1
sudo apt-get install -y --no-install-recommends llvm-15 spirv-tools spirv-cross >> "$OUT/apt.txt" 2>&1
log "llvm-mc-15: $(llvm-mc-15 --version 2>&1 | grep -i 'version' | head -1 | sed 's/^ *//')"
python3 -m venv /tmp/venv
/tmp/venv/bin/python -m pip install -q -r requirements-dev.txt > "$OUT/pip.txt" 2>&1
PY=/tmp/venv/bin/python
log "python: $($PY --version 2>&1)"
run llvm15-pixel-aot-binary $PY -B tests/pixel_aot_check.py binary llvm-mc-15 llvm-objcopy-15 libLLVM-15.so.1
run pixel-aot-controls $PY -B tests/pixel_aot_check.py
run form-coverage $PY -B tests/form_coverage_check.py
run llvm15-rdna2-tools env LLVM_LIB=libLLVM-15.so.1 LLVM_MC=llvm-mc-15 LLVM_OBJCOPY=llvm-objcopy-15 $PY -B tests/rdna2_tools_check.py
run docs-links $PY -B tests/docs_links_check.py
run bidi $PY -B tests/bidi_controls_check.py
# Negative control: truncation replaced by round to nearest in the emitted lowering.
if grep -q 'int(trunc(hs{i}))' tools/pixel_aot.py; then
  sed -i 's/int(trunc(hs{i}))/int(round(hs{i}))/' tools/pixel_aot.py
  log "mutation applied: $(git diff --stat | tail -1)"
  run mutated-pixel-aot-controls $PY -B tests/pixel_aot_check.py
  run mutated-llvm15-pixel-aot-binary $PY -B tests/pixel_aot_check.py binary llvm-mc-15 llvm-objcopy-15 libLLVM-15.so.1
  git checkout -q -- tools/pixel_aot.py
  log "mutation restored: [$(git status --porcelain --untracked-files=no)]"
else
  log "mutation pattern not found"
fi
exit 0
