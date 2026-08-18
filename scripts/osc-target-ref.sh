#!/usr/bin/env bash
# osc-target-ref.sh — safe target_ref resolution and checkout verification
# for the osc-manual-v2 workflow_dispatch wrapper.
#
#   resolve <target_ref>    Run inside a git repo whose "origin" is the fork.
#                           Prints exactly one line: the resolved 40-hex commit
#                           SHA. Only an exact branch name, an exact tag name,
#                           or a literal 40-hex SHA is accepted. Option-like,
#                           malformed, DWIM (main^{}, HEAD~, short SHA, refs/*
#                           paths) and ambiguous (branch+tag collision) inputs
#                           are rejected with a nonzero exit.
#   verify <expected_sha>   Run inside the checked-out target tree. Fails on
#                           checkout drift (HEAD != expected) or a dirty tree.
#
# Success output is strictly one 40-hex line (resolve) or "verified <sha>"
# (verify); any other shape of success is impossible by construction.
set -euo pipefail

fail() { printf 'osc-target-ref: %s\n' "$*" >&2; exit 1; }

is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

[ $# -eq 2 ] || fail "usage: osc-target-ref.sh resolve <target_ref> | verify <expected_sha>"
cmd="$1"
arg="$2"
case "$cmd" in
  resolve|verify) ;;
  *) fail "unknown subcommand: $cmd" ;;
esac

if [ "$cmd" = "resolve" ]; then
  ref="$arg"
  case "$ref" in
    "") fail "empty target_ref" ;;
    -*) fail "option-like target_ref rejected: $ref" ;;
  esac
  if is_sha "$ref"; then
    git fetch -q --depth 1 origin "$ref" 2>/dev/null \
      || fail "SHA not fetchable from origin: $ref"
    resolved=$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null) \
      || fail "not a commit: $ref"
    is_sha "$resolved" || fail "unexpected rev-parse output for: $ref"
    printf '%s\n' "$resolved"
    exit 0
  fi
  case "$ref" in
    refs/*|*@\{*|*\^*|*~*|*:*|*..*)
      fail "DWIM/malformed ref rejected: $ref" ;;
  esac
  git check-ref-format "refs/heads/$ref" || fail "malformed ref name: $ref"
  remote_listing=$(git ls-remote origin "refs/heads/$ref" "refs/tags/$ref")
  matches=$(printf '%s\n' "$remote_listing" \
    | awk -v h="refs/heads/$ref" -v t="refs/tags/$ref" '$2==h || $2==t')
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  [ "$count" -gt 0 ] || fail "no such branch or tag on origin: $ref"
  [ "$count" -eq 1 ] || fail "ambiguous ref (branch and tag both exist): $ref"
  refname=$(printf '%s\n' "$matches" | awk 'NR==1{print $2}')
  git fetch -q --depth 1 origin "$refname" \
    || fail "ref not fetchable from origin: $ref"
  resolved=$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) \
    || fail "ref does not resolve to a commit: $ref"
  is_sha "$resolved" || fail "unexpected rev-parse output for: $ref"
  printf '%s\n' "$resolved"
  exit 0
fi

# verify
expected="$arg"
is_sha "$expected" || fail "expected SHA must be literal 40-hex: $expected"
actual=$(git rev-parse HEAD) || fail "not inside a git work tree"
[ "$actual" = "$expected" ] \
  || fail "checkout drift: HEAD=$actual expected=$expected"
[ -z "$(git status --porcelain)" ] || fail "dirty tree after checkout"
printf 'verified %s\n' "$actual"
