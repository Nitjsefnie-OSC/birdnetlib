#!/usr/bin/env bash
# Offline contract for scripts/osc-target-ref.sh plus the single-canonical-
# wrapper invariant. Usage: osc-target-ref-contract.sh <scan_root>
# Proves: valid-ref success; invalid-ref, option-injection, ambiguous/DWIM
# rejection; 40-hex branch/tag shadowing rejection; checkout-drift, dirty-tree
# and recursive submodule drift/dirt rejection independent of target
# .gitmodules ignore policy, including ignored filesystem mutations; post-setup
# acceptance/provenance; exactly one
# generic target_ref wrapper named osc-manual.yml. Local fixtures only.
set -u
HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/osc-target-ref.sh"
SCAN="${1:-}"
[ -n "$SCAN" ] || { echo "usage: osc-target-ref-contract.sh <scan_root>" >&2; exit 1; }
SCAN="$(cd "$SCAN" && pwd)" || exit 1
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
PASS=0; FAILED=0
ok()  { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad() { FAILED=$((FAILED+1)); printf 'FAIL %s\n' "$1"; }
judge() { if [ "$1" -eq 0 ]; then ok "$2"; else bad "$2"; fi; }
res() { (cd "$TMP/resolver" && bash "$SCRIPT" resolve "$1" 2>"$TMP/err"); }

expect_ok() { out=$(res "$2"); rc=$?
  [ "$rc" -eq 0 ] && [ "$out" = "$3" ]; judge $? "$1"; }
expect_no() { out=$(res "$2"); rc=$?
  [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -Eq '^[0-9a-f]{40}$'
  judge $? "$1"; }

# --- ref fixture ----------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git -C "$TMP/origin.git" config uploadpack.allowAnySHA1InWant true
git init -q -b main "$TMP/seed"
cd "$TMP/seed"
git config user.email c@c; git config user.name c
echo 1 > f && git add f && git commit -qm c1; M1=$(git rev-parse HEAD)
echo 2 > f && git commit -qam c2;   M2=$(git rev-parse HEAD)
echo 3 > f && git commit -qam c3;   M3=$(git rev-parse HEAD)
git branch feature "$M1"; git tag v1 "$M1"; git tag -a vann -m a "$M2"
git branch dup "$M1";     git tag dup "$M2"
git branch "$M1" "$M2";   git tag "$M2" "$M1"
git push -q "$TMP/origin.git" \
  refs/heads/main:refs/heads/main refs/heads/feature:refs/heads/feature \
  refs/heads/dup:refs/heads/dup refs/tags/dup:refs/tags/dup \
  "refs/heads/$M1:refs/heads/$M1" "refs/tags/$M2:refs/tags/$M2" \
  refs/tags/v1:refs/tags/v1 refs/tags/vann:refs/tags/vann
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$TMP/resolver"
git -C "$TMP/resolver" remote add origin "file://$TMP/origin.git"

expect_ok "resolve branch main"        main "$M3"
expect_ok "resolve branch feature"     feature "$M1"
expect_ok "resolve lightweight tag v1" v1 "$M1"
expect_ok "resolve annotated tag vann" vann "$M2"
expect_ok "resolve unshadowed SHA"     "$M3" "$M3"

sh=0
res "$M1" >/dev/null 2>&1 && sh=1   # branch named $M1 must shadow raw SHA
res "$M2" >/dev/null 2>&1 && sh=1   # tag named $M2 must shadow raw SHA
judge "$sh" "reject 40-hex shadowed by named branch/tag"

mkdir -p "$TMP/fail-git"
git_real="$(command -v git)"
printf '%s\n' '#!/bin/sh' \
  'if [ "$1" = "ls-remote" ]; then exit 42; fi' \
  "exec \"$git_real\" \"\$@\"" > "$TMP/fail-git/git"
chmod +x "$TMP/fail-git/git"
out=$(cd "$TMP/resolver" && PATH="$TMP/fail-git:$PATH" \
  bash "$SCRIPT" resolve "$M3" 2>"$TMP/err"); rc=$?
[ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -Eq '^[0-9a-f]{40}$'
judge $? "fail closed when raw-SHA namespace lookup errors"

expect_no "reject unknown ref"          nosuch
expect_no "reject option-like long"     --upload-pack=/bin/touch
expect_no "reject option-like short"    -x
expect_no "reject ambiguous branch+tag" dup
expect_no "reject DWIM suffix"          'main^{}'
expect_no "reject HEAD"                 HEAD
expect_no "reject short SHA"            "$(printf '%s' "$M3" | cut -c1-7)"
expect_no "reject refs/ path"           refs/heads/main
expect_no "reject empty ref"            ''
out=$(cd "$TMP/resolver" && bash "$SCRIPT" resolve 2>/dev/null); rc=$?
judge "$([ "$rc" -ne 0 ]; echo $?)" "reject missing argument"
out=$(cd "$TMP/resolver" && bash "$SCRIPT" bogus x 2>/dev/null); rc=$?
judge "$([ "$rc" -ne 0 ]; echo $?)" "reject bad subcommand"

# --- submodule fixture (ignore=all committed in superproject) -------------
newrepo() { git init -q -b main "$1"; git -C "$1" config user.email c@c
  git -C "$1" config user.name c; }
newrepo "$TMP/subB"
( cd "$TMP/subB" && echo b1 > g && printf 'ignored-b.dat\n' > .gitignore \
  && git add g .gitignore && git commit -qm b1 )
B1=$(git -C "$TMP/subB" rev-parse HEAD)
( cd "$TMP/subB" && echo b2 > g && git commit -qam b2 )
B2=$(git -C "$TMP/subB" rev-parse HEAD)
newrepo "$TMP/subA"
( cd "$TMP/subA" && echo a1 > h && printf 'ignored-a.dat\n' > .gitignore \
  && git add h .gitignore && git commit -qm a1 \
  && git -c protocol.file.allow=always submodule add -q "$TMP/subB" libs/B \
  && git commit -qm a2 )
A2=$(git -C "$TMP/subA" rev-parse HEAD)
newrepo "$TMP/super"
( cd "$TMP/super" && echo s1 > i && printf 'ignored-super.dat\n' > .gitignore \
  && git add i .gitignore && git commit -qm s1 \
  && git -c protocol.file.allow=always submodule add -q "$TMP/subA" libs/A \
  && git config -f .gitmodules submodule.libs/A.ignore all \
  && git add .gitmodules && git commit -qm s2 )
SUP=$(git -C "$TMP/super" rev-parse HEAD)
( cd "$TMP/subA" && echo a3 >> h && git commit -qam a3 )
A3=$(git -C "$TMP/subA" rev-parse HEAD)
git clone -q "$TMP/super" "$TMP/vs"
( cd "$TMP/vs" && git -c protocol.file.allow=always submodule update -q --init --recursive )
ver() { (cd "$TMP/vs" && bash "$SCRIPT" "$@" 2>"$TMP/err"); }

out=$(ver verify "$SUP"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "verified $SUP" ]
judge $? "verify exact recursive checkout under ignore=all"

ver verify "$M1" >/dev/null 2>&1; judge "$([ $? -ne 0 ]; echo $?)" "reject checkout drift"
echo x >> "$TMP/vs/i"
ver verify "$SUP" >/dev/null 2>&1; judge "$([ $? -ne 0 ]; echo $?)" "reject dirty tracked tree"
git -C "$TMP/vs" checkout -q -- i
touch "$TMP/vs/u"
ver verify "$SUP" >/dev/null 2>&1; judge "$([ $? -ne 0 ]; echo $?)" "reject untracked file"
rm -f "$TMP/vs/u"

sg=0
git -C "$TMP/vs/libs/A" fetch -q origin
git -C "$TMP/vs/libs/A" checkout -q "$A3"
[ -z "$(git -C "$TMP/vs" status --porcelain)" ] || sg=1  # ignore=all must hide it from plain status
ver verify "$SUP" >/dev/null 2>&1 && sg=1                # wrong top submodule HEAD
git -C "$TMP/vs/libs/A" checkout -q "$A2"
git -C "$TMP/vs/libs/A/libs/B" checkout -q "$B1"
ver verify "$SUP" >/dev/null 2>&1 && sg=1                # wrong nested submodule HEAD
git -C "$TMP/vs/libs/A/libs/B" checkout -q "$B2"
echo x >> "$TMP/vs/libs/A/h"
ver verify "$SUP" >/dev/null 2>&1 && sg=1                # tracked dirt in submodule
git -C "$TMP/vs/libs/A" checkout -q -- h
touch "$TMP/vs/libs/A/u"
ver verify "$SUP" >/dev/null 2>&1 && sg=1                # untracked dirt in submodule
rm -f "$TMP/vs/libs/A/u"
git -C "$TMP/vs/libs/A" checkout -q "$A3"                # off-gitlink clean state for post
judge "$sg" "submodule drift/dirt gate independent of ignore=all"

ig=0
printf 'ignored\n' > "$TMP/vs/ignored-super.dat"
printf 'ignored\n' > "$TMP/vs/libs/A/ignored-a.dat"
printf 'ignored\n' > "$TMP/vs/libs/A/libs/B/ignored-b.dat"
super_ignored=$(git -C "$TMP/vs" status --porcelain --ignored --ignore-submodules=none)
sub_a_ignored=$(git -C "$TMP/vs/libs/A" status --porcelain --ignored --ignore-submodules=none)
sub_b_ignored=$(git -C "$TMP/vs/libs/A/libs/B" status --porcelain --ignored --ignore-submodules=none)
printf '%s\n' "$super_ignored" | grep -Fqx '!! ignored-super.dat' || ig=1
printf '%s\n' "$sub_a_ignored" | grep -Fqx '!! ignored-a.dat' || ig=1
printf '%s\n' "$sub_b_ignored" | grep -Fqx '!! ignored-b.dat' || ig=1
judge "$ig" "fixture exposes ignored dirt at every recursive depth"
ig=0
ver verify "$SUP" >/dev/null 2>&1 && ig=1
ver post >/dev/null 2>&1 && ig=1
judge "$ig" "reject ignored dirt at superproject and recursive submodule depth"
rm -f "$TMP/vs/ignored-super.dat" "$TMP/vs/libs/A/ignored-a.dat" \
  "$TMP/vs/libs/A/libs/B/ignored-b.dat"

# --- post: canonical off-gitlink state, dirt rejection, provenance --------
out=$(ver post); rc=$?
[ "$rc" -eq 0 ] \
  && printf '%s\n' "$out" | grep -qx "PROVENANCE submodule libs/A $A3" \
  && printf '%s\n' "$out" | grep -qx "PROVENANCE submodule libs/A/libs/B $B2"
judge $? "post accepts off-gitlink clean state and prints recursive provenance"

pg=0
echo x >> "$TMP/vs/i"
ver post >/dev/null 2>&1 && pg=1                          # superproject dirt
git -C "$TMP/vs" checkout -q -- i
echo x >> "$TMP/vs/libs/A/h"
ver post >/dev/null 2>&1 && pg=1                          # submodule-internal dirt
git -C "$TMP/vs/libs/A" checkout -q -- h
judge "$pg" "post rejects superproject and submodule dirt"

ver verify notasha >/dev/null 2>&1; judge "$([ $? -ne 0 ]; echo $?)" "reject non-40-hex expected"
ver verify >/dev/null 2>&1;        judge "$([ $? -ne 0 ]; echo $?)" "reject verify without argument"

# --- single-canonical-wrapper invariant -----------------------------------
single_wrapper() {
  local f n=0 found=""
  for f in "$1"/.github/workflows/*.yml "$1"/.github/workflows/*.yaml; do
    [ -f "$f" ] || continue
    if grep -q workflow_dispatch "$f" && grep -q target_ref "$f"; then
      n=$((n+1)); found="$f"
    fi
  done
  [ "$n" -eq 1 ] && [ "$(basename "$found")" = "osc-manual.yml" ]
}
mkdir -p "$TMP/wg/.github/workflows"
printf 'on: [workflow_dispatch] # target_ref\n' > "$TMP/wg/.github/workflows/osc-manual.yml"
single_wrapper "$TMP/wg"; judge $? "single-wrapper fixture accepts canonical layout"
cp -r "$TMP/wg" "$TMP/wb"
printf 'on: [workflow_dispatch] # target_ref\n' > "$TMP/wb/.github/workflows/second.yml"
sw=0
single_wrapper "$TMP/wb" && sw=1
rm "$TMP/wb/.github/workflows/second.yml"
mv "$TMP/wb/.github/workflows/osc-manual.yml" "$TMP/wb/.github/workflows/other.yml"
single_wrapper "$TMP/wb" && sw=1
judge "$sw" "single-wrapper fixture rejects second or misnamed wrapper"

single_wrapper "$SCAN"; judge $? "exactly one generic target_ref wrapper (osc-manual.yml) in scan root"

printf 'contract: %d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
