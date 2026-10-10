# workflows

Reusable GitHub Actions workflows. No secrets or hostnames live here; callers pass their own.

**New here or doing something by hand? Start with [RUNBOOK.md](RUNBOOK.md)** (deploys) and **[DROPLET_HANDBOOK.md](DROPLET_HANDBOOK.md)** (the servers themselves).

## deploy.yml

SSHes to a droplet with a key locked by a forced command to `boot.sh <sha>`, sending only the commit SHA.

```yaml
  deploy:
    needs: test
    if: github.event_name == 'push' && github.ref_name == github.event.repository.default_branch
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

Callers pin to the major tag `v1`. Each release also gets an exact tag (`v1.0.0`, `v1.1.0`) that never moves.
A compatible change moves `v1` forward to the new exact tag, so every caller picks it up; a breaking change starts `v2`.
