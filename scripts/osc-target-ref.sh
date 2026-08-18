#!/usr/bin/env bash
# osc-target-ref.sh — safe target_ref resolution and checkout verification
# for the osc-manual workflow_dispatch wrapper.
#   resolve <target_ref>  exact branch, exact tag, or literal 40-hex SHA that
#                         no branch or tag shadows. Prints one 40-hex line.
#   verify <sha>          pre-setup gate: HEAD == sha, superproject clean with
#                         --ignore-submodules=none, recursive gitlink identity
#                         and recursive submodule-internal cleanliness.
#   post                  post-setup gate: no non-submodule superproject dirt,
#                         every submodule internally clean; prints recursive
#                         PROVENANCE submodule lines for the state under test.
set -euo pipefail

fail() { printf 'osc-target-ref: %s\n' "$*" >&2; exit 1; }
is_sha() { printf '%s' "$1" | grep -Eq '^[0-9a-f]{40}$'; }

cmd="${1:-}"
case "$cmd" in
  resolve|verify) [ $# -eq 2 ] || fail "usage: osc-target-ref.sh $cmd <arg>" ;;
  post) [ $# -eq 1 ] || fail "usage: osc-target-ref.sh post" ;;
  *) fail "usage: osc-target-ref.sh resolve <ref> | verify <sha> | post" ;;
esac
arg="${2:-}"

named_matches() { # exact refs/heads/$1 or refs/tags/$1 lines on origin
  git ls-remote origin "refs/heads/$1" "refs/tags/$1" \
    | awk -v h="refs/heads/$1" -v t="refs/tags/$1" '$2==h || $2==t'
}

if [ "$cmd" = "resolve" ]; then
  ref="$arg"
  case "$ref" in
    "") fail "empty target_ref" ;;
    -*) fail "option-like target_ref rejected: $ref" ;;
  esac
  if is_sha "$ref"; then
    [ -z "$(named_matches "$ref")" ] \
      || fail "40-hex input shadowed by a named branch or tag: $ref"
    git fetch -q --depth 1 origin "$ref" 2>/dev/null \
      || fail "SHA not fetchable from origin: $ref"
    resolved=$(git rev-parse --verify "${ref}^{commit}" 2>/dev/null) \
      || fail "not a commit: $ref"
    is_sha "$resolved" || fail "unexpected rev-parse output for: $ref"
    printf '%s\n' "$resolved"
    exit 0
  fi
  case "$ref" in
    refs/*|*@\{*|*\^*|*~*|*:*|*..*) fail "DWIM/malformed ref rejected: $ref" ;;
  esac
  git check-ref-format "refs/heads/$ref" || fail "malformed ref name: $ref"
  matches=$(named_matches "$ref")
  count=$(printf '%s\n' "$matches" | grep -c . || true)
  [ "$count" -gt 0 ] || fail "no such branch or tag on origin: $ref"
  [ "$count" -eq 1 ] || fail "ambiguous ref (branch and tag both exist): $ref"
  refname=$(printf '%s\n' "$matches" | awk 'NR==1{print $2}')
  git fetch -q --depth 1 origin "$refname" || fail "ref not fetchable: $ref"
  resolved=$(git rev-parse --verify 'FETCH_HEAD^{commit}' 2>/dev/null) \
    || fail "ref does not resolve to a commit: $ref"
  is_sha "$resolved" || fail "unexpected rev-parse output for: $ref"
  printf '%s\n' "$resolved"
  exit 0
fi

each_sub() { # $1=repo dir $2=callback(records sha, path, abs dir); recursive
  local repo="$1" mode type sha path
  while read -r mode type sha path; do
    [ "$mode" = "160000" ] || continue
    "$2" "$sha" "$path" "$repo/$path"
    each_sub "$repo/$path" "$2"
  done < <(git -C "$repo" ls-tree -r HEAD)
}

sub_head() { sub_actual=$(git -C "$3" rev-parse HEAD 2>/dev/null) \
  || fail "submodule not checked out: $2"; }

check_gitlink() { sub_head "$@"; [ "$sub_actual" = "$1" ] \
  || fail "submodule drift: $2 recorded=$1 actual=$sub_actual"; }

check_clean() { sub_head "$@"; [ -z "$(git -C "$3" status --porcelain --ignore-submodules=none)" ] \
  || fail "dirty submodule: $2"; }

print_prov() { sub_head "$@"; printf 'PROVENANCE submodule %s %s\n' "${3#./}" "$sub_actual"; }

case "$cmd" in
  verify)
    expected="$arg"
    is_sha "$expected" || fail "expected SHA must be literal 40-hex: $expected"
    actual=$(git rev-parse HEAD) || fail "not inside a git work tree"
    [ "$actual" = "$expected" ] \
      || fail "checkout drift: HEAD=$actual expected=$expected"
    [ -z "$(git status --porcelain --ignore-submodules=none)" ] \
      || fail "dirty tree after checkout"
    each_sub . check_gitlink
    each_sub . check_clean
    printf 'verified %s\n' "$actual"
    ;;
  post)
    [ -z "$(git status --porcelain --ignore-submodules=all)" ] \
      || fail "non-submodule dirt after setup"
    each_sub . check_clean
    each_sub . print_prov
    ;;
esac
