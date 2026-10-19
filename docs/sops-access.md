# SOPS access boundaries

Inigo is permitted to decrypt Espanso secrets, backup credentials, and its own
integration credentials. Other application and user credentials remain restricted
to the existing administrator age identities.

## File boundaries

| File | Inigo access | Scope |
| --- | --- | --- |
| `secrets/secrets.yaml` | No | Other credentials; bootstrap age key |
| `secrets/inigo.yaml` | Yes | Inigo integration credentials |
| `secrets/backup-shared.yaml` | Yes | Hoth Borg and backup SMTP credentials |
| `secrets/ferrix-backups.yaml` | Yes | Ferrix Borg credentials |
| `secrets/mpfammatter-espanso.yaml` | Yes | Espanso entries |

SOPS encrypts access at file granularity. Moving only the Nix declarations or
changing `.sops.yaml` does not revoke access to an existing encrypted document.
The restricted document must be freshly encrypted with a new data key, excluding
Inigo's recipient. Merely updating recipient envelopes is insufficient when an
old data key remains recoverable from Git history.

The bootstrap `inigo/age-key` stays in the administrator-only file. SOPS-Nix
uses the administrator identity to install it with the existing runtime ownership
and permissions; Inigo does not need to decrypt the source file to use its own
installed identity. Runtime service credentials retain their existing ownership,
permissions, paths, and restart declarations.

The backup SMTP credentials are shared with Zulip. Those two fields intentionally
remain accessible for backup notifications; Zulip's other secrets do not.
The user-owned Pi token and calendar subscription URLs stay restricted: Inigo's
SilverBullet integration uses its separate dedicated token.

## Verification and activation

`python3 scripts/check-sops-access.py` checks public recipients and creation rules
without decrypting anything. The `sops-access` flake check also checks Nix routing.
The migration helper's real age/SOPS tests use disposable fixture identities;
production secret values must never appear in test output or assertion messages.

Before activation, an administrator must verify that their recovery identity can
still decrypt all three split files. From the repository root, this suppresses
all decrypted output:

```sh
(
  set -e
  export SOPS_AGE_KEY_FILE="$HOME/.config/sops/age/keys.txt"
  for file in secrets/secrets.yaml secrets/inigo.yaml secrets/backup-shared.yaml; do
    sops --decrypt "$file" >/dev/null
  done
  printf 'Administrator decryption checks passed.\n'
)
```

Do not paste key contents or decrypted output into chat. Keep the administrator
identity backed up independently, such as a verified 1Password Document.
Rebuild each affected host normally after publishing the changes; a successful
build is not evidence of activation or successful administrator decryption.

## Historical exposure remains

Previous Git versions and existing backup archives still contain documents that
Inigo's old identity can decrypt. This change cannot retroactively revoke access
to those documents or to previously obtained plaintext. Credentials excluded
from the new scope need separate service-specific rotation to eliminate that
historical exposure. Rotating the SOPS data key is not credential rotation.

Do not rewrite Git history, delete backup archives, or rotate live service
credentials as an implicit part of this migration. Coordinate those operations
separately, preserve recovery paths, and verify each affected service afterward.
