#!/usr/bin/env bash
# Assert that each combination of ci/modular.yml inputs produces exactly the jobs
# it should.
#
# Why this exists: the modular include pattern fails SILENTLY. A wrong `rules:`
# expression does not error -- it includes nothing, and the job simply is not in
# the pipeline. A typo'd input *name* is a hard error; a typo'd input *value*
# ("True") is an invisible omission. This turns that into a non-zero exit.
#
# Runs the same way locally (`just check-matrix`) and in CI (`config-matrix` job).
set -euo pipefail

cd "$(dirname "$0")/.."

GCL=(npx --yes -p node@22 -p gitlab-ci-local@latest gitlab-ci-local)
ROOT=".gcl-matrix-probe.yml"
trap 'rm -f "$ROOT"' EXIT

fail=0

# A probe root that includes ONLY the modular chain, so the assertion is not
# diluted by the nine jobs defined directly in .gitlab-ci.yml.
probe_root() {
    cat > "$ROOT" <<YAML
include:
  - local: ci/templates.yml
  - local: ci/modular.yml
    inputs:
      include_greeting: "$1"
      include_lint: "$2"
      greeting_variant: "$3"
stages: [prep, build, test, deploy, cleanup]
YAML
}

job_names() {
    # `grep || true`: an empty job set is a legitimate expected result (all
    # toggles off), but grep exits 1 on no match, which `set -o pipefail` would
    # otherwise turn into a script abort.
    "${GCL[@]}" --file "$ROOT" --list-json 2>/dev/null \
        | { grep -oE '"name": *"[^"]+"' || true; } \
        | sed 's/.*: *"//; s/"$//' | sort | tr '\n' ' ' | sed 's/ $//'
}

# check <desc> <include_greeting> <include_lint> <variant> <expected job names>
check() {
    local desc="$1" got
    probe_root "$2" "$3" "$4"
    got=$(job_names)
    if [ "$got" = "$5" ]; then
        printf 'ok    %-26s -> %s\n' "$desc" "${got:-<no jobs>}"
    else
        printf 'FAIL  %-26s\n        expected: %s\n        got:      %s\n' \
            "$desc" "${5:-<no jobs>}" "${got:-<no jobs>}"
        fail=1
    fi
}

# variant_routes <variant> present|absent <needle>
# Proves the variant actually swaps the implementation, not just the job list.
variant_routes() {
    local variant="$1" want="$2" needle="$3"
    local desc found
    desc="variant=$variant $want needle"
    probe_root "true" "false" "$variant"
    if "${GCL[@]}" --file "$ROOT" --preview 2>/dev/null | grep -qF "$needle"; then
        found=present
    else
        found=absent
    fi
    if [ "$found" = "$want" ]; then
        printf 'ok    %-26s -> %s\n' "$desc" "$found"
    else
        printf 'FAIL  %-26s expected %s, got %s\n' "$desc" "$want" "$found"
        fail=1
    fi
}

echo "--- job sets ---"
#      description            greeting  lint   variant  expected
check "both on, simple"       true      true   simple   "greeting lint-yaml"
check "both on, fancy"        true      true   fancy    "greeting lint-yaml"
check "greeting off"          false     true   simple   "lint-yaml"
check "lint off"              true      false  simple   "greeting"
check "both off"              false     false  simple   ""

echo "--- variant routing ---"
variant_routes fancy  present "routed by ci/modules/greeting.yml"
variant_routes simple absent  "routed by ci/modules/greeting.yml"

echo
[ "$fail" -eq 0 ] && { echo "all checks passed"; exit 0; }
echo "FAILURES -- a module rule is including the wrong thing" >&2
exit 1
