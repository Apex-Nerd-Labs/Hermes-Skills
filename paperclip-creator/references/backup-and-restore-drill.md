# Backing Up Paperclip — and Proving the Backup Works

A backup you have never restored is a hypothesis. This reference covers what to capture, how to
run a restore drill, and the failure that integrity checks cannot catch.

Placeholders: `<ctid>` guest id, `<pve-host>` Proxmox host, `<lan-ip>` guest address,
`<drill-ctid>` a spare unused guest id.

---

## 1. What actually needs to survive

Paperclip keeps everything that matters in two places:

| Path | Contents |
|---|---|
| `/opt/paperclip-deploy/` | `docker-compose.yml` + `.env` (auth secrets, provider keys) |
| `/opt/paperclip-data/` | embedded Postgres cluster, workspaces, encryption key, **hourly SQL dumps** |

The **in-app hourly dumps** (`/opt/paperclip-data/instances/default/data/backups/paperclip-*.sql.gz`)
are a second, independent layer: they are plain SQL and can be inspected without starting the
service. Use them as your content oracle in §4.

A guest-level backup (Proxmox `vzdump`) covers both, and is the only layer that also restores the
image, Docker, and the OS.

---

## 2. The failure that integrity checks miss

> **`gzip -t` / `zstd -t` passing proves the bytes decompress. It proves nothing about whether the
> archive contains your data.**

Real case: a scheduled guest backup taken in the early morning was verified with `zstd -t`
(clean, 16 GiB), restored successfully, and booted the application — which answered
`/api/health` with `{"status":"ok"}`. It contained **none of the organisation's data**, because the
organisation had been created *after* the backup ran. Every mechanical check passed. The backup was
useless for the thing it existed to protect.

So: **verify backups by content, and by asking the application what it thinks it has.**

---

## 3. The fastest content tell: `bootstrapStatus`

`GET /api/health` returns a field that distinguishes an empty schema from a populated one:

```json
"bootstrapStatus": "bootstrap_pending"   // empty/never-claimed database
"bootstrapStatus": "ready"               // database has an organisation
```

If the live instance says `ready` and a restored copy says `bootstrap_pending`, the backup predates
the organisation. This is a one-line check, and it is the single most valuable sanity test to run
before trusting a restore point.

---

## 4. Proving a backup contains real data

The image ships no `psql` on `PATH`, so inspect the data rather than querying it:

```bash
# (a) content oracle — bisect the in-app dumps for a known string, e.g. the org name
for f in $(ls -1t /opt/paperclip-data/instances/default/data/backups/*.sql.gz); do
  n=$(zcat "$f" | grep -ac "<organisation-name>")
  echo "$(basename $f)  $(stat -c %s $f)B  hits=$n"
done
```

A dump that suddenly grows and starts matching is the moment the data appeared. Sample bisect
output: the organisation was created mid-morning, so every dump up to the hour before it was a
constant small size with `hits=0`, and the next dump jumped in size with `hits=1`:

```
paperclip-<stamp>.sql.gz   ~205 KB  hits=1     <- organisation present
paperclip-<stamp>.sql.gz    ~56 KB  hits=0     <- empty schema only
```

The size jump is the signal worth watching: a schema-only database dumps to a constant size, so an
unchanged size across hours means nothing has been created yet.

```bash
# (b) raw heap scan — works on a mounted or extracted DB directory with no server running
grep -rac "<organisation-name>" /opt/paperclip-data/instances/default/db/base | grep -v ':0$' | wc -l
```

Always scan the **live** database first as a positive control. If the live DB does not match either,
your search string is wrong and a zero-hit result on the backup means nothing.

Also confirm the dump is structurally sane:

```bash
zcat <dump>.sql.gz | grep -c '^CREATE TABLE'      # expect a large, stable number (e.g. 211)
```

---

## 5. Running a restore drill without breaking production

**Never** boot a restored copy of a live guest unchanged: it carries the same MAC (and often a
DHCP reservation) as the running guest, plus the same Tailscale node identity. A duplicate node key
can disturb the live node.

```bash
# 1. pick an unused guest id
pct status <drill-ctid>          # expect: does not exist

# 2. restore to a scratch storage, unprivileged, renamed
pct restore <drill-ctid> /path/to/vzdump-lxc-<ctid>-<stamp>.tar.zst \
    --storage <scratch-storage> --unprivileged 1 --hostname restore-drill

# 3. BEFORE first boot: fresh MAC + link down
pct set <drill-ctid> --net0 "name=eth0,bridge=vmbr0,firewall=1,link_down=1,hwaddr=<new-mac>,ip=dhcp"
pct start <drill-ctid>

# 4. INSIDE, before any link comes up: stop the VPN identity
pct exec <drill-ctid> -- systemctl disable --now tailscaled
```

Order matters: disable the VPN **while the link is still down**, then you may bring networking up.

### Trap: `pct status` says "stopped" while the restore is still running

During a restore the config exists and the disk file is being written, so `pct status <id>` reports
`stopped` and `ls` shows a disk — both look like "finished". They are not. Verify the process:

```bash
pgrep -af 'pct restore'      # anything here means NOT finished — wait
```

Racing it is prevented by the config lock: attempts to configure the guest fail with
`can't lock file '/run/lock/lxc/pve-config-<id>.lock' - got timeout`. **Treat that timeout as
"restore still running", not as an error to work around.** Nothing was applied, so there is nothing
to undo.

Also budget the time: a small home-CPU host took about 3 minutes just to decompress-and-verify
16 GiB, and longer to write it.

### Trap: the archived compose pins the live guest's addresses

A compose file that publishes explicit addresses (good practice) cannot bind them on the drill
guest, because those addresses belong to the live guest. Rewrite the ports to loopback for the
drill, and remember the Compose project-directory rule:

```bash
# `docker compose -f /tmp/drill-compose.yml` derives the PROJECT DIRECTORY from the file's
# location (/tmp), so it never loads /opt/paperclip-deploy/.env and fails with:
#   required variable BETTER_AUTH_SECRET is missing a value
# Pass both explicitly:
docker compose --project-directory /opt/paperclip-deploy \
               --env-file /opt/paperclip-deploy/.env \
               -f /tmp/drill-compose.yml up -d
```

Then prove the restored stack genuinely serves — from **inside** the guest, so no network is needed:

```bash
curl -s http://127.0.0.1:3100/api/health
```

This is the strongest evidence a drill can produce: the restored image plus the restored database
produce a working API, offline.

### Clean up

```bash
pct stop <drill-ctid> && pct destroy <drill-ctid>
```

Destroy the drill guest when done — it holds a full copy of the data at rest, and on a small host it
is a large amount of disk.

---

## 6. Close the gap a backup schedule leaves open

A backup job that runs at a fixed hour leaves a **window**: anything created after that hour has no
restore point until the next run. For a live business platform that window can be an entire working
day.

Mitigations, in order of value:

1. **Take an on-demand guest backup after any significant change** (first organisation created,
   agents wired, budgets set). Do not wait for the schedule.
2. **Keep a cheap, frequent, targeted copy.** The two data directories are small — one real
   instance produced a 13 MB archive containing the compose file, `.env`, the whole cluster and the
   hourly dumps:

   ```bash
   pct exec <ctid> -- tar czf - -C /opt paperclip-deploy paperclip-data > /mnt/<backup>/paperclip-appstate-$(date +%Y%m%d-%H%M%S).tar.gz
   gzip -t <archive>                  # integrity only — still verify content per §4
   ```

3. **Get a copy off the Proxmox host entirely.** An archive on another disk of the same host still
dies with the host. Pull it to a different machine and compare checksums, because a truncated
network copy is a silent failure:

   ```bash
   scp <pve-host>:<archive> ~/backups/paperclip/
   md5sum ~/backups/paperclip/<archive>          # must equal the remote md5sum
   ```

The hourly in-app dumps make the *data* recoverable on their own, but only to a point in time, and
they live inside the guest — so they do not survive losing it. They are a complement to guest
backups, not a replacement.

---

## 7. Drill checklist

- [ ] Backup archive passes decompression test (`zstd -t` / `gzip -t`)
- [ ] **Content** verified present in an in-app dump (bisect for a known string)
- [ ] Live database scanned first, as a positive control
- [ ] `bootstrapStatus` of the restored copy compared against live (`ready` vs `bootstrap_pending`)
- [ ] Restored to a spare guest with a fresh MAC and the link down
- [ ] `tailscaled` disabled before networking is enabled
- [ ] Restored app answered `/api/health` from inside the guest
- [ ] Drill guest stopped and destroyed
- [ ] Off-host copy exists on a *different machine*, checksums compared
- [ ] On-demand backup taken after the most recent significant change to the instance
