# workflows

Reusable GitHub Actions workflows. No secrets or hostnames live here; callers pass their own.

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

Pin callers to a tag. A breaking change gets a new major tag (`v2`), never a moved `v1`.
