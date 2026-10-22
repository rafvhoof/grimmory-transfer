# grimmory-transfer

Migrate a standalone Docker-hosted Grimmory instance into another Docker Compose stack through Nextcloud. The workflow follows [paperless-ngx-transfer](https://github.com/rafvhoof/paperless-ngx-transfer): one export-and-upload command on the source and one download-and-import command on the destination.

This preserves users, reading progress, books, metadata, application files and BookDrop contents **when they are stored in the database and mounts below**.

> **Empty target required.** The destination database must have zero tables and `/app/data`, `/books` and `/bookdrop` must be empty. This tool never merges or deletes destination content. Keep the source VM and backups until migration is validated. Never commit credentials or backup data.

## Comparison with the Paperless transfer

| Area | Paperless transfer | Grimmory transfer |
|---|---|---|
| Entry points | Export uploads; import downloads | Same, using `export.sh` and `import.sh` |
| Configuration | `/etc/paperless-ngx-transfer.env`, `TRANSFER_ENV_FILE`, `NC_*` | `/etc/grimmory-transfer.env`, same override and Nextcloud variables |
| Transport | Authenticated Nextcloud WebDAV via rclone | Same; temporary mode-600 configuration, parallel copies, retries and progress |
| Source preparation | Check staging space and Nextcloud before stopping services | Same checks before stopping the Grimmory app; MariaDB stays running |
| Bundle selection | `MIGRATION_ID` or latest timestamped folder | Same; automatic selection skips pending or incomplete uploads |
| Payload | Native document export, configuration and PostgreSQL recovery dump | Logical MariaDB dump and three mount archives |
| Cutover | Leaves source stopped after success by default | Automatic restart remains the default; explicitly set `LEAVE_GRIMMORY_STOPPED=1` for final cutover |
| Destination checks | Matching version and empty destination | Matching Grimmory image, zero DB tables and three empty mounts; no bypass |

Grimmory needs filesystem archives to preserve its Docker mount contents and Unix metadata. These are transferred individually; there is no additional tar/zip containing the complete bundle, so only one staging copy is needed.

## What is included

| Source | Bundle artifact | Contents |
|---|---|---|
| MariaDB database | `database.sql` | Users, libraries, reading state, shelves and other DB records |
| `/app/data` | `app-data.tar.gz` | Application state, covers, metadata cache and uploaded data |
| `/books` | `books.tar.gz` | Managed book library |
| `/bookdrop` | `bookdrop.tar.gz` | Incoming book files |
| Docker inspection | `manifest.txt` | Source image reference, image ID, database name and mount paths |
| Bundle files | `SHA256SUMS` | SHA-256 checksums for all five artifacts |

The app must have **three separate Docker mounts at those exact container paths**. Extra library mounts, externally referenced files, symlink targets, configuration outside these mounts, external authentication and reverse proxy secrets need separate migration. Source `.env` and Compose secrets are not exported; reconfigure applicable settings on the new host.

## 1. Prepare both hosts

Both hosts need Docker Engine, Docker Compose, Bash 4+, GNU/Linux utilities (`tar`, `sha256sum`, `df`, `awk`, `timeout`, etc.) and Docker access. MariaDB containers must contain `mariadb` and `mariadb-dump`. The database and its user must already exist on the destination, with appropriate dump/import permissions.

Use the **same Grimmory image reference and image contents** on both hosts for the first boot. Pin a version or digest rather than a moving tag such as `latest`. MariaDB versions must also support the dump syntax. Upgrade only after validating migration.

Clone this repository on each host:

```bash
git clone https://github.com/rafvhoof/grimmory-transfer.git
cd grimmory-transfer
sudo install -m 600 transfer.env.example /etc/grimmory-transfer.env
sudo nano /etc/grimmory-transfer.env
```

Use the same Nextcloud settings on both hosts, and the correct container names and database credentials for each host:

```bash
NC_URL='https://nextcloud.example.com'
NC_USER='your-nextcloud-user'
NC_APP_PASSWORD='your-app-password'
NC_REMOTE_ROOT='GrimmoryMigration'

APP_CONTAINER=grimmory
DB_CONTAINER=mariadb
DB_NAME=grimmory
DB_USER=grimmory
DB_PASSWORD='your-database-password'
```

`NC_URL` is the Nextcloud **base URL**, including any installation subdirectory, without `/remote.php/dav/...`. The scripts build the WebDAV endpoint and URL-encode `NC_USER`. Use the Nextcloud user ID shown in your Files WebDAV settings. Create an app password under **Personal settings > Security**; keep the migration folder private. See the [Nextcloud WebDAV guide](https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html).

Configuration is sourced by Bash, so quote values containing spaces or shell characters. Selection order is an explicit `TRANSFER_ENV_FILE`, then `/etc/grimmory-transfer.env`, then a repository-local `.env`. An explicitly selected missing file is an error. `.env.example` remains available for the local-file option. The old `NEXTCLOUD_*` settings have been replaced by the Paperless-compatible `NC_*` names.

If rclone is missing, the scripts install the Debian/Ubuntu distribution package using `apt-get` (and `sudo` when needed). Set `AUTO_INSTALL_RCLONE=0` to disable this, or install [rclone](https://rclone.org/install/) yourself on other distributions. No package installation happens until you run a transfer command.

## 2. Inspect mounts and staging space

On both hosts:

```bash
docker inspect grimmory --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker inspect grimmory --format '{{.Config.Image}}'
docker inspect mariadb --format '{{.Config.Image}}'
```

Use actual container names, which may be prefixed by a Compose project. Preserve `/app/data`, `/books` and `/bookdrop` inside the destination app. For NFS-backed ebooks, mount the share on the host and bind it to `/books`; verify permissions and Grimmory's `DISK_TYPE=NETWORK` setting when applicable.

The default local staging directory on both hosts is:

```text
/var/tmp/grimmory-transfer
```

For larger temporary storage, set `GRIMMORY_TRANSFER_WORKDIR=/mnt/large-temporary-storage/grimmory-transfer`. `BACKUP_DIR` remains a legacy alias. The export estimates mount sizes plus database size, a 25% margin and 512 MiB overhead before stopping Grimmory. This is an estimate, so allow extra capacity for large SQL dumps. Both hosts and Nextcloud need enough free space or quota for the complete bundle.

You can test Nextcloud access separately without stopping the app:

```bash
sudo bash scripts/transfer.sh preflight
```

This tests authentication, creates the migration root, uploads a small probe, downloads and compares it, then removes the probe. It uses bounded timeouts and does not transfer application data.

## 3. Export and upload on the source VM

Take a VM backup or snapshot first. Run:

```bash
sudo bash scripts/export.sh
```

For the **final cutover**, explicitly opt into leaving the source app stopped:

```bash
sudo env LEAVE_GRIMMORY_STOPPED=1 bash scripts/export.sh
```

If this setting is already present in your configuration file, edit it there; sourced configuration values take precedence over environment variables.

Before stopping the app, export checks the containers, mounts, available staging space and Nextcloud read/write access. It then creates a visible `UPLOAD-PENDING.txt` marker under:

```text
Nextcloud / GrimmoryMigration / grimmory-YYYYMMDDTHHMMSSZ /
```

The script stops Grimmory, leaves MariaDB online, dumps the database, archives the three mounts, records source metadata, verifies the bundle, and uploads it with parallel rclone copies. It publishes `SHA256SUMS` after the other files, checks that all six remote files exist, and removes the pending marker only after success.

On any export/upload failure after stopping the app, it attempts to restart the source. On success it restarts the app unless `LEAVE_GRIMMORY_STOPPED=1`. For final cutover, keep the old app stopped and do not allow further changes after the snapshot.

The final output gives the migration ID and local staging path. An optional argument chooses a different local staging directory:

```bash
sudo bash scripts/export.sh /mnt/backup/grimmory-final
```

The remote ID is still timestamped unless you configure `MIGRATION_ID` explicitly. Keep both the local staging copy and source VM for rollback.

## 4. Prepare the destination Arr VM

Create Grimmory and a dedicated MariaDB service in your Compose stack. Pin the source Grimmory image and provide the same three in-container mount destinations. Create the Grimmory container without starting the app; start only MariaDB:

```bash
cd ~/arr-stack
docker compose create grimmory
docker compose up -d mariadb
docker compose stop grimmory
```

Substitute your actual service names. An initialized destination requires a separate verified backup and deliberately provisioned fresh database and mounts. The import never deletes existing data and has no nonempty-target bypass.

## 5. Download and import on the destination VM

Check the destination settings in `/etc/grimmory-transfer.env`, then:

```bash
cd ~/grimmory-transfer
sudo env CONFIRM_REPLACE=YES bash scripts/import.sh
```

Without an argument, import selects the newest completed `grimmory-YYYYMMDDTHHMMSSZ` folder under `NC_REMOTE_ROOT`, skipping folders with no `SHA256SUMS` or an `UPLOAD-PENDING.txt` marker. Set `MIGRATION_ID` in the configuration to choose a specific bundle, including one with a custom name.

Import downloads into the local staging directory, verifies all five artifact checksums and the three archives, and checks the source Grimmory image against the destination. If the bundle records an image ID, the underlying image contents must also match. It reads metadata as text, never as executable shell configuration.

Before restoring anything, import also requires the destination app to be stopped, MariaDB to be running, the database to have zero tables and all three mounts to be empty. `CONFIRM_REPLACE=YES` is an acknowledgement, not an override of these checks. It restores mount contents and imports the SQL dump, retaining the downloaded bundle.

Start Grimmory only after a successful import:

```bash
cd ~/arr-stack
docker compose up -d grimmory
```

If Unix ownership needs adjustment, use the app's configured `USER_ID`/`GROUP_ID` and restrict changes to the relevant target mounts.

## Manual retries and local imports

The transport helper remains available for retrying an existing staging copy without exporting again:

```bash
sudo bash scripts/transfer.sh upload /var/tmp/grimmory-transfer/grimmory-YYYYMMDDTHHMMSSZ
sudo bash scripts/transfer.sh download
sudo bash scripts/transfer.sh download grimmory-YYYYMMDDTHHMMSSZ /mnt/backup/grimmory-final
```

An upload can take a third argument to set the remote migration ID. Remote files are immutable: an identical upload can be retried, but changed contents require a new ID. Failed files may need to restart; completed files are compared by checksum when Nextcloud supplies one. The [rclone Nextcloud backend](https://rclone.org/webdav/) handles chunked large-file uploads.

Downloads can replace backup artifacts in their chosen local directory. Use a dedicated staging directory. A failed or corrupt download never reaches restoration; rerunning the command can repair it.

To verify and import a previously downloaded local bundle without contacting Nextcloud:

```bash
sudo bash scripts/verify.sh /mnt/backup/grimmory-final
sudo env CONFIRM_REPLACE=YES bash scripts/import.sh /mnt/backup/grimmory-final
```

## 6. Validate before switching clients

1. Review `docker compose logs --tail=150 grimmory` and MariaDB logs.
2. Confirm users, libraries, book counts, shelves, reading progress/history, annotations, covers and BookDrop settings.
3. Open several EPUB/PDF files, including non-ASCII filenames.
4. Test OPDS, Kobo/KOReader integrations and internal links; update external URLs if the hostname changed.
5. Check ownership, NAS access, extra mounts, external authentication and reverse proxy settings.
6. Keep the old VM stopped as rollback, then take a fresh backup of the destination.

## Troubleshooting and security

- **Incomplete upload:** A pending marker or missing `SHA256SUMS` blocks import. Retry upload from the retained local bundle using the same migration ID. Automatic selection may use an older completed bundle, so set `MIGRATION_ID` explicitly for final cutover.
- **Image mismatch:** Pin the same source image and digest on the destination. Older v1 bundles without an image ID are checked by image reference only.
- **Partial import:** Provision a newly empty destination or restore its pre-migration snapshot before retrying. Never blindly delete database or mounted files.
- **Nextcloud access:** Check the base URL, app password, quota, routing, TLS and reverse proxy limits. Set `RCLONE_CA_CERT` for a private CA; keep certificate verification enabled. `NC_CONNECT_TIMEOUT` and `NC_IO_TIMEOUT` default to 10 and 30 seconds.
- **Credential handling:** Keep the real transfer file mode `600`. Each transfer run creates a private temporary rclone configuration and removes it on exit. The app password is passed to `rclone obscure` over stdin; obscuring is reversible, not encryption at rest. Local Docker access and process inspection are privileged.
- **Backup contents:** The scripts transfer over HTTPS but do not encrypt stored backups. Keep local staging and the Nextcloud folder private, use encrypted storage as needed, and remove retained copies yourself after the rollback window.
- **External configuration:** DB storage is transferred by logical dump, not by copying live MariaDB files. Re-enter destination connection settings, OIDC/reverse proxy secrets and any other external configuration separately.

## Offline checks

```bash
bash tests/transfer.sh
```

The tests use fake rclone and Docker commands with real filesystem archives and SHA-256 verification. They do not contact your servers.

References: [Grimmory installation](https://grimmory.org/docs/installation/) and [official Compose example](https://github.com/grimmory-tools/grimmory/blob/develop/deploy/compose/docker-compose.yml).
