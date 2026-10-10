#!/usr/bin/env bash
# One-time CI deploy setup for one app on one droplet. Run from your Mac.
#
#   scripts/setup-deploy.sh <ssh-alias> <app-dir> <owner/repo>
#   scripts/setup-deploy.sh shop-droplet backend acme/shop-backend
#
# Droplet: a read-only GitHub deploy key under its own SSH alias, ~/bin/deploy.sh,
# and a CI key locked to `deploy.sh /var/www/<app-dir>`. GitHub: the four secrets
# deploy.yml expects. Safe to re-run: it rotates the CI key and reuses the rest.
set -euo pipefail

[ $# -eq 3 ] || { sed -n '4,5p' "$0" >&2; exit 1; }
ssh_alias="$1" app="$2" repo="$3"
[[ "$app" =~ ^[A-Za-z0-9._-]+$ ]] || { echo "bad app dir: $app" >&2; exit 1; }
[[ "$repo" =~ ^[A-Za-z0-9._-]+/[A-Za-z0-9._-]+$ ]] || { echo "bad repo: $repo" >&2; exit 1; }
slug=$(tr '[:upper:]' '[:lower:]' <<<"${repo#*/}")

host=$(ssh -G "$ssh_alias" | awk '$1 == "hostname" { print $2 }')
user=$(ssh -G "$ssh_alias" | awk '$1 == "user" { print $2 }')
remote() { ssh -o ForwardAgent=no -o BatchMode=yes "$ssh_alias" "$@"; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT

echo "==> Checking $ssh_alias ($user@$host) host key"
ssh-keyscan -t ed25519 "$host" 2>/dev/null > "$tmp/known_hosts"
seen=$(ssh-keygen -lf "$tmp/known_hosts" | awk '{ print $2 }')
actual=$(remote 'ssh-keygen -lf /etc/ssh/ssh_host_ed25519_key.pub' | awk '{ print $2 }')
[ -n "$seen" ] && [ "$seen" = "$actual" ] || { echo "host key mismatch: scanned $seen, droplet says $actual" >&2; exit 1; }

echo "==> Configuring the droplet"
remote bash -s -- "$app" "$repo" "$slug" > "$tmp/out" <<'REMOTE'
set -euo pipefail
app_dir="/var/www/$1" repo="$2" slug="$3"
gh_key="$HOME/.ssh/github_$slug" ci_tag="gha-$slug"
[ -d "$app_dir/.git" ] || { echo "no git repo at $app_dir" >&2; exit 1; }

# Droplet → GitHub: its own read-only key, so fetches never borrow a forwarded agent
[ -f "$gh_key" ] || ssh-keygen -q -t ed25519 -C "droplet-$slug" -f "$gh_key" -N ""
if ! grep -qx "Host github-$slug" ~/.ssh/config 2>/dev/null; then
  printf '\nHost github-%s\n    HostName github.com\n    User git\n    IdentityFile %s\n    IdentitiesOnly yes\n' \
    "$slug" "$gh_key" >> ~/.ssh/config
fi
chmod 600 ~/.ssh/config
ssh-keygen -F github.com >/dev/null || ssh-keyscan -t ed25519 github.com >> ~/.ssh/known_hosts 2>/dev/null
git -C "$app_dir" remote set-url origin "git@github-$slug:$repo.git"

mkdir -p ~/bin
cat > ~/bin/deploy.sh <<'EOS'
#!/usr/bin/env bash
# Forced command for CI keys: deploys one app dir, given only a commit SHA
set -euo pipefail
app_dir="$1"
sha="${SSH_ORIGINAL_COMMAND:-}"
[[ "$sha" =~ ^[0-9a-f]{40}$ ]] || { echo "refusing: expected a full commit SHA" >&2; exit 1; }
# Check out first so the boot.sh that runs is the one from this commit
git -C "$app_dir" fetch --quiet origin
git -C "$app_dir" reset --quiet --hard "$sha"
exec bash "$app_dir/boot.sh" "$sha"
EOS
chmod +x ~/bin/deploy.sh

# GitHub Actions → droplet: a fresh key that can only run deploy.sh for this app
ci_dir=$(mktemp -d)
ssh-keygen -q -t ed25519 -C "$ci_tag" -f "$ci_dir/key" -N ""
touch ~/.ssh/authorized_keys
grep -v " $ci_tag\$" ~/.ssh/authorized_keys > "$ci_dir/authorized_keys" || true
echo "command=\"$HOME/bin/deploy.sh $app_dir\",no-port-forwarding,no-X11-forwarding,no-agent-forwarding,no-pty $(cat "$ci_dir/key.pub")" \
  >> "$ci_dir/authorized_keys"
cat "$ci_dir/authorized_keys" > ~/.ssh/authorized_keys

echo "GH_PUB $(cat "$gh_key.pub")"
echo "CI_KEY_BEGIN"
cat "$ci_dir/key"
echo "CI_KEY_END"
rm -rf "$ci_dir"
REMOTE

sed -n 's/^GH_PUB //p' "$tmp/out" > "$tmp/github.pub"
sed -n '/^CI_KEY_BEGIN$/,/^CI_KEY_END$/p' "$tmp/out" | sed '1d;$d' > "$tmp/ci_key"
chmod 600 "$tmp/ci_key"
rm "$tmp/out"

echo "==> Checking the CI key is locked to deploy.sh"
refusal=$(ssh -o IdentitiesOnly=yes -o BatchMode=yes -o UserKnownHostsFile="$tmp/known_hosts" \
  -i "$tmp/ci_key" "$user@$host" "ls" 2>&1 || true)
[[ "$refusal" == *"refusing: expected a full commit SHA"* ]] || { echo "CI key is NOT locked down: $refusal" >&2; exit 1; }

# Added by hand, not `gh repo deploy-key add`: GitHub deletes keys an OAuth app
# created when that app's authorization is revoked, which would break every deploy.
gh_pub_body=$(cut -d' ' -f2 "$tmp/github.pub")
has_deploy_key() { gh repo deploy-key list -R "$repo" --json key --jq '.[].key' | grep -qF "$gh_pub_body"; }
if has_deploy_key; then
  echo "==> Deploy key already on $repo"
else
  pbcopy < "$tmp/github.pub"
  open "https://github.com/$repo/settings/keys/new"
  echo "==> Deploy key copied. In the browser: Title 'droplet', paste, leave write access OFF, Add key."
  until read -r -p "    Press Enter once it's added... " && has_deploy_key; do
    echo "    Not on $repo yet. Clipboard still holds it: $(cat "$tmp/github.pub")"
  done
fi

echo "==> Checking the droplet can fetch $repo with its own key"
remote "git -C /var/www/$app fetch --quiet origin" || { echo "droplet fetch failed: is the deploy key added?" >&2; exit 1; }

echo "==> Setting secrets on $repo"
gh secret set DEPLOY_SSH_KEY -R "$repo" < "$tmp/ci_key"
gh secret set DEPLOY_KNOWN_HOSTS -R "$repo" < "$tmp/known_hosts"
gh secret set DEPLOY_HOST -R "$repo" --body "$host"
gh secret set DEPLOY_USER -R "$repo" --body "$user"

echo "==> Done: merges to $repo's default branch now deploy /var/www/$app on $ssh_alias"
