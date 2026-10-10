# Droplet Handbook

Everything about the servers themselves: SSH access from any device, building a new droplet from zero, hardening it, watching it, and what to do when something looks wrong.

How code *gets onto* a droplet (CI/CD, deploy keys, rollbacks) is in [RUNBOOK.md](RUNBOOK.md). This handbook stops where the runbook starts.

Placeholders used throughout:

- `<alias>` — the droplet's name in your `~/.ssh/config` (e.g. `shop-droplet`)
- `<droplet-ip>` — its public IP from DigitalOcean
- `<user>` — the non-root user apps run as (one per droplet, same name everywhere is easiest)
- `<key>` — an SSH key file name, e.g. `id_do_laptop`
- `<domain>` — the site's domain, e.g. `example.com`

Last updated: 2026-10-10.

---

## Contents

1. [SSH access: keys and config](#1-ssh-access-keys-and-config)
2. [Accessing droplets from a new device](#2-accessing-droplets-from-a-new-device)
3. [New droplet from zero](#3-new-droplet-from-zero)
4. [Monitoring: daily, weekly, monthly](#4-monitoring-daily-weekly-monthly)
5. [Updating applications](#5-updating-applications)
6. [Troubleshooting](#6-troubleshooting)
7. [If a droplet is compromised](#7-if-a-droplet-is-compromised)
8. [Security checklist](#8-security-checklist)
9. [Quick reference](#9-quick-reference)

---

## 1. SSH access: keys and config

### 1.1 How SSH keys work, in one paragraph

A key has two halves. The **public** half (`<key>.pub`) goes on servers and on DigitalOcean — sharing it is safe. The **private** half (`<key>`) never leaves your device; whoever holds it *is* you. A **passphrase** encrypts the private half, so a stolen laptop alone isn't enough to get in.

### 1.2 Create a key

```bash
ssh-keygen -t ed25519 -f ~/.ssh/<key> -C "<your-email>"
```

**Set a passphrase when asked.** Then load it into your Mac's keychain so you type it once, not on every connection:

```bash
ssh-add --apple-use-keychain ~/.ssh/<key>
```

Show the public half (this is what you paste into DigitalOcean):

```bash
cat ~/.ssh/<key>.pub
```

### 1.3 Add it to DigitalOcean

1. DigitalOcean → **Settings → Security → SSH Keys → Add SSH Key**
2. Paste the public key, name it after the device ("MacBook Pro 2026").
3. Save. Droplets created from now on can have it installed at creation.

**Several DigitalOcean accounts?** You don't need a separate key per account: the same public key can be added to every account. Separate keys per account work too (that's what you have today) — just keep the config below tidy.

### 1.4 The SSH config: one alias per droplet

```bash
nano ~/.ssh/config
```

```
Host <alias>
    HostName <droplet-ip>
    User <user>
    IdentityFile ~/.ssh/<key>
    IdentitiesOnly yes
    AddKeysToAgent yes
    UseKeychain yes
```

- `IdentitiesOnly yes` — offer only this key, not every key you own (fewer "Too many authentication failures").
- `AddKeysToAgent` + `UseKeychain` — macOS only: unlock once, remembered via Keychain. Delete both lines on Windows/Linux.
- **No `ForwardAgent yes`.** Forwarding lets anyone with root on that droplet use your GitHub key while you're connected. Deploys don't need it — each droplet has its own read-only deploy key (see the runbook). Use `ssh -A <alias>` for the rare one-off that does (section 3.6).

Connect:

```bash
ssh <alias>
```

---

## 2. Accessing droplets from a new device

**Best practice: one key per device.** If a laptop is lost, you remove *its* key and every other device keeps working. Copying one private key onto every device means a single loss forces you to re-key everything.

### 2.1 New device, new key (recommended)

1. On the new device, create a key (section 1.2). Windows: use **PowerShell** (OpenSSH is built into Windows 10/11) or Git Bash.
2. Add the public key to DigitalOcean (section 1.3) — that covers droplets you *create* later.
3. Add it to every **existing** droplet. DigitalOcean doesn't push new keys to existing droplets, so do it from a device that already has access:

   ```bash
   ssh <alias> "echo '<paste the new .pub line>' >> ~/.ssh/authorized_keys"
   ```

4. Copy your `~/.ssh/config` to the new device and change each `IdentityFile` to the new key.
5. Test every alias:

   ```bash
   ssh <alias> "whoami"
   ```

### 2.2 Retiring a device

On each droplet, delete the line ending with that device's key comment:

```bash
ssh <alias> "grep -v '<old-key-comment>' ~/.ssh/authorized_keys > /tmp/ak && cat /tmp/ak > ~/.ssh/authorized_keys && rm /tmp/ak"
```

Keep a second terminal connected while you do this, so a mistake can't lock you out. Remove it from DigitalOcean's SSH Keys page too.

### 2.3 Moving existing keys instead (Mac → Mac)

Only if you can't add new keys right now. Copy `~/.ssh` over (AirDrop or an encrypted USB — never cloud storage or chat), then fix permissions, which SSH enforces:

```bash
chmod 700 ~/.ssh && chmod 600 ~/.ssh/* && chmod 644 ~/.ssh/*.pub
```

```bash
ssh-add --apple-use-keychain ~/.ssh/<key>
```

---

## 3. New droplet from zero

Order matters: hardening happens before any app code exists on the box.

### 3.1 Create the droplet

In DigitalOcean: **Create → Droplets**

1. Image: **Ubuntu 24.04 LTS**
2. Plan: Basic, **2 GB RAM / 2 vCPU** minimum — `next build`, Redis and Puppeteer don't fit in 1 GB.
3. Region: London (closest to The Gambia)
4. Authentication: **SSH key** — tick your device's key. Never "Password".
5. Enable **Monitoring** (free, graphs + alerts) and consider **Backups**.
6. Create, then note the IP.

Add an alias for it (section 1.4), but with `User root` for now — you'll switch to `<user>` in 3.3.

### 3.2 First login and updates (as root, once)

```bash
ssh <alias>
```

```bash
apt update && apt upgrade -y
```

If asked about `sshd_config`, choose **"keep the local version currently installed"**.

```bash
apt install -y curl git build-essential ufw fail2ban unattended-upgrades
```

**Why:** `unattended-upgrades` installs security patches automatically; the rest are needed below.

### 3.3 Create your user (as root, once)

```bash
adduser <user>
```

Set a strong password (you'll need it for `sudo`), press Enter through the optional fields.

```bash
usermod -aG sudo <user> && rsync --archive --chown=<user>:<user> ~/.ssh /home/<user>
```

**Why:** gives `<user>` admin rights via `sudo`, and copies root's authorized keys so you can log in as `<user>` with the same key.

Now change `User root` to `User <user>` in your Mac's `~/.ssh/config`, open a **new** terminal and check:

```bash
ssh <alias> "whoami && sudo -v && echo sudo-ok"
```

✅ Expected: `<user>`, then your password prompt, then `sudo-ok`. **From here on, never work as root.**

### 3.4 Harden the box

**Firewall** — allow only SSH and web traffic in:

```bash
sudo ufw default deny incoming && sudo ufw default allow outgoing && sudo ufw allow OpenSSH && sudo ufw allow 80,443/tcp
```

```bash
sudo ufw enable && sudo ufw status verbose
```

✅ Expected: `22`, `80`, `443` allowed; nothing else. App ports (3000, 5000) and Redis (6379) stay closed to the internet — nginx reaches the apps from inside.

**SSH** — keys only, no root.

Keep your current session open, and open a second one as a lifeline. Then:

```bash
sudoedit /etc/ssh/sshd_config
```

Set these three lines (search with Ctrl+W):

```
PermitRootLogin no
PasswordAuthentication no
PubkeyAuthentication yes
```

DigitalOcean images also ship files in `/etc/ssh/sshd_config.d/` that can **override** what you just set. Check:

```bash
grep -rn "PasswordAuthentication\|PermitRootLogin" /etc/ssh/sshd_config.d/
```

If any says `yes`, change it to `no` there too. Then apply and prove it:

```bash
sudo systemctl restart ssh && sudo sshd -T | grep -E "^(permitrootlogin|passwordauthentication|pubkeyauthentication) "
```

✅ Expected: `permitrootlogin no`, `passwordauthentication no`, `pubkeyauthentication yes`. Open a **new** terminal and `ssh <alias>` before closing the old ones.

**Fail2ban** — bans IPs that keep failing SSH logins. Ubuntu enables the SSH jail by default:

```bash
sudo systemctl enable --now fail2ban && sudo fail2ban-client status sshd
```

✅ Expected: `Status for the jail: sshd`.

**Swap** — a safety net so `next build` doesn't get killed for memory:

```bash
sudo fallocate -l 2G /swapfile && sudo chmod 600 /swapfile && sudo mkswap /swapfile && sudo swapon /swapfile
```

```bash
echo '/swapfile none swap sw 0 0' | sudo tee -a /etc/fstab && free -h
```

✅ Expected: `Swap: 2.0Gi`.

### 3.5 Install the stack

**Node.js 24 LTS** (Node 20 reached end of life in April 2026):

```bash
curl -fsSL https://deb.nodesource.com/setup_24.x | sudo -E bash - && sudo apt install -y nodejs && node -v
```

**PM2**, plus the systemd service that brings your apps back after a reboot:

```bash
sudo npm install -g pm2
```

```bash
sudo env PATH=$PATH:/usr/bin pm2 startup systemd -u <user> --hp /home/<user>
```

From now on this droplet follows one rule: **restart PM2 with `sudo systemctl restart pm2-<user>`, never `pm2 update`** — `pm2 update` fights systemd and can take every app down (runbook, troubleshooting).

**nginx:**

```bash
sudo apt install -y nginx && sudo systemctl enable --now nginx
```

**Redis** (only if an app uses queues — BullMQ etc.):

```bash
sudo apt install -y redis-server
```

```bash
sudoedit /etc/redis/redis.conf
```

Set or add:

```
supervised systemd
appendonly yes
appendfsync everysec
maxmemory 200mb
maxmemory-policy noeviction
```

**Why:** `appendonly` keeps queued jobs across restarts; `noeviction` makes Redis refuse writes when full rather than silently dropping jobs.

```bash
sudo systemctl restart redis-server && sudo systemctl enable redis-server && redis-cli ping && sudo ss -ltnp | grep 6379
```

✅ Expected: `PONG`, and 6379 bound to `127.0.0.1` / `[::1]` only — never `0.0.0.0`.

**Puppeteer libraries** (only if an app renders PDFs/screenshots with Puppeteer):

```bash
sudo apt install -y libatk-bridge2.0-0 libatk1.0-0 libcups2 libdbus-1-3 libdrm2 libgbm1 libgtk-3-0 libnspr4 libnss3 libxcomposite1 libxdamage1 libxfixes3 libxkbcommon0 libxrandr2 xdg-utils fonts-liberation libasound2
```

On 24.04 apt prints *"Note, selecting '…t64' instead of …"* for several of these — that's normal (renamed packages).

### 3.6 Get the apps onto the box

```bash
sudo mkdir -p /var/www && sudo chown <user>:<user> /var/www
```

The droplet has no GitHub access of its own yet, so make the **first clone** with your agent forwarded, just this once:

```bash
ssh -A <alias>
```

```bash
cd /var/www && git clone git@github.com:<owner>/<backend-repo>.git backend && git clone git@github.com:<owner>/<frontend-repo>.git frontend
```

```bash
exit
```

`setup-deploy.sh` (step 3.10) later gives the droplet its own read-only key and repoints both repos at it. Never use `npm install` with `sudo`.

### 3.7 Environment files

```bash
nano /var/www/backend/.env
```

Copy every variable from the repo's `.env.example`. Typical production values:

```
NODE_ENV=production
PORT=5000
DATABASE_URL=<connection string>
REDIS_URL=redis://127.0.0.1:6379
```

Generate each secret (JWT, API-key hashing, encryption keys) separately:

```bash
openssl rand -hex 32
```

Frontend build-time variables:

```bash
nano /var/www/frontend/.env.production
```

```
NEXT_PUBLIC_API_BASE_URL=https://api.<domain>
```

Anything starting `NEXT_PUBLIC_` or `VITE_` is shipped to every visitor's browser — never put a secret in one.

### 3.8 First start

Each repo's `boot.sh` installs, builds, migrates and starts the app under PM2 — the same script CI runs later:

```bash
ssh <alias> "/var/www/backend/boot.sh && /var/www/frontend/boot.sh && pm2 save && pm2 ls"
```

✅ Expected: both apps `online` with `↺` 0. `pm2 save` records them so the boot service restores them after a reboot.

If an app crashes, read why:

```bash
ssh <alias> "pm2 logs backend --lines 50 --nostream"
```

### 3.9 nginx, DNS and HTTPS

**API site:**

```bash
sudo tee /etc/nginx/sites-available/backend >/dev/null <<'EOF'
server {
    listen 80;
    server_name api.<domain>;
    client_max_body_size 10m;

    location / {
        proxy_pass http://127.0.0.1:5000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF
```

**Frontend site:**

```bash
sudo tee /etc/nginx/sites-available/frontend >/dev/null <<'EOF'
server {
    listen 80 default_server;
    server_name <domain> www.<domain>;

    location / {
        proxy_pass http://127.0.0.1:3000;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection 'upgrade';
        proxy_set_header Host $host;
        proxy_set_header X-Real-IP $remote_addr;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto $scheme;
        proxy_cache_bypass $http_upgrade;
    }
}
EOF
```

For a static SPA (Vite) served from files instead of a Node process, replace the `location /` block with `root /var/www/frontend/dist;` and `location / { try_files $uri /index.html; }`.

Enable both, drop the default site, test, reload:

```bash
sudo ln -sf /etc/nginx/sites-available/backend /etc/nginx/sites-enabled/ && sudo ln -sf /etc/nginx/sites-available/frontend /etc/nginx/sites-enabled/ && sudo rm -f /etc/nginx/sites-enabled/default
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

**DNS** — at your registrar or Cloudflare, add A records:

```
<domain>        → <droplet-ip>
www.<domain>    → <droplet-ip>
api.<domain>    → <droplet-ip>
```

Check from your Mac until all three answer with the droplet's IP (5–30 minutes; https://dnschecker.org shows global propagation):

```bash
dig +short <domain> www.<domain> api.<domain>
```

**HTTPS** — only after DNS resolves, or certbot fails:

```bash
sudo apt install -y certbot python3-certbot-nginx && sudo certbot --nginx -d <domain> -d www.<domain> -d api.<domain>
```

Certbot edits the nginx configs, adds the HTTP→HTTPS redirect, and installs auto-renewal. Prove renewal will work:

```bash
sudo certbot renew --dry-run
```

### 3.10 Wire up CI/CD

Follow **RUNBOOK.md, section 2.5** for each app. The setup script gives the droplet its own deploy keys and replaces the agent-forwarded clone from 3.6.

### 3.11 Daily security snapshot

A root cron job that writes a short report every morning. It runs as root because reading auth logs and process owners needs `sudo`, which a cron job can't type a password for.

```bash
sudo tee /usr/local/sbin/security-check >/dev/null <<'EOF'
#!/usr/bin/env bash
# Daily snapshot: SSH attacks, open ports, heavy processes, disk, pending reboots
{
  echo "=== Security check $(date -Is) ==="
  echo "SSH auth failures, last 24h: $(journalctl -u ssh --since "24 hours ago" --no-pager | grep -cE 'Invalid user|Failed|authentication failure')"
  fail2ban-client status sshd | grep -E "Currently banned|Total banned"
  echo "--- Listening ports ---"; ss -tulpn
  echo "--- Top CPU processes ---"; ps aux --sort=-%cpu | head -8
  echo "--- Established connections ---"; ss -tunp state established
  echo "--- Disk / memory ---"; df -h / | tail -1; free -h | sed -n 2,3p
  echo "Reboot required: $([ -f /var/run/reboot-required ] && echo YES || echo no)"
  echo
} >> /var/log/security-check.log 2>&1
EOF
```

```bash
sudo chmod 755 /usr/local/sbin/security-check && echo "0 6 * * * root /usr/local/sbin/security-check" | sudo tee /etc/cron.d/security-check
```

Keep the log from growing forever:

```bash
printf '/var/log/security-check.log {\n  weekly\n  rotate 8\n  compress\n  missingok\n  notifempty\n}\n' | sudo tee /etc/logrotate.d/security-check
```

Run it once to check it works:

```bash
sudo /usr/local/sbin/security-check && sudo tail -30 /var/log/security-check.log
```

### 3.12 Verify the whole droplet

```bash
ssh -t <alias> "pm2 ls && systemctl is-enabled pm2-<user> && systemctl is-active nginx fail2ban && sudo ufw status | head -8 && free -h && df -h /"
```

```bash
curl -sI https://<domain> | head -1 && curl -sI https://api.<domain> | head -1
```

✅ Apps online with `↺` 0, service `enabled`, nginx and fail2ban `active`, only 22/80/443 open, swap present, both URLs answer (a 404 from the API root is fine if it has no `/` route).

---

## 4. Monitoring: daily, weekly, monthly

### Daily (2 minutes, from your Mac)

All droplets at once — health, memory, disk and PM2 in one pass:

```bash
for h in <alias1> <alias2> <alias3>; do echo "===== $h"; ssh $h 'uptime; free -h | sed -n 2p; df -h / | tail -1; pm2 ls'; done
```

The morning security report for one droplet:

```bash
ssh -t <alias> "sudo tail -40 /var/log/security-check.log"
```

**Healthy:**

- `↺` (restarts) not climbing since yesterday
- Load average below the CPU count (2 on a 2 vCPU droplet)
- Disk under 80%, swap mostly unused
- Listening ports: only 22, 80, 443 publicly; 3000/5000/6379 on `127.0.0.1` or ufw-blocked
- Processes owned by `<user>`, `root` system services, `redis`, `www-data`
- A steady trickle of SSH failures with fail2ban banning them — that's normal internet noise

**Investigate immediately:**

- A process you don't recognise, especially with a random name, or `xmrig` / miners
- CPU above 50% with no traffic
- A listening port you didn't open, or a public `0.0.0.0` listener that isn't nginx or SSH
- Node or npm processes running as `root`
- Many established connections to one foreign IP, or to ports like 4444, 6667, 31337
- New files in `/tmp` or `/dev/shm` you didn't create
- `↺` climbing fast — a crash loop

### Weekly

```bash
ssh -t <alias> "sudo fail2ban-client status sshd; sudo certbot certificates 2>/dev/null | grep -E 'Domains|Expiry'"
```

Check GitHub's Dependabot alerts for each repo; fix **critical/high** through a PR.

### Monthly

Patch and reboot at a quiet time — unattended-upgrades applies security fixes, but kernel updates need a reboot to take effect:

```bash
ssh -t <alias> "sudo apt update && sudo apt upgrade -y && cat /var/run/reboot-required 2>/dev/null"
```

If it prints `*** System restart required ***`:

```bash
ssh -t <alias> "sudo reboot"
```

Wait a minute, then confirm everything came back on its own:

```bash
ssh <alias> "uptime && pm2 ls"
```

`do-release-upgrade` (e.g. to Ubuntu 26.04) is **not** monthly maintenance — plan it like a migration, ideally by building a fresh droplet.

---

## 5. Updating applications

**Normal path: merge a PR.** CI tests it, then deploys it — RUNBOOK.md section 1.

**By hand** (CI down, or emergency) — the same script CI runs:

```bash
ssh <alias> "/var/www/<app>/boot.sh"
```

Rules for the server:

- **Never `git pull`, edit code, or `npm audit fix` on the droplet.** Every deploy resets the folder to the exact commit CI tested, wiping local changes — and a fix that only exists on the server never went through CI. Dependency fixes go in a PR, where CI proves nothing broke.
- **Use `npm ci`, never `npm install`, on servers.** `npm ci` installs exactly what `package-lock.json` says; `npm install` may quietly pick newer versions. `boot.sh` already does this.
- **Keep Next.js on its latest patch release.** Versions 15.x and 16.0.x had a remote-code-execution hole that compromised droplets before — Dependabot will flag the next one.

---

## 6. Troubleshooting

**App missing from `pm2 ls` / `pm2 ls` empty after login**
Cause: a second, empty PM2 daemon — usually after `pm2 update` on a droplet where systemd owns PM2.
Fix:

```bash
pm2 kill && sudo systemctl start pm2-<user> && sleep 3 && pm2 ls
```

**App keeps restarting (`↺` climbing)**
Cause: it crashes on start — missing env var, bad config, DB unreachable.
Fix: read the reason, fix it, then `pm2 reload <name>`.

```bash
pm2 logs <name> --lines 80 --nostream
```

**App won't start at all**
Fix: start it fresh from its folder and save:

```bash
pm2 delete <name>; cd /var/www/<app> && pm2 start npm --name <name> -- start && pm2 save
```

**"Port already in use" (EADDRINUSE)**
Cause: usually a duplicate copy of the same app.
Fix: see who owns the port before killing anything:

```bash
sudo ss -ltnp 'sport = :5000'
```

If it's a stray `node` you recognise, `pm2 delete` the duplicate. Never `fuser -k` Redis's port — that kills the queue.

**502 Bad Gateway**
Cause: nginx is up but the app behind it isn't (crashed, wrong port, still starting).
Fix: `pm2 ls`, then the logs above; check `proxy_pass` port matches the app's `PORT`.

**nginx won't reload**
Fix: test the config, read the error:

```bash
sudo nginx -t && sudo tail -30 /var/log/nginx/error.log
```

**403 Forbidden on a static (Vite) frontend**
Cause: `dist/` missing (a failed build) or unreadable by nginx.
Fix: rebuild with `boot.sh`; if it exists but 403s, fix permissions:

```bash
sudo chmod -R o+rX /var/www/<app>/dist && ls -ld /var/www /var/www/<app>
```

**Build killed / "JavaScript heap out of memory"**
Cause: not enough RAM for `next build` / `vite build`.
Fix: confirm swap is on (`free -h`; `sudo swapon /swapfile` if not). Still failing → resize to 4 GB, or build in CI and ship the output (bigger change, plan it).

**Redis down**
Fix:

```bash
sudo systemctl status redis-server --no-pager && sudo tail -30 /var/log/redis/redis-server.log
```

```bash
sudo systemctl restart redis-server && redis-cli ping
```

**`apt update` fails ("does not have a Release file")**
Cause: a stale third-party source (old MongoDB/Node repo for a different Ubuntu release).
Fix:

```bash
grep -rl "<the failing URL fragment>" /etc/apt/sources.list.d/
```

```bash
sudo rm /etc/apt/sources.list.d/<file> && sudo apt update
```

**SSH: `Permission denied (publickey)` from your Mac**
Cause: the alias points at the wrong key, or the key isn't loaded.
Fix: `ssh-add -l` to see loaded keys; `ssh -v <alias>` shows which key was offered.

**SSH: `Too many authentication failures`**
Fix: add `IdentitiesOnly yes` to that `Host` block.

**Certificate expired / renewal failing**
Fix:

```bash
sudo certbot renew --dry-run && systemctl list-timers | grep certbot
```

Usually DNS moved or port 80 got blocked — certbot needs it for the challenge.

**Disk full**
Fix: find what grew:

```bash
sudo du -xh / --max-depth=2 2>/dev/null | sort -h | tail -15
```

Common culprits: `~/.pm2/logs` (`pm2 flush`), `/var/log/journal` (`sudo journalctl --vacuum-size=200M`), old `node_modules` copies.

---

## 7. If a droplet is compromised

Signs: a miner, an unknown root process, a strange outbound flood, files you didn't create — or a DigitalOcean abuse email.

**Rebuild, don't repair.** You can't prove a cleaned box is clean.

1. **Contain:** DigitalOcean → Networking → Firewalls → attach a firewall allowing only SSH from your IP. Don't delete the droplet yet.
2. **Snapshot it** (Droplet → Snapshots) for evidence.
3. **Rotate every secret that was on it:** database passwords, JWT and encryption keys, API keys (Resend, Twilio, R2, payment providers), and its deploy keys and CI key (RUNBOOK 2.9). Assume `.env` was read.
4. **Build a new droplet** from section 3, deploy from git — never copy files from the old one.
5. **Point DNS** at the new IP, then destroy the old droplet.
6. **Find the way in** before you relax: outdated Next.js or dependency, leaked key, password SSH left on.
7. Reply to any DigitalOcean abuse report with what you found and did.

---

## 8. Security checklist

Before calling a droplet done:

- [ ] Ubuntu 24.04, fully patched, `unattended-upgrades` installed
- [ ] Apps run as `<user>`; nothing deployed or `npm`-installed as root
- [ ] `sshd -T` shows root login and password auth both **off**
- [ ] ufw: only 22, 80, 443 open
- [ ] fail2ban active with the `sshd` jail
- [ ] Redis bound to localhost only (if installed)
- [ ] 2 GB swap active
- [ ] Node 24 LTS; PM2 boot service `pm2-<user>` enabled; `pm2 save` done
- [ ] HTTPS on every domain; `certbot renew --dry-run` passes
- [ ] No secrets in `NEXT_PUBLIC_*` / `VITE_*` variables
- [ ] No critical/high Dependabot alerts; Next.js on its latest patch
- [ ] Security snapshot cron installed and producing a report
- [ ] CI/CD wired (RUNBOOK 2.5); the droplet has its own deploy keys, no agent forwarding needed
- [ ] DigitalOcean Monitoring on; backups or a snapshot taken
- [ ] Added to your private inventory

---

## 9. Quick reference

```bash
ssh <alias>
```

**Apps**

```bash
pm2 ls
```

```bash
pm2 logs <name> --lines 50 --nostream
```

```bash
pm2 reload <name>
```

```bash
sudo systemctl restart pm2-<user>
```

**Resources**

```bash
free -h && df -h / && uptime
```

**Services**

```bash
systemctl is-active nginx redis-server fail2ban pm2-<user>
```

```bash
sudo nginx -t && sudo systemctl reload nginx
```

**Security**

```bash
sudo tail -40 /var/log/security-check.log
```

```bash
sudo fail2ban-client status sshd
```

```bash
sudo ss -tulpn
```

**Deploy by hand**

```bash
/var/www/<app>/boot.sh
```

---

**Support:** DigitalOcean docs https://docs.digitalocean.com · support@digitalocean.com · abuse reports: abuse-replies@digitalocean.com
