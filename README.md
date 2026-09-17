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
ci/modular.yml                  # modular example: entry point, spec:inputs toggles
ci/modules/                     #   routing layer -- only where a variant choice exists
ci/templates/                   #   implementation layer -- hidden .jobs
ci/jobs/                        #   instantiation layer -- concrete jobs
.gitlab-ci-local-variables.yml  # stand-in for project CI/CD variables (light mode)
justfile                        # all commands
docker-compose.yml              # GitLab CE + gitlab-runner (heavy mode)
scripts/register-runner.sh      # idempotently registers the two instance runners
scripts/check-ci-matrix.sh      # asserts each modular.yml input combo yields the right jobs
scripts/unregister-runners.sh   # removes all runners from GitLab *and* config.toml
Dockerfile                      # trivial image built by the `docker-build` job
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
| `services` + docker-in-docker (`docker:dind`) | `docker-build` |
| `tags` routing a job to a specific runner | `docker-build` (`dind`) |
| Build + push to the built-in container registry (`$CI_REGISTRY_IMAGE`, `$CI_JOB_TOKEN`) | `docker-build` |
| `spec:inputs` with `options`, `$[[ inputs.x ]]`, conditional `include:rules` | `greeting`, `lint-yaml` |

### Modular job structure

`ci/modular.yml` is a cut-down version of the layered pattern used in larger GitLab setups, where
a shared "base project include" is consumed by many stacks. Three layers, each with one job:

| Layer | Responsibility | Contains |
|---|---|---|
| `ci/modules/*.yml` | **route** -- decide *which variant* to include | `spec:inputs` + `include:` with `rules:`. No job bodies. |
| `ci/templates/*.yml` | **implement** | hidden `.jobs`, reused via `extends` |
| `ci/jobs/*.yml` | **instantiate** | concrete jobs: `extends` a template, pick a stage |

The consumer only sets flags:

```yaml
include:
  - local: ci/modular.yml
    inputs:
      greeting: "simple"      # off | simple | fancy
      include_lint: true
```

Two things this buys you. `greeting: "off"` removes a whole feature set without touching any job
definition. And `simple` vs `fancy` swaps which `ci/templates/greeting_*.yml` defines `.greeting`,
so behaviour changes while the job graph stays identical -- `ci/jobs/greeting.yml` never mentions
an implementation.

**One input per module, not a toggle plus a separate variant.** `greeting` carries both the on/off
decision and the implementation choice, which makes the relationship structural: a variant cannot
be selected for a module that is off. Under two inputs, `include_greeting: false` +
`greeting_variant: "fancy"` was legal and silently meaningless. `include_lint` stays a plain
boolean because lint has one implementation and nothing to pick.

The opposite case is a selector shared across *several* modules -- BHP's `asset` -- which belongs
as its own input, because it genuinely is orthogonal to any one module's toggle.

Check either with `just list` (job graph) or `just preview` (fully-resolved YAML).

**A module file only earns its place when it picks between two or more implementations.** `greeting`
has two, so `ci/modules/greeting.yml` exists. `lint` has one, so there is no `ci/modules/lint.yml` --
`ci/modular.yml` gates its template and jobs file directly. One less file, one less hop.

**Verify combinations before pushing**, with `just check-matrix`:

```
--- job sets ---
ok    both on, simple            -> greeting lint-yaml
ok    greeting off               -> lint-yaml
ok    lint off                   -> greeting
ok    both off                   -> <no jobs>
--- variant routing ---
ok    variant=fancy present needle -> present
```

This exists because the pattern fails *silently*: a wrong `rules:` expression does not error, it
includes nothing, and the job simply is not in the pipeline. A typo'd input **name** is a hard
error; a typo'd input **value** (`"True"`) is an invisible omission. `scripts/check-ci-matrix.sh`
asserts the expected job set for each combination, so that omission becomes a non-zero exit.

It runs locally rather than as a pipeline job: it drives `gitlab-ci-local`, which needs the repo's
git metadata and so does not work nested inside a job container.

Note `ci/modular.yml` deliberately does not declare `stages:`. A real base include owns the
stage list, but `stages` does not merge across included files -- the last definition wins -- so
declaring it there would clobber the root pipeline's.

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
just dind          # run the docker-in-docker `docker-build` job
```

In light mode there is no registry, so `docker-build` builds and runs the image but skips the
push (it keys off `$CI_REGISTRY_USER`, which only a real GitLab sets). The image lives in the
dind service container and is discarded when the job ends — it never reaches the host daemon.

`docker-build` needs two extra things gitlab-ci-local doesn't do by default, which `just dind`
supplies: `--privileged` (so the `docker:dind` service can start) and a named volume shared at
`/certs/client` (so the job's docker client can find the TLS certs dind generates). Plain
`just run` will fail that job. The Dockerfile must be tracked by git — gitlab-ci-local only
copies tracked files into the job container.

Set variables in `.gitlab-ci-local-variables.yml`, or per run with `just run --variable DEPLOY_ENV=prod`.

Warnings like `git rev-parse HEAD`, `No such remote 'origin'` or `origin/HEAD is not a symbolic ref` mean the repo has no commits, no remote, or no remote default branch set. The tool falls back to defaults and keeps going. See Prerequisites for the `set-head` fix.

Run output goes to `.gitlab-ci-local/` (gitignored).

## Container registry

Enabled over HTTP on port 5005 (`registry_external_url 'http://gitlab:5005'` in `docker-compose.yml`).
`docker-build` pushes to `$CI_REGISTRY_IMAGE:$CI_COMMIT_SHORT_SHA` using `$CI_JOB_TOKEN`, exactly as
a real GitLab pipeline would. Browse pushed images at
<http://localhost:8929/root/gitlab-sandbox/container_registry>.

Changing the registry settings only needs a container recreate, not a `just nuke`:
`docker compose up -d gitlab` (volumes are preserved; reconfigure takes a few minutes on boot).

## Runners

The playpen registers **two** instance runners, both as `[[runners]]` blocks in the same runner
container (a second container isn't needed):

| Runner | Tags | `run_untagged` | `privileged` | Runs |
|---|---|---|---|---|
| `playpen` | — | `true` | `false` | every ordinary job |
| `playpen-dind` | `dind` | `false` | `true` | `docker-build` only |

The split exists so privileged mode is scoped to the one job that needs it, rather than applying
to every `alpine` echo job in the pipeline. `config.toml` is set to `concurrent = 2` so the two
don't serialise.

A runner only matches a job when it carries **all** the job's tags, so `tags: [dind]` on
`docker-build` pins it to the privileged runner, and `run_untagged=false` stops that runner
taking anything else. Adding a job with a tag no runner carries leaves it pending forever rather
than failing — that's the usual cause of a "stuck" pipeline.

`just register` is idempotent — it reconciles to exactly these two however things started, so
it's safe to re-run after changing executor settings:

```sh
just runners     # show what's currently registered
just register    # reconcile to exactly the two runners (deletes any existing ones)
just unregister  # remove all runners (prompts); `just register` re-creates them
```

Both commands share `scripts/unregister-runners.sh`, which resets **both** sources of truth,
because they drift apart independently:

1. `gitlab-runner unregister --all-runners` — best effort, so tokens get revoked cleanly. Its
   result is not relied on: it partially fails once `config.toml` holds entries GitLab has
   already dropped.
2. GitLab's runner list, via `gitlab-rails` — authoritative for the server side.
3. The runner container's `config.toml` — every `[[runners]]` block is stripped, keeping the
   global section. A `.bak` is left beside it.

Steps 2 and 3 are what guarantee the outcome, and `register` asserts it ended with exactly two
runners (exiting non-zero otherwise).

> **Why unregistering alone isn't enough.** `gitlab-runner unregister` removes the runner
> *manager* — the local registration. With token-based registration the runner itself is a
> GitLab-side object created through the API, so unregistering clears `config.toml` but leaves
> the runner orphaned in the UI (`managers=0`, still listed, still showing as online). Deleting
> it server-side is a separate step.

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
- Only the `playpen-dind` runner is registered with `--docker-privileged`, and only jobs tagged `dind` reach it. A privileged job container can escape to the host kernel, so keeping it off the default runner means an ordinary job can't get it by accident. Still the standard dind trade-off, and a reason to only run pipelines you trust here.
- `docker-build` talks to dind over TLS (`DOCKER_TLS_VERIFY=1`) rather than the unauthenticated `tcp://docker:2375`, so nothing else on the job network can drive the daemon.
- The container registry runs over **plain HTTP** on `127.0.0.1:5005`, and dind is started with `--insecure-registry=gitlab:5005` so it will talk to it. That means registry traffic (including the `docker login` bearer token) is unencrypted on the `gitlab-playpen` network, and dind skips TLS verification for that host. Acceptable for a localhost-bound playpen; do not copy this into anything real — use `https://` and a proper certificate.

## Troubleshooting

| Symptom | Fix |
|---|---|
| GitLab container exits; logs say `Password must not contain commonly used combinations` | Use a stronger `GITLAB_ROOT_PASSWORD`, then `just nuke && just up` (the first boot left a half-seeded DB). |
| `a network with name gitlab-playpen exists but was not created for project` | Leftover from an older checkout/project name. `docker compose -p <old-name> down`, then `just up`. |
| `kW.union is not a function` | Node < 22 is being used. Run through `just`, which pulls in Node 22. |
| `rsync: command not found` | `sudo dnf install -y rsync` |
| `docker push`: `server gave HTTP response to HTTPS client` | dind isn't allowing the plain-HTTP registry. Check the `command: ["--insecure-registry=gitlab:5005"]` on the dind service, and that `docker info` inside dind lists `gitlab:5005` under Insecure Registries. |
| `docker login`: `denied` / 401 | The registry needs `$CI_REGISTRY_USER` + `$CI_REGISTRY_PASSWORD` (job token). Outside a job, use a PAT with `write_registry` scope. |
| `docker-build`: `open /certs/client/ca.pem: no such file or directory`, or dind logs `mount: permission denied (are you root?)` | The job ran on the unprivileged `playpen` runner. Check `docker-build` still has `tags: [dind]`, and re-run `just register`. Light mode: use `just dind`. |
| A job sits pending forever | No runner carries all its tags. `just runners` shows what's registered; an untagged job needs `playpen`, a `dind`-tagged one needs `playpen-dind`. |
| Jobs stuck pending, or duplicate runners in the UI | `just runners` to see what's registered, then `just register` to reconcile down to one. |
| A runner still shows in the GitLab UI after unregistering it by hand | `gitlab-runner unregister` only removes the local manager, not the GitLab-side runner. Use `just unregister`, which deletes both. |
| `docker-build`: `nc: bad address 'docker'` / `wait-for-it.sh: timeout` | The dind service couldn't start — it needs privileged mode. `just dind`. |
| `docker-build`: `failed to read dockerfile` | `Dockerfile` isn't tracked by git; `git add Dockerfile`. |
| `Local include file cannot be found` | The file isn't tracked. Run `git add -A`. |
| Runner logs `permission denied` / `Cannot connect to the Docker daemon` (rootless) | `DOCKER_SOCK` wasn't set, so the root socket path was mounted. Export it, then `just down && just up`. |
| `just register` hangs on dots | GitLab is still booting. First boot can take 5+ minutes. |
| Jobs stuck "pending" in the UI | Check the runner: `just logs runner`. Re-run `just register` if needed. |
