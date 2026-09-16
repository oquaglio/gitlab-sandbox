set shell := ["bash", "-euo", "pipefail", "-c"]

gcl := "npx --yes -p node@22 -p gitlab-ci-local@latest gitlab-ci-local"

default:
    @just --list

# --- Lightweight: gitlab-ci-local (no GitLab server) -------------------

# List jobs the pipeline would run
list:
    {{gcl}} --list

# Run the whole pipeline locally in Docker
run *args:
    {{gcl}} {{args}}

# Run a single job (plus its needs), e.g. `just job unit-tests`
job name:
    {{gcl}} "{{name}}" --needs

# Run the docker-in-docker build job (needs privileged + a shared certs volume)
dind:
    {{gcl}} docker-build --privileged --volume gcl-dind-certs:/certs/client

# Include manual jobs, e.g. deploy
run-manual:
    {{gcl}} --manual deploy

# Print the fully-expanded pipeline (includes/extends resolved)
preview:
    {{gcl}} --preview

# --- Heavyweight: GitLab CE + real gitlab-runner -----------------------

# Start GitLab + runner containers
up:
    docker compose up -d

# Register both runners: 'playpen' (untagged) + 'playpen-dind' (privileged)
register:
    ./scripts/register-runner.sh

# Show registered runners (config.toml view)
runners:
    @docker compose exec -T runner sh -c 'grep -E "^\\[\\[runners\\]\\]|^  name =|^  id =|privileged|volumes" /etc/gitlab-runner/config.toml || echo "(none registered)"' </dev/null

# Unregister ALL runners (removes them from GitLab too); `just register` re-creates one
unregister:
    @echo "This removes every playpen runner, from both GitLab and config.toml:"
    @docker compose exec -T runner sh -c 'echo "  config.toml entries: $(grep -cE "^\\[\\[runners\\]\\]" /etc/gitlab-runner/config.toml || true)"' </dev/null
    @docker compose exec -T gitlab gitlab-rails runner 'rs = Ci::Runner.where(description: "playpen"); puts %(  in GitLab: #{rs.count} -> ids #{rs.map(&:id).join(", ")})' </dev/null 2>/dev/null | grep "in GitLab"
    @read -p "Type 'yes' to confirm: " c && [ "$c" = yes ]
    ./scripts/unregister-runners.sh
    docker compose restart runner
    @just runners

# Tail GitLab logs
logs svc="gitlab":
    docker compose logs -f {{svc}}

# Stop containers (keeps volumes)
down:
    docker compose down

# DESTRUCTIVE: stop and delete all GitLab/runner volumes
nuke:
    @echo "This deletes volumes: gitlab-config, gitlab-logs, gitlab-data, runner-config"
    @read -p "Type 'nuke' to confirm: " c && [ "$c" = nuke ]
    docker compose down -v
