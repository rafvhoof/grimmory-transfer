# grimmory-transfer

A conservative, **cold application + logical MariaDB database** migration from a standalone Docker-hosted Grimmory instance to Grimmory in another Docker Compose stack (for example `arr-stack`). The goal is to preserve users, reading progress, books, metadata, application files and BookDrop contents **provided these are all stored in the documented database and mounts**.

> **Not a merge tool.** Target must be EMPTY, including database tables and `/app/data`, `/books`, `/bookdrop`. No source deletion is performed. Do NOT commit actual backups or `.env`.

## What is included

| Source location | Migration artifact | Contents |
|---|---|---|
| MariaDB database | `database.sql` | Users, library records, reading state, shelves and other records persisted in DB |
| `/app/data` | `app-data.tar.gz` | Application state, covers, metadata cache and uploaded data |
| `/books` | `books.tar.gz` | Managed book library |
| `/bookdrop` | `bookdrop.tar.gz` | Incoming book files |

The scripts require **three distinct Docker mounts** at those exact container paths. Multiple book-library mounts outside `/books`, or externally referenced books on NFS not mounted under `/books`, are **not automatically captured**. Verify `docker inspect` and migrate extra mounts separately. They must have matching *in-container* paths on the target, or DB references may break. Symlinks and files outside mounted paths may need special handling. Check that archives include expected counts.

## Prerequisites

- Docker Engine, Docker Compose, Bash, `tar`, `sha256sum`; ability to run Docker commands.
- On both hosts: an existing app container (target Grimmory can be created but MUST be stopped), MariaDB container with `mariadb-dump` and `mariadb` clients, and the same in-container mount destinations.
- MariaDB database account has permissions to dump source DB and create tables/insert data on destination. Database and users created before import.
- Prefer **the exact same Grimmory image/version** on source and target for first boot. Upgrade only after confirming migration. MariaDB majors should also be compatible with dump syntax.
- Ensure source and target are not writing simultaneously. No new books or state updates after final export.
- Sufficient free space for database dump and compressed book archives. Backups may contain credentials and sensitive account records: encrypt at rest and transfer over SSH.

## 1. Inspect source and target mounts

```bash
docker inspect grimmory --format '{{range .Mounts}}{{println .Source "->" .Destination}}{{end}}'
docker inspect mariadb --format '{{.Config.Image}}'
docker inspect grimmory --format '{{.Config.Image}}'
```

Adjust `.env` to match **each host's container names**; in a Compose project the actual container may be prefixed, e.g. `arr-stack-mariadb-1`. Database storage (usually `/config` in the LinuxServer MariaDB image) is intentionally transferred by logical dump, **not** by copying live database files.

## 2. Export on old VM

```bash
git clone git@github.com:rafvhoof/grimmory-transfer.git
cd grimmory-transfer
cp .env.example .env
chmod 600 .env
nano .env
bash scripts/export.sh
# Or specify an output path: bash scripts/export.sh /mnt/backup/grimmory-final
bash scripts/verify.sh backups/grimmory-YYYYMMDDTHHMMSSZ
```

`export.sh` stops the Grimmory app, leaves MariaDB online, dumps the database and archives all three mounts, then restarts the app on exit. **For the final cutover, immediately stop the old app again** and do not use it; otherwise state changes after the snapshot will be lost.

## 3. Transfer backup (not via GitHub)

From the destination VM, replace the example IP and timestamp:

```bash
mkdir -p ~/grimmory-transfer/backups
rsync -a --info=progress2 olduser@OLD_VM_IP:/home/olduser/grimmory-transfer/backups/grimmory-YYYYMMDDTHHMMSSZ/ ~/grimmory-transfer/backups/grimmory-final/
```

Verify SSH host identity and access permissions. Do not use public cloud storage without encrypting the backup first.

## 4. Prepare the new Arr VM

Create new Grimmory and dedicated MariaDB services in your existing Arr Compose stack. Make sure the new Grimmory has the **same in-container paths** for `/app/data`, `/books` and `/bookdrop`. In particular, if you want to store ebooks on Synology NFS, mount the NFS share on the **host** then bind mount that directory to `/books`; do not change existing working NFS mounts unnecessarily.

```bash
cd ~/arr-stack
docker compose up -d mariadb    # substitute your actual target database service name
docker compose stop grimmory    # if the app already exists
```

If the destination is already initialized, **do not run import** until you have a separate verified backup and have deliberately prepared fresh empty database and application mounts. This tool will not automatically delete any destination data.

## 5. Import on Arr VM

```bash
cd ~/grimmory-transfer
cp .env.example .env
chmod 600 .env
nano .env
bash scripts/verify.sh backups/grimmory-final
CONFIRM_REPLACE=YES bash scripts/import.sh backups/grimmory-final
cd ~/arr-stack
docker compose up -d grimmory
```

The import verifies checksums, checks that the database has zero tables and checks that all three app mounts are empty before extracting any files. `CONFIRM_REPLACE=YES` is an explicit acknowledgement, **not** an override of safety checks. If the imported files require correct Unix ownership, adjust permissions to match the configured Grimmory `USER_ID`/`GROUP_ID`, only within relevant target mounts.

## 6. Validate before switching clients

1. Review `docker compose logs --tail=150 grimmory` and the DB logs.
2. Confirm users, library definitions, book counts, shelves, reading position/history, annotations, thumbnails/covers and BookDrop settings.
3. Open random EPUB/PDF files, including books with non-ASCII filenames.
4. Test OPDS, Kobo/KOReader integrations and internal links; change external URLs if hostname changed.
5. Validate ownership, NAS permissions, any auxiliary library mounts, external auth/OIDC and reverse proxy settings.
6. Keep original VM stopped but retained until satisfied; take a fresh backup of target after verification.

## Troubleshooting and limitations

- **Empty target required:** Import deliberately refuses to merge existing content. To retry after a partial import, restore the destination from its pre-migration snapshot or provision a newly empty database and mounts. Do not blindly remove database or mounted files.
- **Credentials:** Source `.env` and Compose secrets are not exported. Re-enter DB settings in destination `.env`; OIDC/reverse-proxy secrets must be configured separately. Ensure DB connection points to destination MariaDB.
- **Library paths:** Database entries may refer to specific paths. Match in-container paths precisely; a different host path is fine if bind-mounted to the same internal path.
- **NFS:** Respect Grimmory's network-filesystem setting (`DISK_TYPE=NETWORK`) when applicable. Test library writes separately.
- **Application versions:** First migrate to equivalent Grimmory versions; only afterwards update via normal Docker workflow.
- **Database permissions:** On some images the dump client may have limited DB grants; use an appropriate user without embedding passwords in scripts.
- **Security:** This code uses Docker environment for the DB password during database commands. Treat local Docker access as privileged and keep `.env` private.
- **Externals:** Additional bind mounts, symlink targets, manually configured resources outside these paths, custom environment variables, external auth configuration and image-specific secrets require separate attention.

Reference: [official Grimmory installation guide](https://grimmory.org/docs/installation/) and [official Docker Compose example](https://github.com/grimmory-tools/grimmory/blob/develop/deploy/compose/docker-compose.yml).
