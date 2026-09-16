#!/usr/bin/env bash
# Removes every playpen runner, from BOTH sources of truth.
#
# `gitlab-runner unregister` only removes the runner *manager* (the local
# registration). With token-based registration the runner itself is a
# GitLab-side object created via the API, so unregistering alone leaves it
# orphaned in the UI (managers=0, still listed). This removes both.
#
# Used by register-runner.sh and by `just unregister`.
set -euo pipefail

compose() { docker compose "$@"; }
# Matches both playpen runners: "playpen" and "playpen-dind".
RUNNER_DESC_PREFIX="${RUNNER_DESC_PREFIX:-playpen}"

# 1. Best effort: lets gitlab-runner revoke its tokens cleanly. Partially fails
#    when config.toml holds entries GitLab has already dropped, so steps 2 and 3
#    are what actually guarantee the outcome.
compose exec -T runner gitlab-runner unregister --all-runners >/dev/null 2>&1 || true

# 2. Authoritative for GitLab's side. Uses gitlab-rails rather than the REST API
#    to avoid parsing JSON with shell tools.
echo "Removing '$RUNNER_DESC_PREFIX*' runners from GitLab..."
compose exec -T gitlab gitlab-rails runner "
  rs = Ci::Runner.where('description LIKE ?', '$RUNNER_DESC_PREFIX%')
  puts %(  found #{rs.count} runner(s): #{rs.map(&:id).join(', ')})
  rs.each { |r| r.destroy! }
" 2>/dev/null | grep '  found' || echo "  (none)"

# 3. Authoritative for the runner container's side: strip every [[runners]]
#    block, keeping the global settings. Leaves a .bak alongside.
echo "Resetting config.toml to its global section..."
compose exec -T runner sh -c '
  f=/etc/gitlab-runner/config.toml
  [ -f "$f" ] || exit 0
  cp "$f" "$f.bak"
  awk "/^\\[\\[runners\\]\\]/{exit} {print}" "$f.bak" > "$f"
'
