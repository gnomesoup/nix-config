#!/usr/bin/env python3
"""Split SOPS access with fresh data keys, without writing or logging plaintext.

Outputs are JSON (valid YAML), encrypted for every original public age recipient;
only the restricted main file drops the agent recipient. No history is rewritten
and no credential is rotated. Run --dry-run first. Requires sops and age-keygen.
"""
import argparse
import json
import os
from pathlib import Path
import re
import stat
import subprocess
import sys
import tempfile

AGENT = "age1ekuda2zpkys5vhzucpkgehfj6cf3asqvlu9tn8m30uemdd4gtgpsd97dk2"
INTEGRATIONS = frozenset((
    "inigo/ssh_key", "inigo/home-assistant-token", "inigo/protonmail-bridge-email",
    "inigo/protonmail-bridge-username", "inigo/protonmail-bridge-password",
    "inigo/silverbullet-api-token", "inigo/github-deploy-key", "hermes/api-server-key",
    "hermes/dashboard-password", "hermes/dashboard-secret",
))
BACKUPS = frozenset(("borg/borg_passphrase", "borg/endor/borgbase_path", "zulip/email_username", "zulip/email_password"))
RECIPIENT = re.compile(r"age1[023456789acdefghjklmnpqrstuvwxyz]{58}")
ENCRYPTED = re.compile(r"ENC\[AES256_GCM,data:[A-Za-z0-9+/=]*,iv:[A-Za-z0-9+/=]+,tag:[A-Za-z0-9+/=]+,type:[a-z]+\]")
BACKENDS = frozenset(("kms", "gcp_kms", "azure_kv", "hc_vault", "hckms", "pgp"))
METADATA = BACKENDS | {"age", "lastmodified", "mac", "unencrypted_suffix", "encrypted_suffix",
                       "unencrypted_regex", "encrypted_regex", "version", "mac_only_encrypted",
                       "unencrypted_comment_regex", "encrypted_comment_regex"}


class SafeParser(argparse.ArgumentParser):
    def error(self, message):
        # argparse's default error includes raw argv, which may be sensitive.
        raise Refused()


class Refused(Exception):
    """Deliberately carries no diagnostic data."""


def require(condition):
    if not condition:
        raise Refused()


def unique_object(pairs):
    result = {}
    for key, value in pairs:
        require(key not in result)
        result[key] = value
    return result


def load_json(data):
    return json.loads(data, object_pairs_hook=unique_object,
                      parse_constant=lambda _: (_ for _ in ()).throw(Refused()))


def run(arguments, env, data=None, denied=False):
    result = subprocess.run(arguments, input=data, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                            env=env, timeout=120, check=False)
    if denied:
        require(result.returncode != 0)
        return b""
    require(result.returncode == 0)
    return result.stdout


def public_recipients(ciphertext):
    """Read only public SOPS metadata, using JSON or strict emitted-YAML syntax.

    Reject unknown metadata, key groups, and non-age backends. This is not a
    general YAML parser: unfamiliar metadata layouts are intentionally refused.
    """
    if ciphertext.lstrip().startswith(b"{"):
        document = load_json(ciphertext)
        require(isinstance(document, dict) and isinstance(document.get("sops"), dict))
        meta = document["sops"]
        require(set(meta) <= METADATA)
        require(all(not meta.get(name) for name in BACKENDS))
        entries = meta.get("age")
        require(isinstance(entries, list) and entries)
        recipients = []
        for entry in entries:
            require(isinstance(entry, dict) and set(entry) == {"recipient", "enc"})
            require(isinstance(entry["enc"], str) and entry["enc"].startswith("-----BEGIN AGE ENCRYPTED FILE-----"))
            recipients.append(entry["recipient"])
    else:
        text = ciphertext.decode("utf-8")
        headers = list(re.finditer(r"(?m)^sops:[ \t]*$", text))
        require(len(headers) == 1)
        tail = text[headers[0].end():]
        lines = [line for line in tail.splitlines() if line.strip()]
        require(lines and all(line.startswith(" ") for line in lines))
        indent = min(len(line) - len(line.lstrip(" ")) for line in lines)
        fields = {}
        for line in lines:
            if len(line) - len(line.lstrip(" ")) == indent:
                match = re.fullmatch(r" +([a-z_]+):(?:[ \t]*(.*))?", line)
                if match is None:
                    raise Refused()
                name, value = match.groups()
                require(name in METADATA and name not in fields)
                fields[name] = value
        require("age" in fields and fields["age"] == "")
        require(all(fields.get(name, "[]") in ("[]", "null", "") for name in BACKENDS))
        # Empty backend fields may not contain indented children.
        for name in BACKENDS:
            require(not re.search(rf"(?m)^ {{{indent}}}{name}:[ \t]*\n +\S", tail))
        recipients = re.findall(r"(?m)^ +(?:- )?recipient: (age1[0-9a-z]+)[ \t]*$", tail)
        require(len(re.findall(r"\brecipient:", tail)) == len(recipients))
    require(recipients and all(isinstance(r, str) and RECIPIENT.fullmatch(r) for r in recipients))
    require(len(set(recipients)) == len(recipients))
    return set(recipients)


def flatten(tree, prefix="", result=None):
    if result is None:
        result = {}
    require(isinstance(tree, dict) and tree)
    for key, value in tree.items():
        require(isinstance(key, str) and key and all(part not in ("", ".", "..") for part in key.split("/")))
        path = prefix + "/" + key if prefix else key
        if isinstance(value, dict) and value:
            flatten(value, path, result)
        else:
            require(path not in result)
            result[path] = value
    return result


def select(tree, allowed, prefix=""):
    result = {}
    for key, value in tree.items():
        path = prefix + "/" + key if prefix else key
        if isinstance(value, dict) and value:
            child = select(value, allowed, path)
            if child:
                result[key] = child
        elif path in allowed:
            result[key] = value
    return result


def encrypted_values(value):
    if isinstance(value, dict):
        return all(encrypted_values(child) for child in value.values())
    if isinstance(value, list):
        return all(encrypted_values(child) for child in value)
    return isinstance(value, str) and ENCRYPTED.fullmatch(value) is not None


def validate_ciphertext(ciphertext, recipients, tree):
    require(public_recipients(ciphertext) == recipients)
    document = load_json(ciphertext)
    meta = document.pop("sops")
    require(isinstance(meta.get("mac"), str) and ENCRYPTED.fullmatch(meta["mac"]) is not None)
    require(meta.get("encrypted_regex") == ".*")
    require(encrypted_values(document))
    require(set(flatten(document)) == set(flatten(tree)))


def safe_path(raw):
    path = Path(os.path.abspath(raw))
    require(path.parent.is_dir())
    # No symlinks in any existing path component, including absent output names.
    require(not any(parent.is_symlink() for parent in (path, *path.parents)))
    return path


def preflight(source, integration, backup):
    require(len({source, integration, backup}) == 3)
    source_stat = source.stat()
    require(stat.S_ISREG(source_stat.st_mode) and source_stat.st_nlink == 1)
    for path in (integration, backup):
        require(not os.path.lexists(path))
        require(os.access(path.parent, os.W_OK | os.X_OK))
    require(os.access(source.parent, os.W_OK | os.X_OK))
    return source_stat


def same_source(source, snapshot, info):
    current = source.lstat()
    require(stat.S_ISREG(current.st_mode) and current.st_ino == info.st_ino and current.st_dev == info.st_dev)
    require(current.st_size == info.st_size and current.st_mtime_ns == info.st_mtime_ns)
    require(source.read_bytes() == snapshot)


def stage(path, ciphertext):
    fd, name = tempfile.mkstemp(prefix=".sops-split-", dir=path.parent)
    temporary = Path(name)
    try:
        with os.fdopen(fd, "wb") as stream:
            os.fchmod(stream.fileno(), 0o600)
            stream.write(ciphertext)
            stream.flush()
            os.fsync(stream.fileno())
    except BaseException:
        temporary.unlink(missing_ok=True)
        raise
    return temporary


def commit(source, outputs, snapshot, info):
    """Stage ciphertext only; use exclusive links for new outputs, main last.

    Rollback only removes files whose inode we created. No multi-file rename can
    be crash-atomic: keep backups and do not run concurrent writers/migrations.
    Ordinary write failures restore the original ciphertext without plaintext.
    """
    staged = []
    owned = []
    replaced = False
    rollback = None
    try:
        same_source(source, snapshot, info)
        # Prepare restoration before any destination changes: rollback must not
        # require fresh writes after a disk-full or flush failure.
        rollback = stage(source, snapshot)
        for path, ciphertext in outputs:
            staged.append((path, stage(path, ciphertext), ciphertext))
        for path, temporary, _ in staged:
            if path != source:
                os.link(temporary, path)  # Atomic no-clobber, even with a racing creator.
                owned.append((path, temporary.stat().st_ino))
        same_source(source, snapshot, info)
        main = next(temporary for path, temporary, _ in staged if path == source)
        os.replace(main, source)
        replaced = True
        for path, _, ciphertext in staged:
            require(path.read_bytes() == ciphertext and stat.S_IMODE(path.stat().st_mode) == 0o600)
        for parent in {path.parent for path, _ in outputs}:
            fd = os.open(parent, os.O_RDONLY | os.O_DIRECTORY)
            try:
                os.fsync(fd)
            finally:
                os.close(fd)
    except BaseException:
        try:
            if replaced and rollback is not None:
                os.replace(rollback, source)
        finally:
            for path, inode in owned:
                if path.exists() and path.lstat().st_ino == inode:
                    path.unlink()
        raise
    finally:
        if rollback is not None:
            rollback.unlink(missing_ok=True)
        for _, temporary, _ in staged:
            temporary.unlink(missing_ok=True)


def main():
    parser = SafeParser(description=__doc__)
    parser.add_argument("--source", default="secrets/secrets.yaml")
    parser.add_argument("--integration-output", default="secrets/inigo.yaml")
    parser.add_argument("--backup-output", default="secrets/backup-shared.yaml")
    parser.add_argument("--agent-recipient", default=AGENT)
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    require(RECIPIENT.fullmatch(args.agent_recipient) is not None)
    paths = tuple(safe_path(raw) for raw in (args.source, args.integration_output, args.backup_output))
    source, integration, backup = paths
    info = preflight(*paths)
    snapshot = source.read_bytes()
    recipients = public_recipients(snapshot)
    humans = recipients - {args.agent_recipient}
    require(args.agent_recipient in recipients and humans)
    keyfile = os.environ.get("SOPS_AGE_KEY_FILE", "")
    require(keyfile and Path(keyfile).is_file())
    # Disable ambient age/GPG/SSH identity discovery and all SOPS backend envs.
    env = {key: os.environ[key] for key in ("PATH", "TMPDIR", "LANG", "LC_ALL") if key in os.environ}
    env.update(HOME="/nonexistent", XDG_CONFIG_HOME="/nonexistent", GNUPGHOME="/nonexistent",
               SOPS_AGE_KEY_FILE=keyfile)
    public = run(["age-keygen", "-y", keyfile], env).decode().strip()
    require(public == args.agent_recipient)
    input_type = "json" if snapshot.lstrip().startswith(b"{") else "yaml"
    decrypt = ["sops", "decrypt", "--input-type", input_type, "--output-type", "json"]
    tree = load_json(run(decrypt, env, snapshot))
    require(isinstance(tree, dict) and "sops" not in tree)
    flat = flatten(tree)
    require(INTEGRATIONS | BACKUPS <= set(flat))
    restricted = set(flat) - INTEGRATIONS - BACKUPS
    require(restricted and "inigo/age-key" in restricted)
    partitions = ((source, select(tree, restricted), humans),
                  (integration, select(tree, INTEGRATIONS), recipients),
                  (backup, select(tree, BACKUPS), recipients))
    if args.dry_run:
        print(json.dumps({"dry_run": True, "counts": [len(restricted), len(INTEGRATIONS), len(BACKUPS)],
                          "restricted_recipients": sorted(humans), "shared_recipients": sorted(recipients),
                          "integration_keys": sorted(INTEGRATIONS), "backup_keys": sorted(BACKUPS)}, sort_keys=True))
        return
    outputs = []
    for path, subtree, public_set in partitions:
        ciphertext = run(["sops", "--config", "/dev/null", "encrypt", "--input-type", "json", "--output-type", "json",
                          "--filename-override", "split.json", "--age", ",".join(sorted(public_set)),
                          "--encrypted-regex", ".*"], env, json.dumps(subtree, allow_nan=False).encode())
        validate_ciphertext(ciphertext, public_set, subtree)
        # Force YAML decoding: emitted JSON must work with sops-nix's YAML store.
        verification = ["sops", "decrypt", "--input-type", "yaml", "--output-type", "json"]
        if path != source:
            require(load_json(run(verification, env, ciphertext)) == subtree)
        else:
            run(verification, env, ciphertext, denied=True)
        outputs.append((path, ciphertext))
    preflight(*paths)
    same_source(source, snapshot, info)
    commit(source, outputs, snapshot, info)
    print(json.dumps({"counts": [len(restricted), len(INTEGRATIONS), len(BACKUPS)],
                      "agent_main_access": False, "agent_integration_access": True,
                      "agent_backup_access": True}, sort_keys=True))


if __name__ == "__main__":
    try:
        main()
    except SystemExit:
        raise
    except BaseException:
        # Never render an exception, argv, subprocess stderr, or decrypted data.
        print("SOPS split failed; diagnostic output suppressed.", file=sys.stderr)
        sys.exit(1)
