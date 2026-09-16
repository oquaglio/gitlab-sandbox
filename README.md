# GitLab Pipelines Playpen

A local sandbox for experimenting with GitLab CI features without GitLab.com. Every job is a NOP or only logs output, so it's safe to break things.

Two ways to run it:

| Mode | What runs | Cost | Use for |
|---|---|---|---|
| **Light** — `gitlab-ci-local` | Jobs in Docker straight from `.gitlab-ci.yml`, no server | Seconds, tiny | Fast iteration on YAML, rules, needs, matrix |
| **Heavy** — GitLab CE + `gitlab-runner` | Real GitLab server and real runner | ~4 GB RAM, ~5 min boot | Pipeline UI, manual jobs, environments, "Run pipeline" variables |

## Layout

```
.gitlab-ci.yml                  # the playpen pipeline
ci/templates.yml                # hidden .log-job template (include + extends)
.gitlab-ci-local-variables.yml  # stand-in for project CI/CD variables (light mode)
justfile                        # all commands
docker-compose.yml              # GitLab CE + gitlab-runner (heavy mode)
scripts/register-runner.sh      # creates + registers an instance runner via the API
```

## Pipeline features demonstrated

| Feature | Job(s) |
|---|---|
| `stages`, `default:image`, `interruptible` | all |
| `workflow:rules` | top level |
| `include: local` + `extends` + `before_script`/`after_script` | all (via `.log-job`) |
| Pipeline variable with `options` dropdown | `DEPLOY_ENV` |
| `parallel:matrix` (2×2), `cache`, `artifacts` | `build` |
| `needs` (DAG), including `needs: []` to skip stage ordering | `unit-tests`, `flaky-test` |
| `retry`, `allow_failure` | `flaky-test` |
| `rules` on default branch | `only-on-main` |
| `when: manual` + `environment` | `deploy` |
| `when: always` | `cleanup` |

## Prerequisites

- Docker
- [`just`](https://github.com/casey/just)
- Node/npm. Any version works: the justfile fetches Node 22 through `npx -p node@22`, since gitlab-ci-local needs 22+.
- **`rsync`** is required. Light mode copies the repo into each job with it, and without it every run fails with `rsync: command not found` (exit 127):
  ```sh
  sudo dnf install -y rsync      # Fedora
  sudo apt install -y rsync      # Debian/Ubuntu
  ```
- A git repo. gitlab-ci-local **only sees files git tracks or has staged**, so run `git add -A` after adding files.
  ```

## Light mode: gitlab-ci-local

```sh
just list          # show jobs, stages, when, needs
just preview       # print the fully-resolved pipeline (includes/extends expanded)
just run           # run the whole pipeline (skips manual jobs)
just job unit-tests  # run one job plus the jobs it needs
just run-manual    # also run the manual `deploy` job
just run --help    # any gitlab-ci-local flag passes straight through
```

Set variables in `.gitlab-ci-local-variables.yml`, or per run with `just run --variable DEPLOY_ENV=prod`.

Warnings like `git rev-parse HEAD`, `No such remote 'origin'` or `origin/HEAD is not a symbolic ref` mean the repo has no commits, no remote, or no remote default branch set. The tool falls back to defaults and keeps going. See Prerequisites for the `set-head` fix.

Run output goes to `.gitlab-ci-local/` (gitignored).

## Heavy mode: GitLab CE + real runner

```sh
echo "GITLAB_ROOT_PASSWORD=$(openssl rand -base64 18)" > .env   # once; .env is gitignored
just up            # start GitLab + runner
just logs          # optional: watch GitLab boot (Ctrl-C to stop tailing)
just register      # waits for readiness, creates an instance runner, registers it
```

Then:

1. Add `127.0.0.1 gitlab` to your hosts file so links in the UI resolve. On WSL, edit the **Windows** hosts file for browser access.
2. Open <http://localhost:8929> and sign in as `root` with the password from `.env`.
3. Create a blank project, then push this repo to it:
   ```sh
   git remote add playpen http://localhost:8929/root/<project>.git
   git push playpen main
   ```
4. Watch the pipeline under **Build → Pipelines**. Try **Run pipeline** to pick `DEPLOY_ENV` from the dropdown, and trigger `deploy` by hand.

Jobs run as sibling containers on the host Docker daemon, on the `gitlab-playpen` network.

With **rootless Docker**, point compose at your user socket before `just up`:

```sh
export DOCKER_SOCK=$XDG_RUNTIME_DIR/docker.sock
```

```sh
just down          # stop, keep data
just nuke          # DESTRUCTIVE: delete all GitLab/runner volumes (asks for confirmation)
```

## Security notes

- The runner mounts the Docker socket (`$DOCKER_SOCK`, default `/var/run/docker.sock`), which gives it full control of the daemon: **root-equivalent on the host** with rootful Docker, your user's privileges with rootless. Only run pipelines you trust, and don't reuse this setup outside a playpen.
- The root password lives in a gitignored `.env`; compose refuses to start without it. It's only read on first boot — changing it later requires `just nuke`.
- Ports are bound to `127.0.0.1` only.
- `register-runner.sh` creates a root personal access token (`api`, `create_runner`) that expires after 1 day.

## Troubleshooting

| Symptom | Fix |
|---|---|
| GitLab container exits; logs say `Password must not contain commonly used combinations` | Use a stronger `GITLAB_ROOT_PASSWORD`, then `just nuke && just up` (the first boot left a half-seeded DB). |
| `a network with name gitlab-playpen exists but was not created for project` | Leftover from an older checkout/project name. `docker compose -p <old-name> down`, then `just up`. |
| `kW.union is not a function` | Node < 22 is being used. Run through `just`, which pulls in Node 22. |
| `rsync: command not found` | `sudo dnf install -y rsync` |
| `Local include file cannot be found` | The file isn't tracked. Run `git add -A`. |
| Runner logs `permission denied` / `Cannot connect to the Docker daemon` (rootless) | `DOCKER_SOCK` wasn't set, so the root socket path was mounted. Export it, then `just down && just up`. |
| `just register` hangs on dots | GitLab is still booting. First boot can take 5+ minutes. |
| Jobs stuck "pending" in the UI | Check the runner: `just logs runner`. Re-run `just register` if needed. |
