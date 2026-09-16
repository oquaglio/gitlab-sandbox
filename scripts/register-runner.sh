#!/usr/bin/env bash
# Registers the playpen's two instance runners:
#
#   playpen       untagged, UNPRIVILEGED  -- the ordinary jobs
#   playpen-dind  tags: dind, PRIVILEGED  -- docker-build only
#
# Splitting them keeps privileged mode scoped to the one job that needs it
# instead of every job in the pipeline.
#
# Idempotent: re-running removes whatever is registered (locally and in GitLab)
# and replaces it with exactly these two. Safe to re-run after changing settings.
set -euo pipefail

compose() { docker compose "$@"; }

export RUNNER_DESC_PREFIX="playpen"
PAT_NAME="playpen-runner-setup"
GL="http://localhost:8929"

echo "Waiting for GitLab to be healthy (can take several minutes)..."
until compose exec -T gitlab curl -sf "$GL/-/readiness" >/dev/null 2>&1; do
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

# --- reconcile: clear both sources of truth before registering ----------------
"$(dirname "$0")/unregister-runners.sh"

# --- create the GitLab-side runner objects ------------------------------------
# $1 = description, remaining args = extra --data fields
create_runner() {
  desc="$1"; shift
  compose exec -T gitlab curl -sf -X POST -H "PRIVATE-TOKEN: $PAT" \
    --data "runner_type=instance_type" --data "description=$desc" "$@" \
    "$GL/api/v4/user/runners" | sed -E 's/.*"token":"([^"]+)".*/\1/'
}

echo "Creating runner 'playpen' (untagged)..."
TOKEN_PLAIN=$(create_runner "playpen" --data "run_untagged=true")

echo "Creating runner 'playpen-dind' (tags: dind)..."
TOKEN_DIND=$(create_runner "playpen-dind" --data "run_untagged=false" --data "tag_list[]=dind")

# --- register both against the one runner container ---------------------------
# Both live as separate [[runners]] blocks in the same config.toml; a second
# container is not needed.
echo "Registering 'playpen' (unprivileged)..."
compose exec -T runner gitlab-runner register --non-interactive \
  --url "http://gitlab:8929" \
  --token "$TOKEN_PLAIN" \
  --name "playpen" \
  --executor docker \
  --docker-image alpine:3.20 \
  --docker-network-mode gitlab-playpen \
  --clone-url "http://gitlab:8929"

# --docker-privileged + the /certs/client volume are what make docker:dind work.
# Privileged containers can escape to the host daemon; scoped to this runner so
# only jobs tagged `dind` get it.
echo "Registering 'playpen-dind' (privileged, for docker-in-docker)..."
compose exec -T runner gitlab-runner register --non-interactive \
  --url "http://gitlab:8929" \
  --token "$TOKEN_DIND" \
  --name "playpen-dind" \
  --executor docker \
  --docker-image alpine:3.20 \
  --docker-network-mode gitlab-playpen \
  --docker-privileged \
  --docker-volumes /certs/client \
  --clone-url "http://gitlab:8929"

# Two runners serialise at concurrent = 1, which would stall a pipeline whose
# tagged and untagged jobs overlap.
echo "Setting concurrent = 2..."
compose exec -T runner sh -c '
  f=/etc/gitlab-runner/config.toml
  sed -i "s/^concurrent = .*/concurrent = 2/" "$f"
  grep -q "^concurrent" "$f" || sed -i "1i concurrent = 2" "$f"
'

compose restart runner

FINAL=$(compose exec -T runner sh -c "grep -c '^\[\[runners\]\]' /etc/gitlab-runner/config.toml" | tr -d '\r')
echo "Registered runners in config.toml: $FINAL (expected 2)"
[ "$FINAL" = "2" ] || { echo "WARNING: expected exactly 2 runners, found $FINAL" >&2; exit 1; }

echo "Done. UI: $GL  (root / \$GITLAB_ROOT_PASSWORD)"
echo "Add '127.0.0.1 gitlab' to /etc/hosts so external_url links resolve from the browser."
