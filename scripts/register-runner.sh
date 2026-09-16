#!/usr/bin/env bash
# Creates an instance runner via the GitLab API and registers the runner container with it.
set -euo pipefail

compose() { docker compose "$@"; }

echo "Waiting for GitLab to be healthy (can take several minutes)..."
until compose exec -T gitlab curl -sf http://localhost:8929/-/readiness >/dev/null 2>&1; do
  sleep 10; printf '.'
done
echo " ready"

echo "Creating short-lived root PAT..."
PAT="glpat-playpen-$(head -c 12 /dev/urandom | od -An -tx1 | tr -d ' \n')"
compose exec -T gitlab gitlab-rails runner "
  u = User.find_by_username('root')
  t = u.personal_access_tokens.create!(name: 'playpen-runner-setup', scopes: [:api, :create_runner], expires_at: 1.day.from_now)
  t.set_token('$PAT'); t.save!
" >/dev/null

echo "Creating instance runner..."
RUNNER_TOKEN=$(compose exec -T gitlab curl -sf -X POST \
  -H "PRIVATE-TOKEN: $PAT" \
  --data "runner_type=instance_type" --data "run_untagged=true" --data "description=playpen" \
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
echo "Done. UI: http://localhost:8929  (root / \$GITLAB_ROOT_PASSWORD)"
echo "Add '127.0.0.1 gitlab' to /etc/hosts so external_url links resolve from the browser."
