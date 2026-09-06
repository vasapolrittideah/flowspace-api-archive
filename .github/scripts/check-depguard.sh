#!/usr/bin/env bash
# The ADR-0009 boundary is a net under the compiler, and a net with a hole in
# it looks exactly like one without. depguard's own semantics are the hazard:
# `allow` does not override `deny`, so the obvious rule shape silently forbids
# a service from importing itself. This builds a throwaway module in a temp
# directory, points the real .golangci.yml at it, and asserts what must and
# must not be reported. The module is generated rather than committed because
# a second go.mod in this repository would contradict ADR-0009.
set -euo pipefail
cd "$(dirname "$0")/../.."

config=$PWD/.golangci.yml
fail=0
err() { echo "::error::$*"; fail=1; }

# The module path the deny rules are written against, taken from the config
# itself: the thing under test is the only honest source for it.
module=$(grep -v '^[[:space:]]*#' "$config" |
  sed -n 's|.*pkg: \([^[:space:]]*\)/services.*|\1|p' | head -1)
[[ -n $module ]] || { echo "::error::no depguard deny rule naming a services/ import"; exit 1; }

probe=$(mktemp -d)
trap 'rm -rf "$probe"' EXIT
cp "$config" "$probe/.golangci.yml"
printf 'module %s\n\ngo 1.26\n' "$module" >"$probe/go.mod"

# A package outside internal/ is the case the compiler cannot see, so it is
# the only one worth probing.
leak() {
  mkdir -p "$probe/services/$1/leak"
  printf 'package leak\n\n// T escaped internal/, so only depguard guards it.\ntype T struct{}\n' \
    >"$probe/services/$1/leak/leak.go"
}
importer() { # <dir> <package> <service>
  mkdir -p "$probe/$1"
  printf 'package %s\n\nimport "%s/services/%s/leak"\n\n// V reaches across a boundary.\nvar V leak.T\n' \
    "$2" "$module" "$3" >"$probe/$1/p.go"
}

shopt -s nullglob
services=()
for d in services/*/; do services+=("$(basename "$d")"); done

leak probe-only
importer pkg/probe probe probe-only
for s in ${services[@]+"${services[@]}"}; do
  leak "$s"
  importer "outside/$s" "${s//-/_}" "$s"   # not pkg/, not services/: only that service's own rule can catch it
  mkdir -p "$probe/services/$s/ok"
  printf 'package ok\n\nimport "%s/services/%s/leak"\n\n// V is a legal same-service import.\nvar V leak.T\n' \
    "$module" "$s" >"$probe/services/$s/ok/ok.go"
done

cd "$probe"
go build ./... >/dev/null || { echo "::error::probe module does not compile"; exit 1; }
# Other linters will have opinions about generated probe code; only depguard
# is under test here, and its exit code is not.
report=$(golangci-lint run ./... 2>/dev/null | grep '(depguard)' || true)

# Paths are reported relative to golangci-lint's own working directory, which
# mktemp can leave as ../tmp.XXXX; match the tail rather than anchoring.
denied() { grep -qF -- "$1:" <<<"$report"; }

denied pkg/probe/p.go ||
  err "pkg/ may import services/: no rule denies it (ADR-0009)"
for s in ${services[@]+"${services[@]}"}; do
  denied "outside/$s/p.go" ||
    err "services/$s is importable from outside it: add its depguard rule to .golangci.yml"
  ! denied "services/$s/ok/ok.go" ||
    err "services/$s cannot import itself: its depguard rule denies more than it should"
done

(( fail )) && exit 1
if (( ${#services[@]} )); then
  echo "ok: pkg/ guard plus a private-tree rule for each of ${#services[@]} service(s)"
else
  echo "ok: pkg/ guard; no services yet, so no per-service rule to check"
fi
