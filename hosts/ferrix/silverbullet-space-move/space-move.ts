import { asset, editor } from "@silverbulletmd/silverbullet/syscalls";
import { panelStyles } from "@silverbulletmd/silverbullet/ui";

export async function openMover(): Promise<void> {
  await editor.save();
  const path = await editor.getCurrentPath();
  if (!path?.endsWith(".md"))
    throw new Error("Open a Markdown page before moving a collection.");
  const text = await editor.getText();
  const [html, runtime, theme] = await Promise.all([
    asset.readAsset("silverbullet-space-move", "assets/panel.html"),
    asset.readAsset("silverbullet-space-move", "assets/runtime.js"),
    panelStyles(),
  ]);
  const boot = JSON.stringify({ path, text })
    .replace(/\u2028/g, "\\u2028")
    .replace(/\u2029/g, "\\u2029");
  await editor.showPanel(
    "modal",
    100,
    `<style>${theme}</style>${html}`,
    `globalThis.spaceMoveBoot = ${boot};\n${runtime}`,
  );
}
