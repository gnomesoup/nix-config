"""Backup freshness checks; never include backup contents or credentials in alerts."""

import argparse
import json
import math
import os
import re
import smtplib
import socket
import ssl
import subprocess
import time
from datetime import datetime
from email.message import EmailMessage
from pathlib import Path


def state_file(state, key):
    if not re.fullmatch(r"[A-Za-z0-9_.-]+", key):
        raise ValueError("Invalid backup status identifier")
    return Path(state) / key


def read_timestamp(path):
    try:
        return float(path.read_text())
    except (FileNotFoundError, ValueError):
        return None


def write_timestamp(path, now):
    path.parent.mkdir(parents=True, exist_ok=True, mode=0o700)
    temporary = path.with_suffix(".partial")
    temporary.write_text(str(now) + "\n")
    temporary.chmod(0o600)
    temporary.replace(path)


def record_success(state, destination, now=None):
    write_timestamp(state_file(state, destination + ".success"), time.time() if now is None else now)


def timestamp_problem(latest, now):
    if latest is None:
        return "There is no successful Ferrix backup recorded."
    if not math.isfinite(latest):
        return "The latest Ferrix backup has an invalid timestamp."
    if latest > now + 600:
        return "The latest Ferrix archive has a timestamp in the future."
    if now - latest > 36 * 3600:
        return "The latest Ferrix backup is older than 36 hours."
    return None


def local_problem(state, destination, now=None):
    return timestamp_problem(
        read_timestamp(state_file(state, destination + ".success")),
        time.time() if now is None else now,
    )


def archive_problem(repository, now=None):
    now = time.time() if now is None else now
    archives = [a for a in repository["archives"] if a["name"].startswith("ferrix-")]
    if not archives:
        return "There are no Ferrix archives in this repository."
    latest = max(datetime.fromisoformat(a["time"]).timestamp() for a in archives)
    return timestamp_problem(latest, now)


def send_email(config, message):
    username = Path(config["username_file"]).read_text().rstrip("\r\n")
    password = Path(config["password_file"]).read_text().rstrip("\r\n")
    mail = EmailMessage()
    mail["From"] = username
    mail["To"] = config["recipient"]
    mail["Subject"] = f"[backups] Ferrix backup alert from {socket.gethostname()}"
    mail.set_content(message + "\n\nNo backup contents or logs are included in this message.\n")
    with smtplib.SMTP(config["smtp_host"], config["smtp_port"], timeout=30) as smtp:
        smtp.ehlo()
        smtp.starttls(context=ssl.create_default_context())
        smtp.ehlo()
        smtp.login(username, password)
        if smtp.send_message(mail):
            raise RuntimeError("The backup alert recipient was rejected")


def deliver(config, key, message, now=None):
    now = time.time() if now is None else now
    stamp = state_file(config["state_dir"], key + ".alert")
    previous = read_timestamp(stamp)
    if previous is not None and 0 <= now - previous < 86400:
        return
    send_email(config, message)
    write_timestamp(stamp, now)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", type=Path, required=True)
    parser.add_argument("action", choices=["record", "check-local", "check-repository", "require-fresh", "failed", "test"])
    parser.add_argument("destination", nargs="?", default="test")
    arguments = parser.parse_args()
    config = json.loads(arguments.config.read_text())
    state = Path(config["state_dir"])
    action = arguments.action
    destination = arguments.destination
    if action == "record":
        record_success(state, destination)
        return
    if action == "failed":
        problem = f"Backup unit {destination}.service failed on {socket.gethostname()}."
    elif action == "test":
        problem = "This is a requested Ferrix backup alert delivery test."
    elif action == "check-local":
        problem = local_problem(state, destination)
    else:
        result = subprocess.run(
            [os.environ.get("FERRIX_BORG_COMMAND", "borg"), "list", "--json", "--glob-archives", "ferrix-*", "--last", "1"],
            check=True, stdout=subprocess.PIPE, text=True, timeout=900,
        )
        problem = archive_problem(json.loads(result.stdout))
    key = action + "-" + destination
    if problem is not None:
        deliver(config, key, f"Destination/unit: {destination}\n\n{problem}")
        print(f"Backup health alert handled: {destination}")
        if action == "require-fresh":
            raise RuntimeError(problem)
    else:
        state_file(state, key + ".alert").unlink(missing_ok=True)


if __name__ == "__main__":
    os.umask(0o077)
    main()
