import assert from "node:assert/strict";
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
  assert.match(html, /Close the tab/);
  assert.match(html, /portal-icon\.png/);
  assert.doesNotMatch(html, /codex-preview|Your site is taking shape/);
});
