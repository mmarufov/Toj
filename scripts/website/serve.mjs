import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import { fileURLToPath } from "node:url";
import path from "node:path";
import { gzipSync } from "node:zlib";
const root = path.resolve(process.env.SITE_ROOT || fileURLToPath(new URL("../../docs", import.meta.url)));
const types = { ".html": "text/html; charset=utf-8", ".css": "text/css", ".js": "text/javascript", ".mjs": "text/javascript", ".webp": "image/webp", ".png": "image/png", ".woff2": "font/woff2", ".ttf": "font/ttf", ".md": "text/plain" };
createServer(async (request, response) => {
  try {
    const pathname = decodeURIComponent(new URL(request.url, "http://localhost").pathname);
    const file = path.resolve(root, `.${pathname.endsWith("/") ? `${pathname}index.html` : pathname}`);
    if (!file.startsWith(`${root}${path.sep}`)) throw new Error("outside root");
    const body = await readFile(file);
    const compressed = /gzip/.test(request.headers["accept-encoding"] || "") && /\.(?:html|css|js|mjs|ttf)$/.test(file);
    const output = compressed ? gzipSync(body) : body;
    response.writeHead(200, { "Content-Type": types[path.extname(file)] || "application/octet-stream", "Cache-Control": "no-store", "Content-Length": output.length, ...(compressed ? { "Content-Encoding": "gzip" } : {}) });
    response.end(request.method === "HEAD" ? undefined : output);
  } catch { response.writeHead(404); response.end("Not found"); }
}).listen(Number(process.env.PORT || 4173), "127.0.0.1", () => console.log(`Toj website: http://127.0.0.1:${process.env.PORT || 4173}`));
