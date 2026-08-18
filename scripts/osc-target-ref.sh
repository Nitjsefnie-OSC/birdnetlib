#!/usr/bin/env bash
# osc-target-ref.sh — safe target_ref resolution and checkout verification
# for the osc-manual workflow_dispatch wrapper.
#   resolve <target_ref>  exact branch, exact tag, or literal 40-hex SHA that
#                         no branch or tag shadows. Prints one 40-hex line.
#   verify <sha>          pre-setup gate: HEAD == sha, superproject clean with
#                         ignored state visible, recursive gitlink identity and
#                         recursive submodule-internal cleanliness.
#   post                  post-setup gate: no non-submodule superproject dirt,
#                         ignored state visible, every submodule internally
#                         clean; prints recursive PROVENANCE submodule lines.
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
    matches=$(named_matches "$ref") \
      || fail "unable to inspect named refs on origin: $ref"
    [ -z "$matches" ] \
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
  matches=$(named_matches "$ref") \
    || fail "unable to inspect named refs on origin: $ref"
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

each_sub() { # $1=repo dir $2=callback(sha, full path, abs dir); recursive
  local repo="$1" callback="$2" prefix="${3:-}" entry metadata mode type sha path full
  while IFS= read -r -d '' entry; do
    metadata="${entry%%$'\t'*}"
    path="${entry#*$'\t'}"
    read -r mode type sha <<< "$metadata"
    [ "$mode" = "160000" ] || continue
    full="${prefix:+$prefix/}$path"
    "$callback" "$sha" "$full" "$repo/$path"
    if [ -e "$repo/$path/.git" ] \
      && git -C "$repo/$path" rev-parse HEAD >/dev/null 2>&1; then
      each_sub "$repo/$path" "$callback" "$full"
    fi
  done < <(git -C "$repo" ls-tree -r -z HEAD)
}

sub_head() { [ -e "$3/.git" ] || fail "submodule not checked out: $2"
  sub_actual=$(git -C "$3" rev-parse HEAD 2>/dev/null) \
  || fail "submodule not checked out: $2"; }

check_gitlink() { sub_head "$@"; [ "$sub_actual" = "$1" ] \
  || fail "submodule drift: $2 recorded=$1 actual=$sub_actual"; }

clean_status() {
  local repo="$1" ignore_submodules="$2" label="$3" status
  status=$(git -C "$repo" status --porcelain=v1 --ignored=matching \
    --untracked-files=all --ignore-submodules="$ignore_submodules") \
    || fail "unable to inspect $label"
  [ -z "$status" ] || fail "dirty $label"
}

check_clean() {
  sub_head "$@"
  clean_status "$3" none "submodule: $2"
}

inventory_path() {
  if [ -n "${OSC_BASELINE_INVENTORY:-}" ]; then
    printf '%s\n' "$OSC_BASELINE_INVENTORY"
  else
    git rev-parse --git-path osc-target-ref-baseline \
      || fail "unable to locate baseline inventory"
  fi
}

inventory_record() { printf '%s\0%s\0' "$2" "$1"; }
save_inventory() {
  local file="$1" tmp="${1}.tmp.$$"
  mkdir -p "$(dirname "$file")" || fail "unable to create baseline inventory directory"
  each_sub . inventory_record >"$tmp" || fail "unable to build baseline inventory"
  mv -f "$tmp" "$file" || fail "unable to persist baseline inventory"
}

declare -A baseline_sha=() baseline_seen=()
load_inventory() {
  local file="$1" path sha
  [ -f "$file" ] || fail "baseline inventory missing: $file"
  while IFS= read -r -d '' path; do
    IFS= read -r -d '' sha || fail "malformed baseline inventory: $file"
    is_sha "$sha" || fail "malformed baseline gitlink SHA: $path"
    baseline_sha["$path"]="$sha"; baseline_seen["$path"]=0
  done <"$file"
}

post_sub() {
  local sha="$1" path="$2" dir="$3" actual
  if [ "${baseline_sha[$path]+x}" ]; then
    baseline_seen["$path"]=1
    sub_head "$sha" "$path" "$dir"
    clean_status "$dir" all "submodule: $path"
    printf 'PROVENANCE submodule %s %s\n' "$path" "$sub_actual"
  elif [ -e "$dir/.git" ] \
    && actual=$(git -C "$dir" rev-parse HEAD 2>/dev/null); then
    [ "$actual" = "$sha" ] || fail "new submodule drift: $path recorded=$sha actual=$actual"
    clean_status "$dir" all "new submodule: $path"
    printf '\0PROVENANCE new-initialized-gitlink\0%s\0%s\0%s\0' \
      "$path" "$sha" "$actual"
  else
    printf '\0PROVENANCE new-uninitialized-gitlink\0%s\0%s\0' "$path" "$sha"
  fi
}

case "$cmd" in
  verify)
    expected="$arg"
    is_sha "$expected" || fail "expected SHA must be literal 40-hex: $expected"
    actual=$(git rev-parse HEAD) || fail "not inside a git work tree"
    [ "$actual" = "$expected" ] \
      || fail "checkout drift: HEAD=$actual expected=$expected"
    clean_status . none "tree after checkout"
    each_sub . check_gitlink
    each_sub . check_clean
    save_inventory "$(inventory_path)"
    printf 'verified %s\n' "$actual"
    ;;
  post)
    load_inventory "$(inventory_path)"
    clean_status . all "non-submodule tree after setup"
    each_sub . post_sub
    for path in "${!baseline_sha[@]}"; do
      [ "${baseline_seen[$path]:-0}" -eq 1 ] \
        || fail "baseline submodule missing: $path"
    done
    ;;
esac
