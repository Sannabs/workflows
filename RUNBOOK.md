# Deploy Runbook

How every app here gets from a merged pull request to a running server, and how to do every routine job by hand. Read section 0 once; after that, jump to the recipe you need.

Placeholders used throughout:

- `<alias>` — the droplet's SSH alias from your Mac's `~/.ssh/config` (e.g. `myapp-droplet`)
- `<app>` — the app's folder under `/var/www` on the droplet (e.g. `backend`)
- `<owner>/<repo>` — the GitHub repository (e.g. `acme/shop-backend`)
- `<branch>` — the repo's default branch, usually `main` (some repos use `master`)

Your private inventory (which droplet runs which app, and each app's quirks) lives in a separate private repo, never here.

---

## 0. How it works

```
 you merge a PR
      │
      ▼
 GitHub Actions — a fresh, throwaway Ubuntu machine
   job 1  test / build ── fails? stop. nothing ships.
   job 2  deploy ───────SSH with the CI key──────────►  droplet
                                                          authorized_keys: "this key may only run deploy.sh"
                                                          deploy.sh: git fetch (deploy key) → reset to the SHA → boot.sh
                                                          boot.sh:   npm ci → build / migrate → pm2 reload
```

**The three keys** — each does exactly one job:

- **CI key** (GitHub → droplet). Private half is the repo secret `DEPLOY_SSH_KEY`. On the droplet a *forced command* means it can only ever run `deploy.sh <app>` with a commit SHA. Leaked, the worst it can do is redeploy your own code.
- **Deploy key** (droplet → GitHub). Read-only, one repo. Lets the droplet `git fetch` without your personal key.
- **Your personal key** (you → droplet). For humans. CI never touches it.

**The host key** is the droplet's identity, stored as `DEPLOY_KNOWN_HOSTS` so CI refuses to talk to anything impersonating it.

**Where each piece lives:**

- `.github/workflows/ci.yml` — in each app repo. Runs the checks, then calls the shared deploy job.
- `.github/workflows/deploy.yml` — in this repo. The shared deploy job every app calls as `@v1`.
- `scripts/setup-deploy.sh` — in this repo. One-time wiring of keys and secrets for one app.
- `~/bin/deploy.sh` — on each droplet. The forced command: checks out the exact commit, then runs `boot.sh`.
- `boot.sh` — in each app repo. Install, build, migrate, restart. Also works when you run it by hand.
- Four secrets in each app repo: `DEPLOY_SSH_KEY`, `DEPLOY_KNOWN_HOSTS`, `DEPLOY_HOST`, `DEPLOY_USER`.

**Three rules that follow from this design:**

1. **Never edit code on a droplet.** Every deploy runs `git reset --hard`, which wipes it. Change it in the repo.
2. **Merging is deploying.** A merge to `<branch>` reaches production a few minutes later — including any database migration in it.
3. **The droplet's `.env` is the source of truth for config.** It is untracked, so deploys never touch it.

---

## 1. Everyday: ship a change

**1.** Branch, commit, push:

```bash
git switch -c fix/short-name
```

```bash
git push -u origin fix/short-name
```

**2.** Open the PR and watch CI. The `deploy` job shows *skipping* — PRs never deploy.

```bash
gh pr create --fill --base <branch>
```

```bash
gh pr checks --watch
```

**3.** Merge (squash keeps `<branch>` to one commit per change) and watch the deploy:

```bash
gh pr merge --squash --delete-branch
```

```bash
gh run watch --exit-status $(gh run list --branch <branch> --limit 1 --json databaseId --jq '.[0].databaseId')
```

Expect `test`/`build` ✓ then `deploy / deploy` ✓. Frontend deploys take several minutes: `next build` runs on the droplet.

**4.** Trust the droplet, not the green tick:

```bash
ssh <alias> "pm2 ls && git -C /var/www/<app> log -1 --oneline"
```

The commit shown must be your merge commit, and the app `online` with a low `↺` (restart) count.

> If your network drops while a `gh` command runs (`unexpected EOF`, `operation timed out`), check what already happened on GitHub before re-running anything. A merge cannot be repeated; a watch can.

---

## 2. Recipes

### 2.1 Add or change an environment variable

Order matters: **droplet first, then merge.** A backend that validates env on boot will crash-loop if the code arrives before the variable.

1. Add it to `.env.example` in the PR that needs it.
2. Before merging, add it on the droplet:

   ```bash
   ssh <alias>
   ```

   ```bash
   nano /var/www/<app>/.env
   ```

3. Merge. The deploy restarts the app, which reads `.env` on start.

**Changing only a value** (no code change, so no deploy will happen): restart it yourself.

```bash
ssh <alias> "pm2 reload <pm2-name> --update-env"
```

**Frontend `NEXT_PUBLIC_*` / `VITE_*` variables are baked in at build time.** A restart is not enough — rebuild:

```bash
ssh <alias> "/var/www/<app>/boot.sh"
```

Never put a secret in a `NEXT_PUBLIC_*` or `VITE_*` variable: anything with that prefix ships to every browser.

### 2.2 Roll back a bad deploy

**Preferred — revert through the pipeline.** Keeps `<branch>` truthful and goes through CI:

```bash
gh pr list --state merged --limit 5
```

Find the bad PR's merge commit on GitHub, then:

```bash
git switch <branch> && git pull && git revert --no-edit <merge-sha>
```

```bash
git switch -c revert/short-name && git push -u origin revert/short-name && gh pr create --fill --base <branch>
```

Merge it like any other PR.

**Emergency — put an older commit live right now**, bypassing CI:

```bash
ssh <alias> "/var/www/<app>/boot.sh <older-full-sha>"
```

The next merge redeploys `<branch>` over it, so follow up with a revert PR.

**Database migrations never roll back.** Reverting code that added a column leaves the column. If a migration is the problem, write a new migration that undoes it.

### 2.3 A deploy failed — re-run or fix?

Read the failing step first:

```bash
gh run view --log-failed
```

- **The problem was outside the repo** (missing secret, droplet down, GitHub outage, a key you just fixed): re-run only the failed job. Secrets are read when a job starts, so it picks up your fix.

  ```bash
  gh run rerun <run-id> --failed
  ```

- **The problem is in the repo** (a bug, or a mistake in `ci.yml`): re-running replays the same broken commit. Fix it in a new PR.

Re-runs of an old run use the shared workflow as `v1` points **today**, but the app's own files as they were **at that commit**.

### 2.4 Deploy by hand (GitHub down, or testing `boot.sh`)

```bash
ssh <alias>
```

```bash
/var/www/<app>/boot.sh
```

With no argument it deploys the tip of the default branch. Pass a full SHA to deploy a specific commit.

### 2.5 Add CI/CD to a new app

Checklist — do it in this order.

**a. Pick the Node version** the droplet runs and pin it in the repo:

```bash
ssh <alias> "node -v"
```

```bash
printf '24.21.0\n' > .nvmrc
```

**b. Make `boot.sh` deploy an exact commit.** Its code-update block must be:

```bash
echo "==> Fetching code"
git fetch --quiet origin
# CI passes the commit it tested; a manual ./boot.sh deploys the default branch
git reset --hard "${1:-origin/HEAD}"
```

…and it must start with `cd "$(dirname "$0")"`, migrate **before** restarting, and end with `pm2 save`. Make it executable in git:

```bash
chmod +x boot.sh && git update-index --chmod=+x boot.sh
```

If the repo commits build output (`dist/`, `.next/`), stop tracking it — see 2.12 first.

**c. Add `.github/workflows/ci.yml`.** Backend template:

```yaml
name: CI

on:
  pull_request:
    branches: [main]
  push:
    branches: [main]

permissions:
  contents: read

jobs:
  test:
    runs-on: ubuntu-latest
    timeout-minutes: 10
    concurrency:
      group: test-${{ github.ref }}
      cancel-in-progress: true
    steps:
      - uses: actions/checkout@v5

      - uses: actions/setup-node@v5
        with:
          node-version-file: .nvmrc
          cache: npm

      - run: npm ci
      - run: npm test

  deploy:
    needs: test
    if: github.event_name == 'push' && github.ref_name == github.event.repository.default_branch
    # Serialised and never cancelled: killing boot.sh mid-migrate is worse than waiting
    concurrency:
      group: deploy-${{ github.repository }}
      cancel-in-progress: false
    uses: Sannabs/workflows/.github/workflows/deploy.yml@v1
    secrets:
      DEPLOY_SSH_KEY: ${{ secrets.DEPLOY_SSH_KEY }}
      DEPLOY_KNOWN_HOSTS: ${{ secrets.DEPLOY_KNOWN_HOSTS }}
      DEPLOY_HOST: ${{ secrets.DEPLOY_HOST }}
      DEPLOY_USER: ${{ secrets.DEPLOY_USER }}
```

Adapt the checks to the repo:

- **Default branch is `master`?** Change both `branches: [main]` lines. Nothing else.
- **Prisma without a `postinstall`?** Add `- run: npx prisma generate` after `npm ci`.
- **A module throws at import without an env var?** Add a job-level `env:` with a dummy value (e.g. `DATABASE_URL: postgresql://ci:ci@127.0.0.1:5432/ci`). Dummies are fine when nothing actually connects.
- **A module really connects to Postgres at import?** Start the runner's own Postgres (SSL on by default) and pin `runs-on: ubuntu-24.04`:

  ```yaml
      - name: Start Postgres
        run: |
          sudo systemctl start postgresql.service
          sudo -u postgres psql -q -c "CREATE USER ci WITH PASSWORD 'ci';" -c "CREATE DATABASE ci OWNER ci;"
  ```

- **No tests?** Run what you have: `npm run build`, or `npx tsc --noEmit` for TypeScript run through `tsx`.
- **Frontend:** call the job `build` and run `npm ci`, `npm run lint` (only if it has zero errors today), `npm run build`. `next build` also type-checks.

Before trusting a check in CI, run it locally **without your `.env`**, to catch hidden dependencies on local config:

```bash
env -i HOME=$HOME PATH=$PATH DOTENV_CONFIG_PATH=/dev/null npm test
```

**d. Open the PR** (section 1, steps 1–2). Expect the check ✓ and `deploy` skipping. Don't merge yet.

**e. Wire keys and secrets** — run from your Mac:

```bash
~/Desktop/workflows/scripts/setup-deploy.sh <alias> <app> <owner>/<repo>
```

It checks the host key, creates the droplet's deploy key and CI key, proves the CI key cannot open a shell, opens GitHub's deploy-key page (paste, **write access off**, Add key, then Enter), proves the droplet can fetch, and sets the four secrets. It ends with `==> Done`.

**f. Merge the PR** (section 1, steps 3–4). The merge is the first automatic deploy.

### 2.6 Add a new droplet

1. Create a non-root user with sudo and log in with your key. Add an alias in your Mac's `~/.ssh/config`:

   ```
   Host <alias>
       HostName <ip>
       User <user>
       IdentityFile ~/.ssh/<your-key>
   ```

   Don't add `ForwardAgent yes` — deploys don't need it, and it lets anyone with root on the droplet use your GitHub key while you're logged in.

2. Install Node from NodeSource (section 2.7), then PM2:

   ```bash
   sudo npm install -g pm2
   ```

3. Clone each app into `/var/www/<app>`, create its `.env`, and run `./boot.sh` once by hand.
4. Make PM2 survive reboots (section 2.8).
5. nginx + certbot as usual.
6. For each app: section 2.5.

### 2.7 Upgrade Node on a droplet

**a. Prove the app works on the new version first.** Bump `.nvmrc` in a PR and let CI run on it. Merge only when green.

**b. On the droplet, check who owns PM2:**

```bash
systemctl is-enabled pm2-sanna
```

**c. Save what's running, then install the new Node:**

```bash
pm2 save
```

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt-get install -y nodejs && node -v
```

If this fails at `apt update`, a stale third-party apt source is broken — see Troubleshooting.

**d. Restart PM2 on the new Node.** Pick one, based on step b:

- `enabled` → systemd owns PM2. **Never `pm2 update` here** — it kills the daemon systemd is watching, systemd then stops everything, and your apps vanish.

  ```bash
  sudo systemctl restart pm2-sanna && sleep 5 && pm2 ls
  ```

- `not-found` → no service yet:

  ```bash
  pm2 update
  ```

  …then do section 2.8 so the droplet survives reboots.

**e. Redeploy each app** so `node_modules` is rebuilt for the new version — merge anything pending, or run `boot.sh` by hand.

### 2.8 Make PM2 survive reboots

```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u <user> --hp /home/<user>
```

```bash
pm2 save
```

`startup` installs a systemd service (`pm2-<user>`) that runs `pm2 resurrect` at boot; `save` records what to resurrect. Re-run `pm2 save` whenever you add or remove a PM2 app.

### 2.9 Rotate keys

**CI key** (routine, or if a secret may have leaked) — re-run the setup script. It replaces the old key on the droplet and the secret on GitHub in one go:

```bash
~/Desktop/workflows/scripts/setup-deploy.sh <alias> <app> <owner>/<repo>
```

**Deploy key** — delete it on GitHub (repo → Settings → Deploy keys), delete it on the droplet, then re-run the setup script, which creates and registers a new one:

```bash
ssh <alias> "rm ~/.ssh/github_<repo-name-lowercase> ~/.ssh/github_<repo-name-lowercase>.pub"
```

**Droplet rebuilt** (new host key): re-run the setup script for each of its apps. It refuses to continue if the host key it scans doesn't match what the droplet reports.

### 2.10 Change the shared deploy workflow

Every app follows the `v1` tag, so changing `deploy.yml` on `main` affects nobody until you move the tag.

1. Commit and push the change to this repo.
2. **Compatible change** (callers pass the same inputs): give it an exact version, then move `v1`:

   ```bash
   git tag v1.2.0 HEAD && git push origin v1.2.0
   ```

   ```bash
   git tag -f v1 v1.2.0 && git push --force origin v1
   ```

3. **Breaking change** (callers must change their `ci.yml`): tag `v2` instead and move each app over in its own PR.
4. Prove it: re-run any app's latest run and check the deploy job.

   ```bash
   gh run rerun $(gh run list -R <owner>/<repo> --branch <branch> --limit 1 --json databaseId --jq '.[0].databaseId') -R <owner>/<repo>
   ```

Exact tags (`v1.0.0`, `v1.1.0`, …) never move. To pin an app to one, change `@v1` to `@v1.1.0` in its `ci.yml`.

### 2.11 See what a deploy is doing right now

A deploy step sitting on `*` for minutes is usually `next build` on the droplet. Look at the droplet:

```bash
ssh <alias> "ps -eo etimes,pcpu,args --sort=-pcpu | grep -E 'next|npm|tsc' | grep -v grep | head -5"
```

### 2.12 Stop tracking build output (`dist/`, `.next/`)

If a repo commits build output, `git reset --hard` swaps the live build for the committed copy on every deploy. And the first deploy *after* untracking deletes the live files before the rebuild — a blank site.

1. **On the droplet first**, untrack without deleting:

   ```bash
   git -C /var/www/<app> rm -r -q --cached dist
   ```

2. In the repo: make sure `.gitignore` lists `dist`, then `git rm -r --cached dist`, commit, PR, merge.

---

## 3. Troubleshooting

Find the symptom, then read the cause and the fix.

**Deploy fails in seconds, exit code 255, log shows ssh's usage text**
Cause: a secret is missing — GitHub passes a missing secret as an empty string, not an error. (Since `v1.1.0` the **Check secrets** step catches this and names the missing one.)
Fix: run `setup-deploy.sh` for that repo, then `gh run rerun <run-id> --failed`.

**`Load key "…id_ed25519": error in libcrypto`**
Cause: `DEPLOY_SSH_KEY` holds a mangled key (usually a bad manual paste).
Fix: re-run `setup-deploy.sh`; it sets the secret with `gh`, no pasting.

**`Permission denied (publickey)` in the Deploy step, before any `boot.sh` output**
Cause: the CI key in the secret isn't in the droplet's `authorized_keys` (rotated, or removed by hand).
Fix: re-run `setup-deploy.sh`.

**`refusing: expected a full commit SHA`**
Cause: something sent the droplet a command instead of a bare 40-character SHA — usually an old hand-written deploy step. The lock is working.
Fix: the deploy job must call the shared `deploy.yml`, which sends only `$GITHUB_SHA`.

**`git@github.com: Permission denied (publickey)` inside the `boot.sh` output**
Cause: the droplet can't fetch — its deploy key is missing on GitHub, or the repo's `origin` doesn't use the `github-<repo>` alias.
Fix: re-run `setup-deploy.sh`. Check with `ssh <alias> "git -C /var/www/<app> remote get-url origin"` — it should start with `git@github-`.

**`Host key verification failed`**
Cause: the droplet's identity changed (rebuilt) or `DEPLOY_KNOWN_HOSTS` is wrong.
Fix: re-run `setup-deploy.sh`; it verifies the fingerprint against the droplet itself before saving.

**CI is red but everything passes on your Mac**
Cause: your Mac has something a fresh machine doesn't — a `.env`, a generated Prisma client, or a stale one.
Fix: reproduce with `env -i HOME=$HOME PATH=$PATH DOTENV_CONFIG_PATH=/dev/null npm test`, then add what's missing to `ci.yml` (dummy env, `prisma generate`, runner Postgres — see 2.5c).

**`node --test tests/` fails with "test failed" at `tests:1:1`**
Cause: since Node 22, `node --test` treats arguments as file patterns, not folders.
Fix: `"test": "node --test tests/*.test.js"`.

**Apps missing from `pm2 ls` after a Node upgrade**
Cause: `pm2 update` was run where systemd owns PM2.
Fix:

```bash
pm2 kill && sudo systemctl start pm2-sanna && sleep 3 && pm2 ls
```

**`pm2 ls` is empty after you log in, but the site works**
Cause: your shell started a second, empty PM2 daemon instead of talking to systemd's.
Fix: the same command as above.

**NodeSource setup fails at `apt update` ("does not have a Release file")**
Cause: a stale third-party apt source (e.g. an old MongoDB repo for a different Ubuntu release).
Fix: find it and delete it, then retry:

```bash
grep -rl "<the failing URL fragment>" /etc/apt/sources.list.d/
```

```bash
sudo rm /etc/apt/sources.list.d/<file>.list && sudo apt-get update
```

**`setup-deploy.sh` says "Not on <repo> yet" after you press Enter**
Cause: the deploy key wasn't saved on GitHub — usually Enter pressed before clicking **Add key**.
Fix: the key is still on your clipboard; add it, then press Enter again.

**`gh secret set … HTTP 503`**
Cause: GitHub's secrets service was briefly down; everything before the failing line succeeded.
Fix: check which secrets exist with `gh secret list -R <owner>/<repo>`. If only `DEPLOY_HOST` or `DEPLOY_USER` is missing, set it by hand (`gh secret set DEPLOY_USER -R <owner>/<repo> --body <user>`). If `DEPLOY_SSH_KEY` or `DEPLOY_KNOWN_HOSTS` is missing, re-run `setup-deploy.sh` — the CI private key is never saved anywhere you could copy it from.

**`gh` fails with `unexpected EOF` / `operation timed out`**
Cause: your network.
Fix: check GitHub's state before retrying (`gh pr view`, `gh run list`). Merges aren't repeatable; watches are.

**Two merges in quick succession**
Not a problem: deploys are queued one at a time per repo, and a newer pending deploy replaces an older pending one — the latest commit always wins.

---

## 4. Reference

**Secrets in each app repo**

- `DEPLOY_SSH_KEY` — private half of the CI key
- `DEPLOY_KNOWN_HOSTS` — `<ip> ssh-ed25519 AAAA…` line for the droplet
- `DEPLOY_HOST` — droplet IP
- `DEPLOY_USER` — the user PM2 runs as

**On each droplet**

- `~/bin/deploy.sh` — the forced command
- `~/.ssh/authorized_keys` — one `command="…deploy.sh /var/www/<app>"` line per app, ending in `gha-<repo>`
- `~/.ssh/github_<repo>` + a `Host github-<repo>` block in `~/.ssh/config` — the deploy key and its alias
- `/var/www/<app>/.env` — config, untracked, never touched by deploys
- `~/.pm2/dump.pm2` — what PM2 restores at boot (`pm2 save` writes it)

**Handy commands**

```bash
gh run list --limit 5
```

```bash
gh run view --log-failed
```

```bash
gh secret list -R <owner>/<repo>
```

```bash
gh repo deploy-key list -R <owner>/<repo>
```

```bash
ssh <alias> "pm2 ls && systemctl is-enabled pm2-sanna"
```

```bash
ssh <alias> "pm2 logs <pm2-name> --lines 50 --nostream"
```
