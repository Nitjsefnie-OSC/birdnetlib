#!/usr/bin/env bash
# Offline contract for scripts/osc-target-ref.sh. Proves:
#   valid-ref success (branch, lightweight tag, annotated tag, 40-hex SHA)
#   invalid-ref rejection (unknown name, empty, missing arg, bad subcommand)
#   option-injection rejection (-*, --upload-pack=...)
#   ambiguous/DWIM rejection (branch+tag collision, main^{}, HEAD, short SHA)
#   dirty-tree rejection (tracked modification, untracked file)
#   checkout-drift rejection (HEAD != expected SHA)
#   green-no-op rejection (no input shape exits 0 without a strict 40-hex
#   resolution or an exact verify; success output shape is asserted)
# Runs entirely against a local throwaway origin; no network, no target repo.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
SCRIPT="$HERE/osc-target-ref.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
PASS=0
FAILED=0

ok()   { PASS=$((PASS+1)); printf 'PASS %s\n' "$1"; }
bad()  { FAILED=$((FAILED+1)); printf 'FAIL %s\n' "$1"; }

expect_resolve_ok() { # name input expected_sha
  out=$(cd "$TMP/resolver" && bash "$SCRIPT" resolve "$2" 2>"$TMP/err"); rc=$?
  if [ "$rc" -eq 0 ] && [ "$out" = "$3" ] \
     && printf '%s\n' "$out" | grep -Eq '^[0-9a-f]{40}$'; then
    ok "$1"
  else
    bad "$1 (rc=$rc out=$out err=$(cat "$TMP/err"))"
  fi
}

expect_resolve_fail() { # name input
  out=$(cd "$TMP/resolver" && bash "$SCRIPT" resolve "$2" 2>"$TMP/err"); rc=$?
  if [ "$rc" -ne 0 ] && ! printf '%s\n' "$out" | grep -Eq '^[0-9a-f]{40}$'; then
    ok "$1"
  else
    bad "$1 (rc=$rc out=$out)"
  fi
}

# --- fixture origin -------------------------------------------------------
git init -q --bare "$TMP/origin.git"
git -C "$TMP/origin.git" config uploadpack.allowAnySHA1InWant true
git init -q -b main "$TMP/seed"
cd "$TMP/seed"
git config user.email contract@example.com
git config user.name contract
echo one > f.txt && git add f.txt && git commit -qm c1
M1=$(git rev-parse HEAD)
echo two > f.txt && git commit -qam c2
M2=$(git rev-parse HEAD)
git branch feature "$M1"
git tag v1 "$M1"
git tag -a vann -m annotated "$M2"
git branch dup "$M1"
git tag dup "$M2"
git push -q "$TMP/origin.git" \
  refs/heads/main:refs/heads/main \
  refs/heads/feature:refs/heads/feature \
  refs/heads/dup:refs/heads/dup \
  refs/tags/v1:refs/tags/v1 \
  refs/tags/vann:refs/tags/vann \
  refs/tags/dup:refs/tags/dup
git -C "$TMP/origin.git" symbolic-ref HEAD refs/heads/main
git init -q "$TMP/resolver"
git -C "$TMP/resolver" remote add origin "file://$TMP/origin.git"

# --- resolve: valid refs --------------------------------------------------
expect_resolve_ok "resolve branch main"        main "$M2"
expect_resolve_ok "resolve branch feature"     feature "$M1"
expect_resolve_ok "resolve lightweight tag v1" v1 "$M1"
expect_resolve_ok "resolve annotated tag vann" vann "$M2"
expect_resolve_ok "resolve literal SHA"        "$M1" "$M1"

# --- resolve: rejections --------------------------------------------------
expect_resolve_fail "reject unknown ref"          nosuch
expect_resolve_fail "reject option-like long"     --upload-pack=/bin/touch
expect_resolve_fail "reject option-like short"    -x
expect_resolve_fail "reject ambiguous branch+tag" dup
expect_resolve_fail "reject DWIM suffix"          'main^{}'
expect_resolve_fail "reject HEAD"                 HEAD
expect_resolve_fail "reject short SHA"            "$(printf '%s' "$M1" | cut -c1-7)"
expect_resolve_fail "reject refs/ path"           refs/heads/main
expect_resolve_fail "reject empty ref"            ''

out=$(cd "$TMP/resolver" && bash "$SCRIPT" resolve 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "reject missing argument" || bad "reject missing argument"
out=$(cd "$TMP/resolver" && bash "$SCRIPT" bogus x 2>/dev/null); rc=$?
[ "$rc" -ne 0 ] && ok "reject bad subcommand" || bad "reject bad subcommand"

# --- verify ---------------------------------------------------------------
git clone -q "$TMP/origin.git" "$TMP/work" 2>/dev/null
cd "$TMP/work"
git checkout -q main

out=$(bash "$SCRIPT" verify "$M2" 2>"$TMP/err"); rc=$?
[ "$rc" -eq 0 ] && [ "$out" = "verified $M2" ] \
  && ok "verify exact checkout" || bad "verify exact checkout (rc=$rc out=$out)"

bash "$SCRIPT" verify "$M1" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "reject checkout drift" || bad "reject checkout drift"

echo stray >> f.txt
bash "$SCRIPT" verify "$M2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "reject dirty tracked tree" || bad "reject dirty tracked tree"
git checkout -q -- f.txt

echo stray > untracked.txt
bash "$SCRIPT" verify "$M2" >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "reject untracked file" || bad "reject untracked file"
rm -f untracked.txt

bash "$SCRIPT" verify notasha >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "reject non-40-hex expected" || bad "reject non-40-hex expected"

bash "$SCRIPT" verify >/dev/null 2>&1; rc=$?
[ "$rc" -ne 0 ] && ok "reject verify without argument" || bad "reject verify without argument"

printf 'contract: %d passed, %d failed\n' "$PASS" "$FAILED"
[ "$FAILED" -eq 0 ]
