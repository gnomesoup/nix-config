{
  pkgs,
  ferrix,
  hoth,
}:
# Compatibility check name; both hosts now use the shared workflow.
import ./managed-backup-check.nix { inherit pkgs ferrix hoth; }
