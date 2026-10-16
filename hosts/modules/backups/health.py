"""Backup freshness and notifications, without backup data or logs in email."""
import argparse
from datetime import datetime
from email.message import EmailMessage
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import smtplib
import socket
import ssl
import subprocess
import sys
import tempfile
import time


def completed_archive(config, name):
    prefix = config["archive_prefix"]
    return (isinstance(name, str) and name.startswith(prefix)
            and len(name) > len(prefix)
            and not re.search(r"\.checkpoint(?:\.\d+)?$", name))


def parse_timestamp(value):
    """Borg's naive ISO timestamps deliberately use the host's local timezone."""
    try:
        return datetime.fromisoformat(value).timestamp()
    except (TypeError, ValueError, OverflowError, OSError):
        return None


def timestamp_problem(config, latest, now):
    if latest is None or not math.isfinite(latest):
        return "Completed backup timestamp is missing or invalid."
    if latest > now + 600:
        return "Completed backup timestamp is in the future."
    if now - latest > config.get("max_age_seconds", 129600):
        return "Completed backup is stale."
    return None


def archive_problem(config, repository, now):
    archives = [a for a in repository["archives"]
                if completed_archive(config, a.get("name"))]
    if not archives:
        return "No completed backup archives are recorded."
    timestamps = [parse_timestamp(a.get("time")) for a in archives]
    if any(t is None or not math.isfinite(t) for t in timestamps):
        return "Completed backup timestamp is missing or invalid."
    return timestamp_problem(config, max(t for t in timestamps if t is not None), now)


def local_problem(config, now):
    try:
        marker = json.loads(Path(config["status_file"]).read_text())
    except (OSError, ValueError, UnicodeError):
        return "No valid completed backup marker is recorded."
    if not isinstance(marker, dict):
        return "Completed backup marker is invalid."
    for field in ("source", "job", "repository", "archive"):
        if not isinstance(marker.get(field), str) or not marker[field]:
            return "Completed backup marker is incomplete."
    for setting, field in (("source_id", "source"), ("repository_id", "repository")):
        if setting in config and config[setting] != marker[field]:
            return "Completed backup marker belongs to a different source or repository."
    namespace = dict(config, archive_prefix=config.get("archive_prefix", marker["source"] + "-complete-"))
    if not completed_archive(namespace, marker["archive"]):
        return "Completed backup marker has an invalid archive namespace."
    completed_at = marker.get("completed_at")
    try:
        latest = (float(completed_at) if isinstance(completed_at, (int, float)) and not isinstance(completed_at, bool)
                  else parse_timestamp(completed_at))
    except OverflowError:
        latest = None
    return timestamp_problem(config, latest, now)


def send_email(config, message):
    """Read credentials at delivery time only; never log server replies or secrets."""
    username = Path(config["username_file"]).read_text().rstrip("\r\n")
    password = Path(config["password_file"]).read_text().rstrip("\r\n")
    mail = EmailMessage()
    mail["From"] = username
    mail["To"] = config["recipient"]
    mail["Subject"] = f"[backups] Backup alert from {socket.gethostname()}"
    mail.set_content(message + "\n\nNo backup contents, credentials, or logs are included.\n")
    with smtplib.SMTP(config["host"], config["port"], timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        smtp.login(username, password)
        if smtp.send_message(mail):
            raise RuntimeError("Backup alert recipient was rejected")


def alert_path(config, key):
    # JSON framing avoids ambiguous concatenations, hashing avoids unsafe filenames.
    context = [socket.gethostname(), config.get("source_id"),
               config.get("repository_id"), config.get("archive_prefix"), key]
    digest = hashlib.sha256(json.dumps(context, ensure_ascii=True).encode()).hexdigest()
    return Path(config["alert_directory"]) / (digest + ".alert")


def deliver(config, key, message, now=None, force=False):
    now = time.time() if now is None else now
    stamp = alert_path(config, key)
    stamp.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    # Serialize read/send/write, so parallel checks cannot bypass the daily limit.
    descriptor = os.open(stamp.with_suffix(".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        try:
            previous = float(stamp.read_text())
        except (OSError, ValueError):
            previous = None
        if not force and previous is not None and math.isfinite(previous) and 0 <= now - previous < 86400:
            return
        send_email(config["smtp"], message)
        temporary = None
        try:
            with tempfile.NamedTemporaryFile(mode="w", dir=stamp.parent, prefix=".alert-", delete=False) as stream:
                temporary = Path(stream.name)
                stream.write(str(now) + "\n")
            temporary.replace(stamp)
        finally:
            if temporary is not None:
                temporary.unlink(missing_ok=True)


class HealthError(Exception):
    """Only static, safe-to-print operational diagnostics belong in this exception."""


def validate_config(config, action):
    if not isinstance(config, dict):
        raise HealthError("Backup health configuration must be a JSON object.")
    if not isinstance(config.get("alert_directory"), str) or not config["alert_directory"]:
        raise HealthError("Backup health alert_directory is required.")
    if not isinstance(config.get("smtp"), dict):
        raise HealthError("Backup health smtp configuration is required.")
    for field in ("source_id", "repository_id"):
        if field in config and (not isinstance(config[field], str) or not config[field]):
            raise HealthError("Backup health identity must be a nonempty string.")
    if action in ("failed", "test"):
        return
    age = config.get("max_age_seconds", 129600)
    if isinstance(age, bool) or not isinstance(age, (int, float)) or not math.isfinite(age) or age <= 0:
        raise HealthError("Backup health max_age_seconds must be finite and positive.")
    if not (action == "check-local" and "archive_prefix" not in config):
        prefix = config.get("archive_prefix")
        if not isinstance(prefix, str) or not re.fullmatch(r"[A-Za-z0-9_.-]+-complete-", prefix):
            raise HealthError("Backup health archive_prefix must select a completed source namespace.")
        if "source_id" in config and prefix != config["source_id"] + "-complete-":
            raise HealthError("Backup health archive_prefix does not match source_id.")
    if action == "check-local":
        if not isinstance(config.get("status_file"), str) or not config["status_file"]:
            raise HealthError("Backup health status_file is required.")
    else:
        command = config.get("borg_command")
        if not isinstance(command, list) or not command or any(not isinstance(part, str) or not part for part in command):
            raise HealthError("Backup health borg_command must be a nonempty argument list.")


def repository_problem(config, now):
    try:
        result = subprocess.run(
            config["borg_command"] + ["list", "--json", "--glob-archives", config["archive_prefix"] + "*", "--last", "1"],
            check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True, timeout=900,
        )
    except subprocess.TimeoutExpired:
        raise HealthError("Borg repository listing timed out after 900 seconds.") from None
    except subprocess.CalledProcessError as error:
        raise HealthError(f"Borg repository listing failed (exit status {error.returncode}).") from None
    except OSError:
        raise HealthError("Borg repository listing could not start.") from None
    try:
        repository = json.loads(result.stdout)
    except (ValueError, TypeError):
        raise HealthError("Borg repository listing returned invalid JSON.") from None
    if (not isinstance(repository, dict) or not isinstance(repository.get("archives"), list)
            or any(not isinstance(a, dict) or not isinstance(a.get("name"), str) for a in repository["archives"])):
        raise HealthError("Borg repository listing returned an invalid archive structure.")
    return archive_problem(config, repository, now)


def reset_alert(config, key):
    stamp = alert_path(config, key)
    if not stamp.parent.exists():
        return
    descriptor = os.open(stamp.with_suffix(".lock"), os.O_CREAT | os.O_RDWR, 0o600)
    with os.fdopen(descriptor, "a") as lock:
        fcntl.flock(lock, fcntl.LOCK_EX)
        stamp.unlink(missing_ok=True)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("action", choices=("check-repository", "require-fresh", "check-local", "failed", "test"))
    parser.add_argument("identifier", nargs="?", default="backup")
    arguments = parser.parse_args(argv)
    try:
        try:
            config = json.loads(arguments.config.read_text())
        except (OSError, ValueError, UnicodeError):
            raise HealthError("Backup health configuration could not be read as JSON.") from None
        validate_config(config, arguments.action)
        now = time.time()
        action = arguments.action
        context = "repository" if action in ("check-repository", "require-fresh") else action
        key = context + ":" + arguments.identifier
        label = json.dumps(arguments.identifier, ensure_ascii=True)
        if action == "failed":
            problem = f"Backup unit {label} failed on {socket.gethostname()}."
        elif action == "test":
            problem = "This is a requested backup alert delivery test."
        elif action == "check-local":
            problem = local_problem(config, now)
        else:
            problem = repository_problem(config, now)
        if problem is None:
            reset_alert(config, key)
            return 0
        message = (f"Backup context: {label}\n"
                   f"Source: {json.dumps(config.get('source_id', socket.gethostname()))}\n"
                   f"Repository: {json.dumps(config.get('repository_id', 'unspecified'))}\n\n{problem}")
        try:
            deliver(config, key, message, now=now, force=action == "test")
        except (OSError, RuntimeError, ValueError, KeyError, smtplib.SMTPException):
            raise HealthError("Backup alert delivery or throttle update failed.") from None
        if action == "require-fresh":
            print("Backup freshness requirement failed: " + problem, file=sys.stderr)
            return 1
        print("Backup health alert handled.")
        return 0
    except HealthError as error:
        print(str(error), file=sys.stderr)
        return 1
    except (OSError, ValueError, TypeError, KeyError, OverflowError):
        print("Backup health check failed due to invalid state or configuration.", file=sys.stderr)
        return 1


if __name__ == "__main__":
    os.umask(0o077)
    sys.exit(main())
