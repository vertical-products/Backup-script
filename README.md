# Vertical Platform — Database Backup

Daily full backup of the production PostgreSQL cluster (`vertical_postgres_prod`)
to the Cloudflare R2 bucket `tutora-s3` (any S3-compatible store works).
The newest **3 days** of backups are kept. Older ones are deleted automatically.

## 1. What gets backed up

**Every** database in the cluster. The script finds them at run time, so new
tenants are picked up without any config change:

| Database               | Contents                                                          |
|------------------------|-------------------------------------------------------------------|
| `vertical_platform_db` | Plans, tenant registry, subscriptions, provisioning jobs, super admins |
| `vertical_db`          | Tenant template / maintenance DB                                  |
| `tenant_<id>`          | One per tenant, created at signup by `ProvisioningService`        |
| `postgres`             | Default maintenance DB                                            |
| *globals*              | Roles, passwords (hashed), grants (`pg_dumpall --globals-only`)   |

Not covered: Redis (cache/queue, rebuildable) and MinIO file uploads.

> **Keep `ENCRYPTION_MASTER_KEY` (from `apps/api/.env`) safe somewhere else.**
> Tenant DB connection strings and other secrets are encrypted with it. A
> restored database is useless without that key, and the key is *not* in these backups.

## 2. How a run works

```
pre-flight checks ─► pg_dump -Fc every DB ─► verify dumps ─► tar ─► upload ─► verify size ─► delete backups older than 3 days
 (tools, container,    + globals.sql.gz      (pg_restore      (one        (3 retries)
  bucket, disk space)                         --list)          archive)
```

* **Format:** `pg_dump` custom format (`.dump`), which is PostgreSQL's compressed
  full backup (schema + data). It is the Postgres equivalent of SQL Server's
  `.bacpac`. `.bacpac` itself only exists for SQL Server / Azure SQL.
* **One object per backup:** `s3://tutora-s3/vertical-platform/postgres/vertical_YYYY-MM-DD_HHMMSS.tar`.
  An upload is atomic, so a half-uploaded backup is never seen as a real one.
* **Retention (`RETENTION_DAYS=3`):** after day 4's backup uploads and is verified,
  day 1's backup is deleted, leaving days 2, 3 and 4.
* **Safety rules:**
  * A run that fails at any step deletes nothing.
  * Only objects named exactly `<BACKUP_NAME>_<date>_<time>.tar` are ever deleted.
  * Pruning only happens once the new backup is visible in the bucket listing.
  * A lock stops two runs from overlapping.
  * Staging files are removed even when a run fails.
* **No DB password on the host:** the script uses the container's own `POSTGRES_PASSWORD`.

Inside each archive:

```
vertical_2026-10-12_020000/
  vertical_platform_db.dump   vertical_db.dump   tenant_<id>.dump ...
  globals.sql.gz              MANIFEST.txt       SHA256SUMS
```

## 3. Setup on the production droplet

Requirements: `docker`, AWS CLI v2 (`aws`), `flock`, `curl`, `tar`, `gzip`.
Ubuntu 24.04 ships everything except the AWS CLI:

```bash
curl -sSL "https://awscli.amazonaws.com/awscli-exe-linux-x86_64.zip" -o /tmp/awscliv2.zip
cd /tmp && unzip -q awscliv2.zip && sudo ./aws/install
```

```bash
sudo mkdir -p /opt/vertical && sudo cp -r Backupscripting /opt/vertical/
cd /opt/vertical/Backupscripting
cp config/backup.env.example config/backup.env
chmod 600 config/backup.env
nano config/backup.env          # real R2 key/secret, alert + heartbeat URLs
```

Create an R2 API token with **Object Read & Write** limited to the `tutora-s3` bucket
(Cloudflare dashboard → R2 Object Storage → Manage API tokens). Put its
**Access Key ID** and **Secret Access Key** in `backup.env`. The `cfat_…` token
value is for the Cloudflare REST API and is not used here. R2 needs
`AWS_DEFAULT_REGION=auto` and `S3_ENDPOINT_URL=https://<ACCOUNT_ID>.r2.cloudflarestorage.com`.

Test it by hand. Run it as the same user that will own the cron job: root, or a
user in the `docker` group.

```bash
bash scripts/backup.sh --dry-run   # checks everything, shows what would be deleted, changes nothing
bash scripts/backup.sh             # real run
tail -n 50 logs/backup_$(date +%F).log
aws --endpoint-url https://2981b4797332bb1d614c15a54f491afa.r2.cloudflarestorage.com --region auto \
  s3 ls s3://tutora-s3/vertical-platform/postgres/
```

Install the daily 02:00 cron job. It merges into the existing crontab and is safe to re-run:

```bash
bash scripts/install_cron.sh
```

## 4. Monitoring (do this, it is what makes it production-grade)

* **`HEARTBEAT_URL`**: create a check on healthchecks.io (free), Uptime Kuma or
  Better Stack with period 24h and grace 2h, then paste the ping URL. You get an
  alert if a backup does not succeed, including when the server is down or cron
  never ran. The script cannot report those cases itself.
* **`ALERT_WEBHOOK_URL`**: gets an immediate message with the log tail when a run fails.
* Logs: `logs/backup_<date>.log`, kept for 30 days.

## 5. Restoring (manual)

Restore into a **separate** container first, check the data, then cut over.

```bash
aws --endpoint-url https://2981b4797332bb1d614c15a54f491afa.r2.cloudflarestorage.com --region auto \
  s3 cp s3://tutora-s3/vertical-platform/postgres/vertical_2026-10-12_020000.tar .
tar -xf vertical_2026-10-12_020000.tar && cd vertical_2026-10-12_020000
sha256sum -c SHA256SUMS                                   # must all be OK

C=vertical_postgres_restore                               # target container
gunzip -c globals.sql.gz | docker exec -i $C psql -U vertical -d postgres
for f in *.dump; do
  db="${f%.dump}"; [ "$db" = postgres ] && continue
  docker exec $C createdb -U vertical "$db"
  docker exec -i $C pg_restore -U vertical -d "$db" --no-owner --exit-on-error < "$f"
done
```

Do a test restore at least once a month. A backup you have never restored is not proven.

## 6. Notes

* Retention is done by the script only. Do **not** add a short R2 lifecycle
  (auto-delete) rule on the bucket: if backups stopped, it would delete the
  last good copies. The heartbeat monitor is what tells you backups stopped.
* R2 is on a different provider than the DigitalOcean droplet, so the backups
  survive the loss of the droplet or the DO account. R2 has no egress fees,
  so downloading a backup to restore it costs nothing.

## 7. Files

```
Backupscripting/
├── README.md
├── config/backup.env.example   copy to backup.env (gitignored) and fill in
├── lib/common.sh               config, logging, alerts, lock, docker/S3 helpers
├── scripts/backup.sh           the backup (run daily by cron)
├── scripts/install_cron.sh     installs the cron job
├── cron/crontab.txt            schedule template (02:00 daily)
└── logs/                       per-day logs + cron.log
```
