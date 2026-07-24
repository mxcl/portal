import assert from "node:assert/strict";
import { readFile, readdir } from "node:fs/promises";
import test from "node:test";

test("server-renders the Portal landing page", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  const response = await worker.fetch(
    new Request("http://localhost/", { headers: { accept: "text/html" } }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
  const html = await response.text();

  assert.equal(response.status, 200);
  assert.match(html, /<title>Portal — The terminal that never leaves<\/title>/i);
  assert.match(html, /Sessions live until you/);
  assert.match(html, /One session\./);
  assert.match(html, /Just works\./);
  assert.match(html, /Every CLI\. Already fluent\./);
  assert.match(html, /Proper macOS blur/);
  assert.match(html, /Linux is through the next portal\./);
  assert.match(html, /portal-icon\.png/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape/);
});

test("server bundle does not evaluate the browser-only Draco loader", async () => {
  const assets = new URL("../dist/server/ssr/assets/", import.meta.url);
  const files = (await readdir(assets)).filter((file) => file.endsWith(".js"));
  const bundles = await Promise.all(
    files.map((file) => readFile(new URL(file, assets), "utf8")),
  );

  assert.doesNotMatch(bundles.join("\n"), /draco_decoder\.wasm/);
});
