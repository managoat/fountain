import { chromium } from "playwright";
import { createServer } from "node:http";
import { readFile } from "node:fs/promises";
import assert from "node:assert/strict";
const root = new URL("../../apps/fountain/priv/account_app/", import.meta.url);
const server = createServer(async (req, res) => {
  const name =
    new URL(req.url, "http://localhost").pathname.slice(1) || "index.html";
  if (!["index.html", "app.mjs", "auth.mjs", "style.css", "assets/tokens.css", "images/app-icon.png"].includes(name)) {
    res.writeHead(404).end();
    return;
  }
  res.setHeader(
    "Content-Type",
    name.endsWith(".png")
      ? "image/png"
      : name.endsWith(".mjs")
      ? "application/javascript"
      : name.endsWith(".css")
        ? "text/css"
        : "text/html",
  );
  res.end(await readFile(new URL(name, name.includes("/") ? new URL("../static/", root) : root)));
});
await new Promise((resolve) => server.listen(0, "127.0.0.1", resolve));
const base = `http://127.0.0.1:${server.address().port}`;
const browser = await chromium.launch({
  headless: true,
  executablePath: process.env.ACCOUNT_CHROMIUM,
});
const errors = [];
try {
  const context = await browser.newContext();
  const page = await context.newPage();
  page.on("pageerror", (error) => errors.push(error));
  const mutations = [];
  let keys = [
    {
      id: "key-1",
      name: "Existing key",
      prefix: "ftn_test",
      scopes: ["full"],
      expires_at: null,
    },
  ];
  await context.route("https://server.example/api/**", async (route) => {
    const req = route.request();
    const path = new URL(req.url()).pathname;
    assert.equal(req.headers().authorization, "Bearer test-token");
    assert.equal(req.headers().cookie, undefined);
    if (req.method() !== "GET")
      mutations.push({ path, method: req.method(), body: req.postDataJSON() });
    let data = { data: [] };
    if (path === "/api/auth/me")
      data = { id: "user-1", email: "owner@example.com", role: "admin" };
    if (path === "/api/auth/api-keys" && req.method() === "GET")
      data = { data: keys };
    if (path === "/api/auth/api-keys" && req.method() === "POST") {
      const name = req.postDataJSON().name;
      keys.push({
        id: "key-2",
        name,
        prefix: "ftn_new",
        scopes: ["full"],
        expires_at: null,
      });
      data = { id: "key-2", key: "ftn_once_only_secret" };
    }
    if (path === "/api/account/inference-credentials")
      data = { data: [{ provider: "openai_api_key", set: false }] };
    if (path === "/api/connections")
      data = {
        data: [
          { id: "connection-1", resource: "Example MCP", status: "active" },
        ],
      };
    if (path === "/api/oauth/clients")
      data = {
        data: [
          {
            id: "client-1",
            name: "My app",
            client_id: "client-public-id",
            redirect_uris: ["https://app.example/"],
            published: false,
          },
        ],
      };
    if (path === "/api/secret-bindings/presets")
      data = {
        data: [
          {
            id: "github",
            name: "GitHub",
            host: "api.github.com",
            auth_type: "bearer",
            suggested_key: "GH_TOKEN",
            usable: true,
          },
        ],
      };
    if (path === "/api/auth/password")
      data = {
        message: "Password changed",
        sessions_invalidated: true,
        api_keys_revoked: false,
      };
    if (req.method() === "DELETE" || path === "/api/oauth/revoke") {
      await route.fulfill({ status: 204 });
      return;
    }
    await route.fulfill({ json: data });
  });
  await context.addInitScript(() =>
    sessionStorage.setItem(
      "managoat-account.session",
      JSON.stringify({
        server: "https://server.example",
        token: "test-token",
        expires: Date.now() + 600000,
      }),
    ),
  );
  await page.goto(base + "/?open=api-keys");
  await page.getByText("Existing key", { exact: true }).waitFor();
  assert.ok(
    await page
      .getByText("owner@example.com · https://server.example", { exact: true })
      .isVisible(),
  );
  assert.equal(await page.locator("#console-link").getAttribute("href"), "https://server.example/dashboard");
  await page.emulateMedia({ colorScheme: "light" });
  const colors = () => page.evaluate(() => ({
    background: getComputedStyle(document.documentElement).backgroundColor,
    button: getComputedStyle(document.querySelector('#api-keys button[type="submit"]')).backgroundColor,
  }));
  assert.deepEqual(await colors(), {background: "rgb(249, 250, 251)", button: "rgb(11, 90, 204)"});
  await page.getByRole("button", { name: "Toggle dark mode" }).click();
  assert.deepEqual(await colors(), {background: "rgb(9, 9, 11)", button: "rgb(87, 150, 244)"});
  await page.screenshot({path: "/tmp/managoat-account-dark.png", fullPage: true});
  await page.reload();
  await page.getByText("Existing key", {exact: true}).waitFor();
  assert.equal(await page.locator("html").getAttribute("data-theme"), "dark");
  await page.getByRole("button", { name: "Toggle dark mode" }).click();
  assert.equal(await page.locator(".settings-content > section:visible").count(), 1);
  assert.equal(await page.locator("#settings > details").count(), 0);
  assert.equal(await page.locator('[data-section="api-keys"]').getAttribute("aria-current"), "page");
  await page.screenshot({path: "/tmp/account-settings-desktop.png", fullPage: true});
  const keysCard = page.locator("#api-keys");
  await keysCard.getByLabel("Key name").fill("<img src=x onerror=alert(1)>");
  await keysCard
    .getByRole("button", { name: "Create key", exact: true })
    .click();
  await page.getByText("ftn_once_only_secret", { exact: true }).waitFor();
  await page.getByRole("navigation", {name: "Account settings"}).getByRole("link", {name: "OAuth apps", exact: true}).click();
  assert.ok(await keysCard.isHidden());
  await page.goBack();
  await keysCard.waitFor({state: "visible"});
  await page.goForward();
  await page.locator("#oauth-apps").waitFor({state: "visible"});
  await page.getByRole("navigation", {name: "Account settings"}).getByRole("link", {name: "API keys", exact: true}).click();
  assert.ok(
    await page.getByText("ftn_once_only_secret", { exact: true }).isVisible(),
  );
  assert.equal(await page.locator("#settings img").count(), 0);
  await keysCard.getByRole("button", { name: "Dismiss", exact: true }).click();
  assert.equal(
    await page.getByText("ftn_once_only_secret", { exact: true }).count(),
    0,
  );
  assert.ok(
    await keysCard.getByRole("link", { name: /Manage admin keys/ }).isVisible(),
  );
  await page.getByRole("navigation", {name: "Account settings"}).getByRole("link", {name: "OAuth apps", exact: true}).click();
  await page
    .locator("#oauth-apps")
    .getByRole("button", { name: "Edit", exact: true })
    .click();
  assert.equal(
    await page.locator("#oauth-apps").getByLabel("App name").inputValue(),
    "My app",
  );
  await page.locator("#oauth-apps").getByLabel("App name").fill("Renamed");
  await page
    .locator("#oauth-apps")
    .getByRole("button", { name: "Save app" })
    .click();
  await page.getByText("App saved.", { exact: true }).waitFor();
  assert.deepEqual(
    mutations.find((m) => m.path === "/api/oauth/clients/client-1").body,
    { name: "Renamed", redirect_uris: ["https://app.example/"] },
  );
  await page.getByRole("navigation", {name: "Account settings"}).getByRole("link", {name: "Secret bindings", exact: true}).click();
  await page.getByLabel("Service preset").selectOption("github");
  assert.equal(
    await page.getByLabel("Secret name", { exact: true }).inputValue(),
    "GH_TOKEN",
  );
  await page
    .locator("#bindings")
    .getByRole("button", { name: "Create binding" })
    .click();
  await page.getByText("Binding saved.", { exact: true }).waitFor();
  assert.deepEqual(
    mutations.find((m) => m.path === "/api/secret-bindings").body,
    { key: "GH_TOKEN", host: "api.github.com", auth_type: "bearer" },
  );
  await page.getByRole("navigation", {name: "Account settings"}).getByRole("link", {name: "Security", exact: true}).click();
  await page
    .getByLabel("Current password", { exact: true })
    .fill("old-password");
  await page.getByLabel("New password", { exact: true }).fill("new-password");
  await page
    .getByRole("button", { name: "Change password", exact: true })
    .click();
  await page
    .getByText(
      "Password changed. Browser sessions were signed out; API keys remain active.",
      { exact: true },
    )
    .waitFor();
  assert.equal(
    await page.getByLabel("New password", { exact: true }).inputValue(),
    "",
  );
  const deletion = page.getByRole("button", { name: "Delete my account" });
  assert.ok(await deletion.isDisabled());
  await page.locator("#delete input").fill("wrong@example.com");
  assert.ok(await deletion.isDisabled());
  await page.locator("#delete input").fill("owner@example.com");
  assert.ok(await deletion.isEnabled());
  await page.setViewportSize({ width: 390, height: 844 });
  assert.ok(await page.getByRole("navigation", {name: "Account settings"}).isHidden());
  await page.getByLabel("Settings section", {exact: true}).selectOption("api-keys");
  assert.equal(await page.locator(".settings-content > section:visible").count(), 1);
  await keysCard.waitFor({state: "visible"});
  await page.screenshot({path: "/tmp/account-settings-mobile.png", fullPage: true});
  await page.getByLabel("Settings section", {exact: true}).selectOption("security");
  assert.equal(
    await page.evaluate(
      () => document.documentElement.scrollWidth > innerWidth,
    ),
    false,
  );
  await page.screenshot({
    path: "/tmp/managoat-account-mobile.png",
    fullPage: true,
  });
  await deletion.click();
  await page
    .getByText("Your account has been deleted.", { exact: true })
    .waitFor();
  assert.deepEqual(mutations.find((m) => m.path === "/api/account").body, {
    confirm: "owner@example.com",
  });
  assert.ok(
    await page
      .getByRole("button", { name: "Continue to sign in" })
      .isVisible(),
  );
  assert.equal(
    await page.evaluate(() =>
      sessionStorage.getItem("managoat-account.session"),
    ),
    null,
  );
  // Old links land on the new section without making the user expand anything.
  await page.goto(base + "/?open=delete");
  await page.locator("#delete input").waitFor({state: "visible"});
  assert.equal(await page.getByLabel("Settings section", {exact: true}).inputValue(), "security");
  await page.goto(base + "/?open=connections");
  await page.getByRole("heading", {name: "Connections", exact: true}).waitFor();
  assert.equal(await page.locator(".settings-content > section:visible").count(), 1);
  // A foreign server parameter must not send an existing session to that server.
  await page.goto(base + "/?server=https://other.example");
  await page
    .getByText(
      "This link points to another server. Sign in to that server to continue.",
      { exact: true },
    )
    .waitFor();
  assert.ok(await page.locator("#settings").isHidden());
  assert.equal(errors.length, 0, errors.map(String).join("\n"));
  console.log(
    "Account browser checks passed: CRUD, XSS escaping, key reveal, password, deletion, server isolation, section history/deep links, mobile navigation and layout.",
  );
} finally {
  await browser.close();
  await new Promise((resolve) => server.close(resolve));
}
