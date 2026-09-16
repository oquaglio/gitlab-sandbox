#!/usr/bin/env bash
# Registers a single instance runner, configured for docker-in-docker.
#
# Idempotent: re-running removes whatever runners are already registered
# (locally and in GitLab) and replaces them with exactly one. Safe to re-run
# after changing executor settings.
set -euo pipefail

compose() { docker compose "$@"; }

RUNNER_DESC="playpen"
PAT_NAME="playpen-runner-setup"

echo "Waiting for GitLab to be healthy (can take several minutes)..."
until compose exec -T gitlab curl -sf http://localhost:8929/-/readiness >/dev/null 2>&1; do
  sleep 10; printf '.'
done
echo " ready"

echo "Creating short-lived root PAT (revoking any from previous runs)..."
PAT="glpat-playpen-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
compose exec -T gitlab gitlab-rails runner "
  u = User.find_by_username('root')
  u.personal_access_tokens.active.where(name: '$PAT_NAME').each(&:revoke!)
  t = u.personal_access_tokens.create!(name: '$PAT_NAME', scopes: [:api, :create_runner], expires_at: 1.day.from_now)
  t.set_token('$PAT'); t.save!
" >/dev/null

# --- reconcile: end up with exactly one runner, however we started ------------
# Two sources of truth can drift apart: the runner's config.toml and GitLab's
# own runner list. Reset both rather than trusting either.

# 1. Best effort: lets gitlab-runner revoke its tokens cleanly. Often partially
#    fails when config.toml holds entries whose tokens GitLab already dropped,
#    so its result is not relied on -- steps 2 and 3 are what guarantee state.
compose exec -T runner gitlab-runner unregister --all-runners >/dev/null 2>&1 || true

# 2. Authoritative: delete every '$RUNNER_DESC' runner GitLab still lists.
#    Done through gitlab-rails rather than the REST API to avoid parsing JSON
#    with shell tools.
echo "Removing existing '$RUNNER_DESC' runners from GitLab..."
compose exec -T gitlab gitlab-rails runner "
  rs = Ci::Runner.where(description: '$RUNNER_DESC')
  puts %(  found #{rs.count} existing runner(s): #{rs.map(&:id).join(', ')})
  rs.each { |r| r.destroy! }
" 2>/dev/null | grep '  found' || echo "  (none)"

# 3. Authoritative: strip every [[runners]] block, keeping the global settings.
echo "Resetting config.toml to its global section..."
compose exec -T runner sh -c '
  f=/etc/gitlab-runner/config.toml
  [ -f "$f" ] || exit 0
  cp "$f" "$f.bak"
  awk "/^\\[\\[runners\\]\\]/{exit} {print}" "$f.bak" > "$f"
'

# --- create + register exactly one runner ---------------------------------
echo "Creating instance runner..."
RUNNER_TOKEN=$(compose exec -T gitlab curl -sf -X POST \
  -H "PRIVATE-TOKEN: $PAT" \
  --data "runner_type=instance_type" --data "run_untagged=true" --data "description=$RUNNER_DESC" \
  http://localhost:8929/api/v4/user/runners | sed -E 's/.*"token":"([^"]+)".*/\1/')

# --docker-privileged + the /certs/client volume are what make docker:dind work.
# Privileged containers can escape to the host daemon; fine for a local playpen only.
echo "Registering runner container (privileged, for docker-in-docker)..."
compose exec -T runner gitlab-runner register --non-interactive \
  --url http://gitlab:8929 \
  --token "$RUNNER_TOKEN" \
  --executor docker \
  --docker-image alpine:3.20 \
  --docker-network-mode gitlab-playpen \
  --docker-privileged \
  --docker-volumes /certs/client \
  --clone-url http://gitlab:8929

compose restart runner

FINAL=$(compose exec -T runner sh -c "grep -c '^\[\[runners\]\]' /etc/gitlab-runner/config.toml" | tr -d '\r')
echo "Registered runners in config.toml: $FINAL (expected 1)"
[ "$FINAL" = "1" ] || { echo "WARNING: expected exactly 1 runner, found $FINAL" >&2; exit 1; }

echo "Done. UI: http://localhost:8929  (root / \$GITLAB_ROOT_PASSWORD)"
echo "Add '127.0.0.1 gitlab' to /etc/hosts so external_url links resolve from the browser."
