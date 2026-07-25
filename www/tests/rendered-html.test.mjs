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
  assert.match(html, /<title>Portal — Give your Mac a portal<\/title>/i);
  assert.match(html, /Portal is a delightful terminal app for Mac and iPhone/);
  assert.match(html, /finds your other devices automatically/);
  assert.match(html, /whenever the host Mac is awake/);
  assert.match(html, /Sessions stay put until you/);
  assert.match(html, /MAC \+ IPHONE/);
  assert.match(html, /One session\./);
  assert.match(html, /Just works\./);
  assert.match(html, /Every CLI\. Already fluent\./);
  assert.match(html, /Proper macOS blur/);
  assert.match(html, /Built by Mac/);
  assert.match(html, /creator of Homebrew/);
  assert.match(html, /Closed tabs come back\./);
  assert.match(html, /Linux is through the next portal\./);
  assert.match(html, /portal-icon\.png/);
  assert.match(html, /portal-electric/);
  assert.doesNotMatch(
    html,
    /codex-preview|Your site is taking shape|never leaves|still running/i,
  );
});
