"""Check SOPS recipient boundaries using public metadata only; never decrypt."""
import argparse
import json
from pathlib import Path
import re
import sys

AGENT = "age1ekuda2zpkys5vhzucpkgehfj6cf3asqvlu9tn8m30uemdd4gtgpsd97dk2"
ALLOWED = {"inigo.yaml", "backup-shared.yaml", "ferrix-backups.yaml",
           "mpfammatter-espanso.yaml"}
AGENT_PATTERNS = {
    r"secrets/mpfammatter-espanso\.yaml$",
    r"secrets/(inigo|backup-shared|ferrix-backups)\.yaml$",
    r"secrets/(inigo|backup-shared|ferrix-backups|mpfammatter-espanso)\.yaml$",
}


def creation_rules(text):
    rules = []
    current = None
    for line in text.splitlines():
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        header = re.fullmatch(r"  - path_regex: (.+)", line)
        recipient = re.fullmatch(r"      (age1[a-z0-9]+),?", line)
        if header:
            current = (re.compile(header.group(1)), set())
            rules.append(current)
        elif recipient and current is not None:
            current[1].add(recipient.group(1))
        elif line not in ("creation_rules:", "    age: >-"):
            raise ValueError()
    if not rules or any(not recipients for _, recipients in rules):
        raise ValueError()
    return rules


def recipients(path):
    text = path.read_text()
    if text.lstrip().startswith("{"):
        metadata = json.loads(text)["sops"]
        result = {entry["recipient"] for entry in metadata["age"]}
    else:
        parts = re.split(r"(?m)^sops:\s*$", text)
        if len(parts) != 2:
            raise ValueError()
        result = set(re.findall(r"(?m)^\s*(?:- )?recipient: (age1[a-z0-9]+)\s*$", parts[1]))
    if not result:
        raise ValueError()
    return result


def check(root, agent):
    rules = creation_rules((root / ".sops.yaml").read_text())
    for pattern, identities in rules:
        if agent in identities and pattern.pattern not in AGENT_PATTERNS:
            raise ValueError()
        if not identities - {agent}:
            raise ValueError()
    expected = {root / "secrets" / name for name in ALLOWED | {"secrets.yaml"}}
    if not all(path.is_file() and not path.is_symlink() for path in expected):
        raise ValueError()
    files = set((root / "secrets").rglob("*.yaml"))
    files.update((root / "secrets").rglob("*.sops"))
    for path in files:
        if path.is_symlink():
            raise ValueError()
        relative = path.relative_to(root).as_posix()
        permitted = path.parent == root / "secrets" and path.name in ALLOWED
        actual = recipients(path)
        policy = next((ids for pattern, ids in rules if pattern.search(relative)), None)
        if policy is None or (agent in policy) != permitted:
            raise ValueError()
        if (agent in actual) != permitted or not actual - {agent}:
            raise ValueError()
        if actual != policy:
            raise ValueError()
    return len(files)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--root", type=Path, default=Path(__file__).resolve().parent.parent)
    parser.add_argument("--agent-recipient", default=AGENT)
    args = parser.parse_args()
    try:
        count = check(args.root.resolve(), args.agent_recipient)
    except Exception:
        print("SOPS access policy check failed; inspect public recipient metadata locally.",
              file=sys.stderr)
        return 1
    print(f"SOPS access policy verified for {count} encrypted files; no decryption performed.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
