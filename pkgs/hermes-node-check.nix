{ nodejs, runCommand }:

runCommand "hermes-node-runtime-check" { nativeBuildInputs = [ nodejs ]; } ''
  export HOME="$TMPDIR/home"
  mkdir -p "$HOME"

  # --version catches loader failures before any Hermes or npm code executes.
  node --version
  node -e '
    const assert = require("node:assert/strict");
    const { spawnSync } = require("node:child_process");
    assert.equal(6 * 7, 42);
    const child = spawnSync(process.execPath, ["--version"], { encoding: "utf8" });
    assert.equal(child.status, 0, child.stderr);
    assert.match(child.stdout, /^v[0-9]+\./);
  '
  npm --version
  npm config set offline true
  test "$(npm config get offline)" = true
  touch "$out"
''
