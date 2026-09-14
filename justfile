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

# Create + register an instance runner (run after `up`)
register:
    ./scripts/register-runner.sh

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
