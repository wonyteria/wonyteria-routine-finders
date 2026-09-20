#!/usr/bin/env python3
"""Hourly local backups. SQLite snapshots are online and independent per database.

Only verified snapshots inside backups/managed are eligible for automatic pruning.
Restore exports into a NEW directory; it never replaces the live Docker volume.
"""

import argparse
import base64
import contextlib
import datetime as dt
import fcntl
import hashlib
import json
import logging
from logging.handlers import RotatingFileHandler
import os
from pathlib import Path, PurePosixPath
import re
import shutil
import sqlite3
import subprocess
import tarfile
import tempfile
import uuid
from zoneinfo import ZoneInfo

MANAGER = "routine-finders-backup-v1"
DATABASES = (
    "production.sqlite3", "production_cache.sqlite3",
    "production_queue.sqlite3", "production_cable.sqlite3",
)
REQUIRED_TABLES = ("users", "solid_cache_entries", "solid_queue_jobs", "solid_cable_messages")
CONFIG_FILES = (
    "runtime.env", "compose.macstudio.yml", "deploy/release.env",
    "deploy/cloudflared.yml", "tunnel.token", "source/config/credentials.yml.enc",
    "deploy/backup.py", "deploy/life.routinefinders.backup.plist",
)
SNAPSHOT_NAME = re.compile(r"\d{8}T\d{6}Z-[0-9a-f]{8}\Z")
UTC = dt.timezone.utc
TIMEZONE = ZoneInfo("Asia/Seoul")
LOG = logging.getLogger("routine-finders-backup")


def now():
    return dt.datetime.now(UTC)


def digest(path):
    result = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for block in iter(lambda: stream.read(1024 * 1024), b""):
            result.update(block)
    return result.hexdigest()


def read_json(path):
    with Path(path).open() as stream:
        return json.load(stream)


def atomic_json(path, value):
    path = Path(path)
    temporary = path.with_name("." + path.name + "-" + uuid.uuid4().hex)
    try:
        with temporary.open("x") as stream:
            os.chmod(temporary, 0o600)
            json.dump(value, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)


def safe_relative(name):
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts or "\\" in name:
        raise ValueError("Unsafe archive path")
    return path


def unpack(archive, destination):
    """Do not use extractall: reject links, devices, traversal, and duplicate files."""
    destination = Path(destination)
    seen = set()
    with tarfile.open(archive, "r:gz") as source:
        for member in source:
            relative = safe_relative(member.name)
            if not relative.parts:
                if member.isdir():
                    continue
                raise ValueError("Invalid root archive member")
            if not (member.isdir() or member.isfile()):
                raise ValueError("Archive contains a link or special file")
            target = destination.joinpath(*relative.parts)
            if member.isdir():
                if target.exists() and not target.is_dir():
                    raise ValueError("Archive directory collision")
                target.mkdir(mode=0o700, parents=True, exist_ok=True)
                continue
            key = str(relative)
            if key in seen or target.exists():
                raise ValueError("Duplicate archive file")
            seen.add(key)
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            with source.extractfile(member) as incoming, target.open("xb") as outgoing:
                os.chmod(target, 0o600)
                shutil.copyfileobj(incoming, outgoing)


def file_manifest(directory):
    result = {}
    for path in sorted(Path(directory).rglob("*")):
        if path.is_symlink():
            raise ValueError("Symlinks are not supported in backups")
        if path.is_file():
            result[str(path.relative_to(directory))] = {
                "sha256": digest(path), "bytes": path.stat().st_size,
            }
        elif not path.is_dir():
            raise ValueError("Special files are not supported")
    return result


def database_report(storage, normalize=False):
    report = {}
    for name, required in zip(DATABASES, REQUIRED_TABLES):
        path = Path(storage) / name
        if not path.is_file():
            raise ValueError("Required database missing: " + name)
        with contextlib.closing(sqlite3.connect(path.as_uri() + "?mode=rw", uri=True)) as db:
            if normalize:
                db.execute("PRAGMA journal_mode=DELETE")
            if db.execute("PRAGMA integrity_check").fetchall() != [("ok",)]:
                raise ValueError("Database integrity check failed: " + name)
            tables = [r[0] for r in db.execute(
                "SELECT name FROM sqlite_master WHERE type=? AND name NOT LIKE ?",
                ("table", "sqlite_%"),
            )]
            if required not in tables:
                raise ValueError("Required table missing: " + required)
            counts = {}
            for table in tables:
                quoted = '"' + table.replace('"', '""') + '"'
                counts[table] = db.execute("SELECT COUNT(*) FROM " + quoted).fetchone()[0]
            report[name] = counts
    primary = Path(storage) / DATABASES[0]
    with contextlib.closing(sqlite3.connect(primary.as_uri() + "?mode=ro", uri=True)) as db:
        blobs = db.execute("SELECT key, byte_size, checksum, service_name FROM active_storage_blobs")
        count = 0
        for key, size, checksum, service in blobs:
            if service != "local" or not re.fullmatch(r"[A-Za-z0-9_-]{4,}", key):
                raise ValueError("Unsupported attachment service or unsafe key")
            path = Path(storage) / key[:2] / key[2:4] / key
            if not path.is_file() or path.stat().st_size != size:
                raise ValueError("Attachment missing or wrong size")
            if checksum:
                md5 = hashlib.md5()
                with path.open("rb") as stream:
                    for block in iter(lambda: stream.read(1024 * 1024), b""):
                        md5.update(block)
                if base64.b64encode(md5.digest()).decode() != checksum:
                    raise ValueError("Attachment checksum mismatch")
            count += 1
    return {"tables": report, "verified_attachments": count}


def retention_keep(snapshots, timestamp):
    """Union: all last-24h snapshots + newest in 7 days / 4 weeks / 3 months."""
    ordered = sorted(snapshots, key=lambda item: item[1], reverse=True)
    if any(created > timestamp + dt.timedelta(minutes=5) for _, created in ordered):
        raise ValueError("Future-dated snapshot: refusing automatic deletion")
    keep = {name for name, created in ordered if created >= timestamp - dt.timedelta(hours=24)}
    buckets = [set(), set(), set()]
    limits = (7, 4, 3)
    for name, created in ordered:
        local = created.astimezone(TIMEZONE)
        iso = local.isocalendar()
        keys = (local.date(), (iso[0], iso[1]), (local.year, local.month))
        for seen, limit, key in zip(buckets, limits, keys):
            if key not in seen and len(seen) < limit:
                seen.add(key)
                keep.add(name)
    return keep


def notify_failure():
    if not Path("/usr/bin/osascript").exists():
        return
    try:
        notice = subprocess.run([
            "/usr/bin/osascript", "-e",
            'display notification "Automatic backup failed. Check backup status and logs." with title "Routine Finders Backup"',
        ], capture_output=True, text=True, timeout=10)
        if notice.returncode:
            LOG.warning("macOS failure notification could not be delivered")
    except (OSError, subprocess.TimeoutExpired):
        LOG.warning("macOS failure notification could not be delivered")


class Backups:
    def __init__(self, service, docker=None):
        self.service = Path(service).resolve()
        self.root = self.service / "backups/managed"
        self.docker = docker or str(Path.home() / ".orbstack/bin/docker")

    @contextlib.contextmanager
    def locked(self):
        if self.root.is_symlink() or self.root.parent.is_symlink():
            raise ValueError("Managed backup directory must not be a symlink")
        self.root.mkdir(mode=0o700, parents=True, exist_ok=True)
        marker = self.root / "repository.json"
        if not marker.exists() and any(p.name != ".lock" for p in self.root.iterdir()):
            raise ValueError("Refusing to adopt a nonempty unmanaged backup directory")
        lock_path = self.root / ".lock"
        if lock_path.is_symlink():
            raise ValueError("Unsafe backup lock")
        with lock_path.open("a") as lock:
            os.chmod(lock_path, 0o600)
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                raise RuntimeError("Another backup or restore is already running") from None
            if not marker.exists():
                atomic_json(marker, {"manager": MANAGER, "id": str(uuid.uuid4())})
            self.repository()
            os.chmod(self.root, 0o700)
            yield

    def repository(self):
        marker = self.root / "repository.json"
        if marker.is_symlink():
            raise ValueError("Unsafe repository marker")
        value = read_json(marker)
        if value.get("manager") != MANAGER:
            raise ValueError("Unrecognized backup repository")
        uuid.UUID(value["id"])
        return value

    def manifest(self, snapshot):
        path = Path(snapshot)
        if path.parent != self.root or not SNAPSHOT_NAME.fullmatch(path.name) or path.is_symlink():
            raise ValueError("Snapshot is outside the managed namespace")
        entries = list(path.iterdir())
        if {p.name for p in entries} != {"snapshot.tar.gz", "manifest.json"}:
            raise ValueError("Unexpected snapshot contents; refusing deletion or restore")
        if any(p.is_symlink() or not p.is_file() for p in entries):
            raise ValueError("Unsafe snapshot contents")
        value = read_json(path / "manifest.json")
        if value.get("manager") != MANAGER or value.get("repository_id") != self.repository()["id"]:
            raise ValueError("Snapshot ownership mismatch")
        created = dt.datetime.fromisoformat(value["created_at"])
        if created.tzinfo is None or not value.get("verified"):
            raise ValueError("Invalid or unverified snapshot")
        if value.get("name") != path.name or not path.name.startswith(created.astimezone(UTC).strftime("%Y%m%dT%H%M%SZ-")):
            raise ValueError("Snapshot name mismatch")
        return value

    def snapshots(self):
        return sorted(p for p in self.root.iterdir() if SNAPSHOT_NAME.fullmatch(p.name))

    def verify(self, snapshot, destination):
        manifest = self.manifest(snapshot)
        archive = Path(snapshot) / "snapshot.tar.gz"
        if digest(archive) != manifest["archive_sha256"]:
            raise ValueError("Backup archive checksum mismatch")
        unpack(archive, destination)
        if file_manifest(destination) != manifest["files"]:
            raise ValueError("Restored file manifest mismatch")
        report = database_report(Path(destination) / "storage")
        if report != manifest["database_report"]:
            raise ValueError("Restored database counts mismatch")
        return manifest

    def prune(self, verified_current, timestamp):
        candidates = self.snapshots()
        metadata = [(p, self.manifest(p)) for p in candidates]
        keep = retention_keep([(p.name, dt.datetime.fromisoformat(m["created_at"])) for p, m in metadata], timestamp)
        if verified_current.name not in keep:
            raise ValueError("Newest verified backup would not be retained")
        removals = [(p, m) for p, m in metadata if p.name not in keep]
        # Validate EVERY deletion candidate before deleting any of them.
        for path, manifest in removals:
            if digest(path / "snapshot.tar.gz") != manifest["archive_sha256"]:
                raise ValueError("Corrupt old backup: refusing automatic deletion")
        for path, _ in removals:
            self.manifest(path)
            (path / "snapshot.tar.gz").unlink()
            (path / "manifest.json").unlink()
            path.rmdir()
        return [path.name for path, _ in removals]

    def capture(self, payload):
        result = subprocess.run([self.docker, "inspect", "routine-finders-web-1"],
                                capture_output=True, text=True, timeout=30, check=True)
        app = json.loads(result.stdout)[0]
        if not app["State"]["Running"]:
            raise ValueError("Production container is not running")
        mounts = [m for m in app["Mounts"] if m["Destination"] == "/rails/storage"]
        if len(mounts) != 1 or mounts[0]["Type"] != "volume" or mounts[0]["Name"] != "routine_finders_storage_macstudio":
            raise ValueError("Unexpected production storage mount")
        storage = payload / "storage"
        storage.mkdir(mode=0o700)
        container = "routine-finders-backup-" + uuid.uuid4().hex[:12]
        script = "set -eu\n"
        for name in DATABASES:
            script += 'sqlite3 -readonly /source/' + name + ' ".timeout 5000" ".backup /snapshot/' + name + '"\n'
        excludes = " ".join("--exclude=./" + name + suffix for name in DATABASES for suffix in ("", "-wal", "-shm", "-journal"))
        script += "tar " + excludes + " -czf /snapshot/uploads.tar.gz -C /source .\n"
        # SQLite read-only connections may still need to create WAL/SHM coordination
        # files. The volume must permit that; -readonly prevents database data writes.
        command = [self.docker, "run", "--rm", "--name", container, "--network", "none",
                   "--read-only", "--cap-drop", "ALL", "--security-opt", "no-new-privileges",
                   "--user", "1000:1000", "--mount", "type=volume,src=" + mounts[0]["Name"] + ",dst=/source",
                   "--mount", "type=bind,src=" + str(storage) + ",dst=/snapshot",
                   "--entrypoint", "sh", app["Image"], "-c", script]
        try:
            subprocess.run(command, capture_output=True, text=True, timeout=600, check=True)
        finally:
            # Only this invocation's uniquely named helper can be removed.
            cleanup = subprocess.run([self.docker, "rm", "-f", container], capture_output=True, text=True, timeout=30)
            if cleanup.returncode and "No such container" not in cleanup.stderr:
                LOG.warning("Backup helper cleanup failed: %s", cleanup.stderr.strip())
        unpack(storage / "uploads.tar.gz", storage)
        (storage / "uploads.tar.gz").unlink()
        report = database_report(storage, normalize=True)
        for name in CONFIG_FILES:
            source = self.service / name
            if source.is_symlink() or not source.is_file():
                raise ValueError("Required recovery configuration missing or linked: " + name)
            target = payload / "config" / name
            target.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            os.chmod(target, 0o600)
        recovery = {
            "image_id": app["Image"], "image_reference": app["Config"]["Image"],
            "revision": (app["Config"].get("Labels") or {}).get("org.opencontainers.image.revision"),
            "storage_volume": mounts[0]["Name"],
            "consistency": "Independent online SQLite snapshots; referenced local attachments verified. Not a cross-database atomic snapshot.",
        }
        atomic_json(payload / "recovery.json", recovery)
        return report

    def backup(self):
        with self.locked():
            previous = read_json(self.root / "status.json") if (self.root / "status.json").exists() else {}
            started = now()
            state = {**previous, "last_attempt_at": started.isoformat(), "state": "running"}
            atomic_json(self.root / "status.json", state)
            try:
                if shutil.disk_usage(self.root).free < 1024 ** 3:
                    raise RuntimeError("Less than 1 GiB free; refusing backup and pruning")
                with tempfile.TemporaryDirectory(prefix=".work-", dir=self.root) as work:
                    work = Path(work)
                    payload = work / "payload"
                    payload.mkdir(mode=0o700)
                    report = self.capture(payload)
                    finished = now()
                    name = finished.strftime("%Y%m%dT%H%M%SZ-") + uuid.uuid4().hex[:8]
                    output = work / name
                    output.mkdir(mode=0o700)
                    archive = output / "snapshot.tar.gz"
                    files = file_manifest(payload)
                    with tarfile.open(archive, "w:gz") as tar:
                        for item in sorted(payload.iterdir()):
                            tar.add(item, arcname=item.name)
                    os.chmod(archive, 0o600)
                    with archive.open("rb") as stream:
                        os.fsync(stream.fileno())
                    manifest = {
                        "manager": MANAGER, "repository_id": self.repository()["id"], "name": name,
                        "created_at": finished.isoformat(), "started_at": started.isoformat(),
                        "archive_sha256": digest(archive), "archive_bytes": archive.stat().st_size,
                        "files": files, "database_report": report, "verified": True,
                    }
                    # Verify extraction, hashes, SQLite integrity, and attachments before publishing.
                    atomic_json(output / "manifest.json", manifest)
                    restored = work / "restored"
                    restored.mkdir(mode=0o700)
                    unpack(archive, restored)
                    if file_manifest(restored) != files or database_report(restored / "storage") != report:
                        raise ValueError("Backup restore verification failed")
                    snapshot = self.root / name
                    os.rename(output, snapshot)
                    atomic_json(self.root / "status.json", {
                        **state, "last_verified_snapshot": name, "last_verified_at": finished.isoformat(),
                    })
                    state.update(last_verified_snapshot=name, last_verified_at=finished.isoformat())
                    deleted = self.prune(snapshot, finished)
                    state.update(state="ok", last_success_at=now().isoformat(), last_error=None,
                                 archive_bytes=manifest["archive_bytes"], deleted_snapshots=deleted,
                                 retained_snapshots=len(self.snapshots()), verified_attachments=report["verified_attachments"])
                    atomic_json(self.root / "status.json", state)
                    LOG.info("Verified backup %s; %d bytes; %d attachments; pruned %d snapshots",
                             name, manifest["archive_bytes"], report["verified_attachments"], len(deleted))
                    return state
            except Exception as error:
                detail = str(error)
                if isinstance(error, subprocess.CalledProcessError):
                    detail = "Backup command failed: " + (error.stderr or "no error output")[-1500:]
                state.update(state="failed", last_error=detail, failed_at=now().isoformat())
                atomic_json(self.root / "status.json", state)
                LOG.error("Backup or pruning failed: %s", detail)
                if previous.get("state") != "failed":
                    notify_failure()
                raise


def main():
    os.umask(0o077)
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--service-directory", type=Path, default=Path(__file__).resolve().parent.parent)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("backup")
    commands.add_parser("status")
    commands.add_parser("list")
    for name in ("verify", "restore"):
        command = commands.add_parser(name)
        command.add_argument("snapshot", help="Managed snapshot directory name")
        if name == "restore":
            command.add_argument("--to", type=Path, required=True, help="NEW directory; never the live volume")
    args = parser.parse_args()
    manager = Backups(args.service_directory)
    logs = manager.service / "logs"
    logs.mkdir(mode=0o700, parents=True, exist_ok=True)
    handler = RotatingFileHandler(logs / "backup.log", maxBytes=2 * 1024 * 1024, backupCount=3)
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s"))
    LOG.addHandler(handler)
    LOG.setLevel(logging.INFO)
    try:
        if args.command == "backup":
            state = manager.backup()
            print("Verified backup:", state["last_verified_snapshot"], "retained:", state["retained_snapshots"])
        elif args.command == "status":
            state = read_json(manager.root / "status.json")
            last = dt.datetime.fromisoformat(state["last_success_at"]) if state.get("last_success_at") else None
            state["overdue"] = last is None or now() - last > dt.timedelta(hours=2)
            print(json.dumps(state, ensure_ascii=False, indent=2))
            return int(state["state"] != "ok" or state["overdue"])
        else:
            with manager.locked():
                if args.command == "list":
                    for snapshot in manager.snapshots():
                        manifest = manager.manifest(snapshot)
                        print(snapshot.name, manifest["created_at"], manifest["archive_bytes"])
                else:
                    with tempfile.TemporaryDirectory(prefix=".restore-", dir=manager.root) as restored:
                        manifest = manager.verify(manager.root / args.snapshot, Path(restored))
                        if args.command == "restore":
                            destination = args.to.expanduser().absolute()
                            if destination.exists() or destination.is_symlink():
                                raise ValueError("Restore destination already exists; refusing overwrite")
                            destination.mkdir(mode=0o700, parents=True, exist_ok=False)
                            for item in Path(restored).iterdir():
                                if item.is_dir():
                                    shutil.copytree(item, destination / item.name)
                                else:
                                    shutil.copyfile(item, destination / item.name)
                            print("Verified restore exported to", destination)
                            print("Live production storage was NOT changed.")
                        else:
                            print("Verified archive, files, all databases and attachments:", manifest["name"])
        return 0
    except Exception as error:
        LOG.error("Operation failed: %s", type(error).__name__)
        print("Backup operation failed. See", logs / "backup.log")
        return 1
    finally:
        LOG.removeHandler(handler)
        handler.close()


if __name__ == "__main__":
    raise SystemExit(main())
