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
| Docker inspection | `manifest.txt` | Source image reference, image ID, registry digest, database name and mount paths |
| Bundle files | `SHA256SUMS` | SHA-256 checksums for all five artifacts |

The app must have **three separate Docker mounts at those exact container paths**. Extra library mounts, externally referenced files, symlink targets, configuration outside these mounts, external authentication and reverse proxy secrets need separate migration. Source `.env` and Compose secrets are not exported; reconfigure applicable settings on the new host.

## Your existing BookLore-era source

Your supplied Compose file already uses `ghcr.io/grimmory-tools/grimmory:latest`. Keep that source installation as it is for export; the new destination can use the `grimmory` names and current configuration conventions. Upstream's [BookLore upgrade guidance](https://github.com/grimmory-tools/grimmory/blob/develop/deploy/compose/docker-compose.yml) preserves existing database names/users and data, and the [installation guide](https://grimmory.org/docs/installation/) uses `SERVER_PORT` for the app port.

| Setting | Existing source | New destination example |
|---|---|---|
| App service/container | `booklore` | `grimmory` |
| Database service/container | `mariadb` | `grimmory-db` |
| MariaDB image | `lscr.io/linuxserver/mariadb:11.4.5` | `lscr.io/linuxserver/mariadb:11.4.8`, as in the upstream Compose example |
| App data | `/mnt/booklore/data` | `./grimmory/data` in Arr stack |
| Books | `/mnt/booklore/books` | `/mnt/media/books`, or another empty destination library |
| BookDrop | `/mnt/booklore/bookdrop` | `./grimmory/bookdrop` in Arr stack |
| Database files | `./mariadb/config` on source | `./grimmory/database` on destination; migrated by SQL dump |
| App port setting | `BOOKLORE_PORT` | `SERVER_PORT=6060` inside Docker; `GRIMMORY_PORT` selects the host port |
| Database name and user | Actual `MYSQL_DATABASE` and `DB_USER` from the source `.env` | Preserve those values, even if named `booklore` |

The posted Compose file does not show the actual database name or username. Read them from the source `.env`, or inspect these non-secret fields:

```bash
docker inspect mariadb --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n '/^MYSQL_DATABASE=/p; /^MYSQL_USER=/p'
docker inspect booklore --format '{{range .Config.Env}}{{println .}}{{end}}' \
  | sed -n '/^USER_ID=/p; /^GROUP_ID=/p; /^TZ=/p'
```

Configure `/etc/grimmory-transfer.env` on this source with `APP_CONTAINER=booklore`, `DB_CONTAINER=mariadb`, and the actual database name, username and password. Renaming the destination service does not require renaming the database; keeping its name also preserves qualified SQL references and routines.

Obtain the registry digest of the image used by the **running** source container before preparing the destination:

```bash
docker inspect booklore --format '{{.Config.Image}}'
docker image inspect "$(docker inspect booklore --format '{{.Image}}')" \
  --format '{{range .RepoDigests}}{{println .}}{{end}}'
```

Copy the complete `ghcr.io/grimmory-tools/grimmory@sha256:...` value into the destination's `GRIMMORY_IMAGE`. Inspecting the container's image ID avoids selecting a different image if `latest` was pulled after the container started. Export also records a registry digest and prints it when available. Keep a private copy of the original Compose file and `.env` for reference and rollback.

## 1. Prepare both hosts

Both hosts need Docker Engine, Docker Compose, Bash 4+, GNU/Linux utilities (`tar`, `sha256sum`, `df`, `awk`, `timeout`, etc.) and Docker access. MariaDB containers must contain `mariadb` and `mariadb-dump`. The database and its user must already exist on the destination, with appropriate dump/import permissions.

Use the **same Grimmory image contents** on both hosts for the first boot. A source tagged `latest` and a destination pinned by digest are accepted when their image IDs match. Pin the destination to the running source digest; upgrading the app is a separate step after validating migration. MariaDB versions must also support the dump syntax; the example moves within MariaDB 11.4 from your 11.4.5 source to the upstream 11.4.8 image using a logical dump.

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

For your source, change the example to `APP_CONTAINER=booklore`, `DB_CONTAINER=mariadb`. For the supplied destination Compose example, use `APP_CONTAINER=grimmory`, `DB_CONTAINER=grimmory-db`. Set `DB_NAME` to the source `MYSQL_DATABASE` on **both** hosts, and use the corresponding host's database password.

`NC_URL` is the Nextcloud **base URL**, including any installation subdirectory, without `/remote.php/dav/...`. The scripts build the WebDAV endpoint and URL-encode `NC_USER`. Use the Nextcloud user ID shown in your Files WebDAV settings. Create an app password under **Personal settings > Security**; keep the migration folder private. See the [Nextcloud WebDAV guide](https://docs.nextcloud.com/server/stable/user_manual/en/files/access_webdav.html).

Configuration is sourced by Bash, so quote values containing spaces or shell characters. Selection order is an explicit `TRANSFER_ENV_FILE`, then `/etc/grimmory-transfer.env`, then a repository-local `.env`. An explicitly selected missing file is an error. `.env.example` remains available for the local-file option. The old `NEXTCLOUD_*` settings have been replaced by the Paperless-compatible `NC_*` names.

If rclone is missing, the scripts install the Debian/Ubuntu distribution package using `apt-get` (and `sudo` when needed). Set `AUTO_INSTALL_RCLONE=0` to disable this, or install [rclone](https://rclone.org/install/) yourself on other distributions. No package installation happens until you run a transfer command.

## 2. Inspect mounts and staging space

On your source:

```bash
docker inspect booklore --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker inspect booklore --format '{{.Config.Image}}'
docker inspect mariadb --format '{{.Config.Image}}'
```

On the destination, inspect `grimmory` and `grimmory-db` instead. Use actual container names, which may be prefixed by a Compose project. Preserve `/app/data`, `/books` and `/bookdrop` inside the destination app. For NFS-backed ebooks, mount the share on the host and bind it to `/books`; verify permissions and Grimmory's `DISK_TYPE=NETWORK` setting when applicable.

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

Export prints each preparation step, including a separate size scan for each mount. Short Docker operations have a `DOCKER_TIMEOUT` of 30 seconds; each mount scan has a `SPACE_SCAN_TIMEOUT` of 1800 seconds, including utility image startup or pulling. Both settings accept positive integer seconds in the transfer configuration. Allow more scan time for large or slow network libraries. If one of these bounded operations ignores termination, its Docker client is forcefully stopped after another five seconds. Archives and database dumps have no size-related time limit.

Long export steps show a moving activity bar and elapsed time, refreshed every second in a terminal. Database dumps and archives also show the output size in MiB. The bar indicates that the step is still running; scans do not know the total work in advance, so it does not represent a completion percentage. Redirected output, a `dumb` terminal, and commands with their own status messages get a status line every ten seconds instead. Progress is written to stderr to keep SQL dumps, size estimates and checksum files clean. Uploads use rclone's existing transfer progress.

If export stalls, the last printed step identifies the operation to investigate. A stall at `Checking Docker access` points to Docker access or the daemon; a stall at `Estimating /books size` can also involve utility image startup or the filesystem backing that mount. Inspect the Docker service and source mounts on the source VM. The message `got 3 SIGTERM/SIGINTs, forcefully exiting` comes from Docker after repeated interrupts and does not identify the original cause. Backup helper containers use an init process to forward interrupts, and export attempts to remove an unfinished helper during cleanup.

The script stops Grimmory, leaves MariaDB online, dumps the database, archives the three mounts, records source metadata, verifies the bundle, and uploads it with parallel rclone copies. It publishes `SHA256SUMS` after the other files, checks that all six remote files exist, and removes the pending marker only after success.

On any export/upload failure or interrupt after stopping the app, it attempts to restart the source. On success it restarts the app unless `LEAVE_GRIMMORY_STOPPED=1`. For final cutover, keep the old app stopped and do not allow further changes after the snapshot.

The final output gives the migration ID and local staging path. An optional argument chooses a different local staging directory:

```bash
sudo bash scripts/export.sh /mnt/backup/grimmory-final
```

The remote ID is still timestamped unless you configure `MIGRATION_ID` explicitly. Keep both the local staging copy and source VM for rollback.

## 4. Prepare the destination Arr VM

Use [compose/grimmory.yml](compose/grimmory.yml) and [compose/grimmory.env.example](compose/grimmory.env.example) as the destination service definitions and settings. They follow the upstream Grimmory layout with a dedicated `grimmory-db`, current MariaDB 11.4 image, `SERVER_PORT=6060`, the three required mounts, and a health-dependent database startup.

Replace the existing `grimmory` / `grimmory-db` blocks in your Arr Compose file with the reviewed example, retaining the rest of the stack and its `arr` network. Merge the environment example into the Arr stack's existing private `.env`. The sample is a complete service definition, so replace the old service blocks rather than layering conflicting mount definitions over them.

Set these values before creating containers:

| Destination setting | Value to use |
|---|---|
| `GRIMMORY_IMAGE` | Full registry digest of the running source image, from the inspection command above |
| `GRIMMORY_DB_NAME` | Source `MYSQL_DATABASE`; do not automatically change it to `grimmory` |
| `GRIMMORY_DB_USER` | Source `DB_USER` |
| `GRIMMORY_DB_PASSWORD` | App/database password for the fresh target; also set this as target transfer `DB_PASSWORD` |
| `GRIMMORY_DB_ROOT_PASSWORD` | Separate strong password for the fresh target database |
| `PUID` / `PGID` | Existing Arr account; compare with old `APP_USER_ID` / `APP_GROUP_ID` and adjust restored ownership if needed |
| `DB_USER_ID` / `DB_GROUP_ID` | Desired owner of target MariaDB files; compare with the source's values |
| `TZ` | Keep your existing timezone |
| `GRIMMORY_PORT` | Existing `BOOKLORE_PORT` value if you want to keep the external port; otherwise `6060` |
| `GRIMMORY_BOOKS_PATH` | Empty target library, default `/mnt/media/books` on the mounted NAS |
| `GRIMMORY_DISK_TYPE` | `NETWORK` for NFS/SMB, `LOCAL` for local disk |
| `GRIMMORY_BOOKS_ACCESS` | `rw` during restore |

Both passwords and the image are required, so an unconfigured example fails Compose validation. For a Bindery-managed library, stop acquisition and any other writers during the migration; the destination library must still be empty. After validation, you can change `GRIMMORY_BOOKS_ACCESS` to `ro` and recreate the Grimmory container to restore the Arr stack's read-only library policy.

Create the Grimmory container without starting the app; start only its database:

```bash
cd ~/arr-stack
docker compose config --quiet
docker compose up -d grimmory-db
docker compose create grimmory
docker compose stop grimmory
```

The image's normal healthcheck targets the internal port 6060, independent of the chosen host port. The transfer configuration on this host must use `APP_CONTAINER=grimmory`, `DB_CONTAINER=grimmory-db`, `DB_NAME=<GRIMMORY_DB_NAME>`, `DB_USER=<GRIMMORY_DB_USER>` and `DB_PASSWORD=<GRIMMORY_DB_PASSWORD>`.

Substitute your actual service names if different. An initialized destination requires a separate verified backup and deliberately provisioned fresh database and mounts. The import never deletes existing data and has no nonempty-target bypass. Leave the source Compose and live database storage intact.

## 5. Download and import on the destination VM

Check the destination settings in `/etc/grimmory-transfer.env`, then:

```bash
cd ~/grimmory-transfer
sudo env CONFIRM_REPLACE=YES bash scripts/import.sh
```

Without an argument, import selects the newest completed `grimmory-YYYYMMDDTHHMMSSZ` folder under `NC_REMOTE_ROOT`, skipping folders with no `SHA256SUMS` or an `UPLOAD-PENDING.txt` marker. Set `MIGRATION_ID` in the configuration to choose a specific bundle, including one with a custom name.

Import downloads into the local staging directory, verifies all five artifact checksums and the three archives, and checks the source Grimmory image against the destination. If the bundle records an image ID, identical image contents are required even when tag/digest references differ; older bundles without an ID require the same image reference. It also checks the source database name when recorded. It reads metadata as text, never as executable shell configuration.

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

Once the restored instance is working and backed up, choose a newer stable Grimmory version or digest from the [official releases](https://github.com/grimmory-tools/grimmory/releases), update `GRIMMORY_IMAGE` in the destination `.env`, then run `docker compose pull grimmory` and `docker compose up -d grimmory` there. Review release notes before upgrading; keep the migration's first boot on the source image. Service renaming and modern Compose settings are already in place during the transfer.

## Troubleshooting and security

- **Incomplete upload:** A pending marker or missing `SHA256SUMS` blocks import. Retry upload from the retained local bundle using the same migration ID. Automatic selection may use an older completed bundle, so set `MIGRATION_ID` explicitly for final cutover.
- **Image mismatch:** Pin the running source image digest on the destination. With a recorded image ID, different references are accepted only for identical image contents. Older v1 bundles without an image ID are checked by image reference only.
- **Database name mismatch:** Keep the source `MYSQL_DATABASE` in destination `GRIMMORY_DB_NAME` and transfer `DB_NAME`. A service named `grimmory-db` can serve a database still named `booklore`.
- **Partial import:** Provision a newly empty destination or restore its pre-migration snapshot before retrying. Never blindly delete database or mounted files.
- **Nextcloud access:** Check the base URL, app password, quota, routing, TLS and reverse proxy limits. Set `RCLONE_CA_CERT` for a private CA; keep certificate verification enabled. `NC_CONNECT_TIMEOUT` and `NC_IO_TIMEOUT` default to 10 and 30 seconds.
- **Credential handling:** Keep the real transfer file mode `600`. Each transfer run creates a private temporary rclone configuration and removes it on exit. The app password is passed to `rclone obscure` over stdin; obscuring is reversible, not encryption at rest. Local Docker access and process inspection are privileged.
- **Backup contents:** The scripts transfer over HTTPS but do not encrypt stored backups. Keep local staging and the Nextcloud folder private, use encrypted storage as needed, and remove retained copies yourself after the rollback window.
- **External configuration:** DB storage is transferred by logical dump, not by copying live MariaDB files. Re-enter destination connection settings, OIDC/reverse proxy secrets and any other external configuration separately.

## Offline checks

```bash
bash tests/progress.sh
bash tests/transfer.sh
```

The tests use fake rclone and Docker commands with real filesystem archives and SHA-256 verification. They do not contact your servers.

References: [Grimmory installation](https://grimmory.org/docs/installation/) and [official Compose example](https://github.com/grimmory-tools/grimmory/blob/develop/deploy/compose/docker-compose.yml).
