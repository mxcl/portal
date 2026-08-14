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
  assert.match(
    html,
    /Portal is a delightful, opinionated terminal app for Mac and\s+iPhone/,
  );
  assert.match(html, /Start and resume sessions from any Mac or iPhone/);
  assert.match(html, /No Portal account/);
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
  assert.match(html, /Portal for Mac<\/th><td>Free forever/);
  assert.match(html, /Portal for iPhone<\/th><td>3 days free/);
  assert.match(html, /Monthly<\/th><td>\$4\.99\/mo/);
  assert.match(html, /Annual<\/th><td>\$39\.99\/yr/);
  assert.match(html, /Linux is through the next portal\./);
  assert.match(html, /portal-icon\.png/);
  assert.match(html, /portal-electric/);
  assert.match(html, /poster="\/portal-terminal-natural-loop\.jpg"/);
  assert.match(html, /https:\/\/github\.com\/mxcl\/portal\/releases\/latest/);
  assert.match(html, /https:\/\/apps\.apple\.com\/app\/id6800348258/);
  assert.doesNotMatch(
    html,
    /codex-preview|Your site is taking shape|never leaves|still running/i,
  );
});

test("server-renders the security model", async () => {
  const workerUrl = new URL("../dist/server/index.js", import.meta.url);
  workerUrl.searchParams.set("test", `${process.pid}-${Date.now()}`);
  const { default: worker } = await import(workerUrl.href);
  const response = await worker.fetch(
    new Request("http://localhost/security", {
      headers: { accept: "text/html" },
    }),
    { ASSETS: { fetch: async () => new Response("Not found", { status: 404 }) } },
    { waitUntil() {}, passThroughOnException() {} },
  );
  const html = await response.text();

  assert.equal(response.status, 200);
  assert.match(html, /<title>Security — Portal<\/title>/i);
  assert.match(html, /What leaves your Mac\./);
  assert.match(html, /Never leaves the Mac/);
  assert.match(html, /even when both devices are on the same Wi-Fi/i);
  assert.match(html, /relay never receives the encryption key/i);
  assert.match(html, /Temporary \/ memory only/i);
  assert.match(html, /Durable \/ stored on disk/i);
  assert.match(html, /there is no catalog history/i);
  assert.match(html, /does not persist or log live terminal frames/i);
  assert.match(html, /no per-device revocation/i);
});
