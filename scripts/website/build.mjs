import { build, transform } from "esbuild";
import { readFile, writeFile, readdir, rm, mkdir } from "node:fs/promises";
import { createHash } from "node:crypto";
import { fileURLToPath } from "node:url";
import path from "node:path";

const root = fileURLToPath(new URL("../../", import.meta.url));
const source = new URL("./src/", import.meta.url);
const assets = path.join(root, "docs/assets");
await mkdir(assets, { recursive: true });
const hash = (content) => createHash("sha256").update(content).digest("hex").slice(0, 10);
const existing = await readdir(assets);
for (const name of existing) {
  if (/^(?:site|motion|onest-latin|noto-tajik)-[a-zA-Z0-9]+\.(?:js|css|woff2)$/.test(name)) await rm(path.join(assets, name));
}
const fontFiles = {};
for (const name of ["onest-latin", "noto-tajik"]) {
  const data = await readFile(new URL(`./fonts/${name}.woff2`, import.meta.url));
  const filename = `${name}-${hash(data)}.woff2`;
  await writeFile(path.join(assets, filename), data);
  fontFiles[name] = filename;
}
const cssSource = (await readFile(new URL("styles.css", source), "utf8"))
  .replaceAll("{{font}}", fontFiles["onest-latin"]).replaceAll("{{tajikfont}}", fontFiles["noto-tajik"]);
const css = (await transform(cssSource, { loader: "css", minify: true, target: ["safari17", "chrome120", "firefox120"] })).code;
const cssFile = `site-${hash(css)}.css`;
await writeFile(path.join(assets, cssFile), css);
const result = await build({
  absWorkingDir: root,
  entryPoints: [fileURLToPath(new URL("site.mjs", source))], outdir: assets,
  bundle: true, splitting: true, format: "esm", target: ["safari17", "chrome120", "firefox120"],
  entryNames: "site-[hash]", chunkNames: "motion-[hash]", minify: true,
  write: false, metafile: true, legalComments: "none",
});
for (const output of result.outputFiles) await writeFile(output.path, output.contents);
const jsFile = path.basename(Object.entries(result.metafile.outputs).find(([, output]) => output.entryPoint?.endsWith("src/site.mjs"))[0]);
const html = (await readFile(new URL("index.html", source), "utf8"))
  .replaceAll("{{style}}", `assets/${cssFile}`).replaceAll("{{script}}", `assets/${jsFile}`);
await writeFile(path.join(root, "docs/index.html"), html);
console.log(`Built ${cssFile}, ${jsFile}, ${result.outputFiles.length - 1} motion chunk, and two font subsets.`);
