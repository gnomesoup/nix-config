{ fetchPnpmDeps, lib }:
args:
fetchPnpmDeps (
  args
  // lib.optionalAttrs ((args.pname or "") == "hermes-agent" && (args.fetcherVersion or null) == 4) {
    # Format 4 can archive host-dependent pnpm 12 virtual-store materialisations.
    # Format 5 excludes those links; refresh this hash when Hermes' lock changes.
    fetcherVersion = 5;
    hash = "sha256-60Df2mDvJkKIjmpiOmVsfPNyl287WtJvR8AE4dprMN0=";
  }
)
