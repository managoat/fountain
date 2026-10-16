import { createAuth, serverURL } from "./auth.mjs";
const auth = createAuth();
const $ = (selector) => document.querySelector(selector);
const settings = $("#settings");
const query = new URLSearchParams(location.search);
let section = query.get("open") || "";
function el(tag, text, attrs = {}) {
  const node = document.createElement(tag);
  if (text !== null) node.textContent = text;
  for (const [key, value] of Object.entries(attrs))
    node.setAttribute(key, value);
  return node;
}
function notice(message, error = false) {
  const node = $("#notice");
  node.textContent = message;
  node.hidden = false;
  node.className = error ? "error" : "";
  node.setAttribute("role", error ? "alert" : "status");
}
async function run(button, action) {
  button.disabled = true;
  try {
    await action();
  } catch (error) {
    notice(error.message, true);
    if (!auth.session()) signedOut();
  } finally {
    button.disabled = false;
  }
}
function button(text, action, style = "secondary") {
  const node = el("button", text, { type: "button", class: style });
  node.addEventListener("click", () => run(node, action));
  return node;
}
function field(name, label, type = "text", value = "", required = true) {
  const wrapper = el("label", label);
  const input = el(type === "textarea" ? "textarea" : "input", null, { name });
  if (type !== "textarea") input.type = type;
  input.value = value;
  input.required = required;
  if (type === "password") input.autocomplete = "off";
  wrapper.append(input);
  return wrapper;
}
function form(fields, title, action) {
  const node = el("form", null),
    submit = el("button", title, { type: "submit" });
  node.append(...fields, submit);
  node.addEventListener("submit", (event) => {
    event.preventDefault();
    run(submit, () => action(Object.fromEntries(new FormData(node)), node));
  });
  return node;
}
function card(id, title, description) {
  const node = el("details", null, { id }),
    summary = el("summary", title);
  summary.append(el("small", description));
  node.append(summary);
  settings.append(node);
  node.open = section === id;
  return node;
}
function row(title, detail, ...actions) {
  const node = el("div", null, { class: "row" }),
    label = el("div", null),
    controls = el("div", null, { class: "actions" });
  label.append(el("strong", title), el("p", detail));
  controls.append(...actions);
  node.append(label, controls);
  return node;
}
function empty(list, text) {
  if (!list.childElementCount) list.append(el("p", text, { class: "empty" }));
}
const api = (...args) => auth.request(...args);
const id = (value) => encodeURIComponent(value);
const lines = (value) =>
  value
    .split("\n")
    .map((line) => line.trim())
    .filter(Boolean);
function pairs(value) {
  return Object.fromEntries(
    lines(value).map((line) => {
      const split = line.indexOf("=");
      if (split < 1) throw new Error("Use one name=value pair per line.");
      return [line.slice(0, split).trim(), line.slice(split + 1).trim()];
    }),
  );
}
function confirmAction(message, action) {
  return async () => {
    if (window.confirm(message)) await action();
  };
}
function signedOut() {
  settings.replaceChildren();
  settings.hidden = true;
  $("#login").hidden = false;
  $("#sign-out").hidden = true;
  $("#identity").textContent =
    "Manage your access, connections and credentials.";
}
async function keys(user) {
  const node = card(
    "api-keys",
    "API keys",
    "Create credentials and revoke access you no longer need.",
  );
  const result = el("div", null);
  const list = el("div", null);
  async function refresh() {
    const { data } = await api("/api/auth/api-keys");
    list.replaceChildren();
    for (const key of data)
      list.append(
        row(
          key.name,
          `${key.prefix}… · ${key.scopes.join(", ")} · Expires ${key.expires_at || "never"}`,
          button(
            "Revoke",
            confirmAction(
              `Revoke ${key.name}? If this is your current sign-in, you will need to sign in again.`,
              async () => {
                await api(`/api/auth/api-keys/${id(key.id)}`, "DELETE");
                await refresh();
                notice("Key revoked.");
              },
            ),
          ),
        ),
      );
    empty(list, "No API keys yet.");
  }
  node.append(
    form([field("name", "Key name")], "Create key", async (data, formNode) => {
      const key = await api("/api/auth/api-keys", "POST", data);
      const secret = el("code", key.key, { class: "result" });
      result.replaceChildren(
        el("p", "Copy this key now. It will not be shown again."),
        secret,
        button("Dismiss", () => result.replaceChildren()),
      );
      formNode.reset();
      await refresh();
    }),
    result,
    list,
  );
  if (user.role === "admin")
    node.append(
      el("a", "Manage admin keys in the admin console →", {
        href: auth.session().server + "/admin/keys",
      }),
    );
  await refresh();
}
async function oauthApps() {
  const node = card(
    "oauth-apps",
    "OAuth apps",
    "Register an app that signs in with Managoat.",
  );
  const editor = el("div", null),
    list = el("div", null);
  node.append(editor, list);
  function edit(client) {
    editor.replaceChildren(
      form(
        [
          field("name", "App name", "text", client?.name || ""),
          field(
            "redirect_uris",
            "Redirect URLs — one per line",
            "textarea",
            client?.redirect_uris.join("\n") || "",
          ),
        ],
        client ? "Save app" : "Register app",
        async (data) => {
          await api(
            "/api/oauth/clients" + (client ? `/${id(client.id)}` : ""),
            client ? "PATCH" : "POST",
            { ...data, redirect_uris: lines(data.redirect_uris) },
          );
          edit();
          await refresh();
          notice("App saved.");
        },
      ),
    );
    if (client) editor.append(button("Cancel editing", () => edit()));
  }
  async function refresh() {
    const { data } = await api("/api/oauth/clients");
    list.replaceChildren();
    for (const client of data)
      list.append(
        row(
          client.name,
          `${client.client_id} · ${client.published ? "Published" : "Development: only you can sign in"}`,
          button("Edit", () => edit(client)),
          button(
            "Delete",
            confirmAction(`Delete ${client.name}?`, async () => {
              await api(`/api/oauth/clients/${id(client.id)}`, "DELETE");
              edit();
              await refresh();
            }),
          ),
        ),
      );
    empty(list, "No registered apps yet.");
  }
  edit();
  await refresh();
}
async function connections() {
  const node = card(
    "connections",
    "Connections",
    "Connect remote MCP servers. Their credentials stay on your server.",
  );
  const list = el("div", null);
  function authorize(data) {
    const url = new URL(data.authorize_url);
    if (url.protocol !== "https:")
      throw new Error("The provider returned an insecure sign-in URL.");
    location.assign(url.href);
  }
  async function refresh() {
    const { data } = await api("/api/connections");
    list.replaceChildren();
    for (const connection of data)
      list.append(
        row(
          connection.resource || connection.url,
          `${connection.status}${connection.revoked_reason ? " · " + connection.revoked_reason : ""}`,
          button("Reconnect", async () =>
            authorize(
              await api(
                `/api/connections/${id(connection.id)}/authorize`,
                "POST",
              ),
            ),
          ),
          button(
            "Disconnect",
            confirmAction(
              "Disconnect this server? Agents using it will need a new connection.",
              async () => {
                await api(`/api/connections/${id(connection.id)}`, "DELETE");
                await refresh();
              },
            ),
          ),
        ),
      );
    empty(list, "No connected servers yet.");
  }
  const advanced = el("details", null);
  advanced.append(
    el("summary", "Provider options"),
    field("client_id", "Client ID (if required)", "text", "", false),
    field(
      "client_secret",
      "Client secret (if required)",
      "password",
      "",
      false,
    ),
    field(
      "authorize_params",
      "Authorization options — one name=value per line",
      "textarea",
      "",
      false,
    ),
  );
  node.append(
    form(
      [field("url", "MCP server URL", "url"), advanced],
      "Connect server",
      async (data) => {
        const attrs = { url: data.url };
        if (data.client_id) attrs.client_id = data.client_id;
        if (data.client_secret) attrs.client_secret = data.client_secret;
        if (data.authorize_params)
          attrs.authorize_params = pairs(data.authorize_params);
        authorize(await api("/api/connections", "POST", attrs));
      },
    ),
    button("Refresh status", refresh),
    list,
  );
  await refresh();
}
async function credentials() {
  const node = card(
    "inference-credentials",
    "Inference credentials",
    "Choose the credentials your agents use with model providers.",
  );
  node.append(
    el("a", "Link or manage your ChatGPT subscription →", {
      href: auth.session().server + "/auth/chatgpt",
    }),
  );
  const { data } = await api("/api/account/inference-credentials");
  const names = {
    anthropic_api_key: "Anthropic API key",
    claude_code_oauth_token: "Claude OAuth token",
    openai_api_key: "OpenAI API key",
    gemini_api_key: "Gemini API key",
  };
  for (const provider of data) {
    const status = el(
      "p",
      provider.set ? "Credential saved" : "No credential saved",
    );
    node.append(
      form(
        [
          el("h2", names[provider.provider] || provider.provider),
          status,
          field("value", "New credential", "password"),
        ],
        "Validate and save",
        async (data, node) => {
          await api(
            `/api/account/inference-credentials/${id(provider.provider)}`,
            "PUT",
            data,
          );
          node.reset();
          status.textContent = "Credential saved";
          notice("Credential validated and saved.");
        },
      ),
      button(
        "Remove credential",
        confirmAction("Remove this credential?", async () => {
          await api(
            `/api/account/inference-credentials/${id(provider.provider)}`,
            "DELETE",
          );
          status.textContent = "No credential saved";
          notice("Credential removed.");
        }),
      ),
    );
  }
}
async function bindings() {
  const node = card(
    "bindings",
    "Secret bindings",
    "Attach environment and vault secrets to outbound hosts.",
  );
  const list = el("div", null),
    editor = el("div", null);
  const { data: presets } = await api("/api/secret-bindings/presets");
  function edit(binding = {}) {
    const authType = el("select", null, { name: "auth_type" });
    for (const type of ["bearer", "api_key", "basic", "custom", "substitute"])
      authType.append(el("option", type, { value: type }));
    authType.value = binding.auth_type || "bearer";
    const label = el("label", "Authentication");
    label.append(authType);
    const optional = el("div", null);
    function authFields() {
      optional.replaceChildren();
      if (authType.value === "api_key")
        optional.append(
          field("header", "Header name", "text", binding.header || ""),
          field("prefix", "Prefix", "text", binding.prefix || "", false),
        );
      if (authType.value === "basic")
        optional.append(
          field("username", "Username", "text", binding.username || ""),
        );
      if (authType.value === "custom")
        optional.append(
          field(
            "headers_text",
            "Headers — one name=value per line; use {{ SECRET_NAME }} for a secret",
            "textarea",
            Object.entries(binding.headers || {})
              .map(([k, v]) => `${k}=${v}`)
              .join("\n"),
          ),
        );
    }
    authType.addEventListener("change", authFields);
    authFields();
    editor.replaceChildren(
      form(
        [
          field(
            "key",
            "Secret name",
            "text",
            binding.key || binding.suggested_key || "",
          ),
          field("host", "Host", "text", binding.host || ""),
          label,
          optional,
        ],
        binding.created_at ? "Save binding" : "Create binding",
        async (data) => {
          const attrs = { ...data };
          delete attrs.headers_text;
          if (data.headers_text) attrs.headers = pairs(data.headers_text);
          await api(
            "/api/secret-bindings" +
              (binding.created_at ? `/${id(binding.id)}` : ""),
            binding.created_at ? "PATCH" : "POST",
            attrs,
          );
          edit();
          await refresh();
          notice("Binding saved.");
        },
      ),
    );
    if (binding.created_at)
      editor.append(button("Cancel editing", () => edit()));
  }
  const picker = el("select", null);
  picker.append(el("option", "Start with a preset…", { value: "" }));
  for (const preset of presets.filter((p) => p.usable))
    picker.append(el("option", preset.name, { value: preset.id }));
  picker.addEventListener("change", () =>
    edit(presets.find((p) => p.id === picker.value) || {}),
  );
  const pickerLabel = el("label", "Service preset");
  pickerLabel.append(picker);
  node.append(pickerLabel, editor, list);
  async function refresh() {
    const { data } = await api("/api/secret-bindings");
    list.replaceChildren();
    for (const binding of data)
      list.append(
        row(
          binding.key,
          `${binding.host} · ${binding.auth_type} · ${binding.enabled ? "Enabled" : "Disabled"}`,
          button("Edit", () => edit(binding)),
          button(binding.enabled ? "Disable" : "Enable", async () => {
            await api(`/api/secret-bindings/${id(binding.id)}`, "PATCH", {
              enabled: !binding.enabled,
            });
            await refresh();
          }),
          button(
            "Delete",
            confirmAction(
              `Remove the binding for ${binding.key} on ${binding.host}?`,
              async () => {
                await api(`/api/secret-bindings/${id(binding.id)}`, "DELETE");
                await refresh();
              },
            ),
          ),
        ),
      );
    empty(list, "No secret bindings yet.");
  }
  edit();
  await refresh();
}
function security(user) {
  const node = card(
    "password",
    "Password",
    "Change your password or set one for an account that uses GitHub.",
  );
  node.append(
    el(
      "p",
      "Changing your password signs out browser sessions. API keys, including this app’s sign-in, remain active. Revoke keys above if needed.",
    ),
    el("a", "Set or reset a password →", {
      href: auth.session().server + "/auth/forgot-password",
    }),
    form(
      [
        field("current_password", "Current password", "password"),
        field("new_password", "New password", "password"),
      ],
      "Change password",
      async (data, formNode) => {
        await api("/api/auth/password", "POST", data);
        formNode.reset();
        notice(
          "Password changed. Browser sessions were signed out; API keys remain active.",
        );
      },
    ),
  );
  node.querySelector("[name=current_password]").autocomplete =
    "current-password";
  node.querySelector("[name=new_password]").autocomplete = "new-password";
  node.querySelector("[name=new_password]").minLength = 8;
  const danger = card(
    "delete",
    "Delete account",
    "Permanently delete your account and everything in it.",
  );
  danger.append(
    el(
      "p",
      "Destroys running sandboxes, agents, environments, vaults, conversations and stored secrets, including the encryption key. This cannot be undone.",
    ),
  );
  const deleteForm = form(
    [field("confirm", `Type ${user.email} to confirm`)],
    "Delete my account",
    async (data) => {
      if (data.confirm !== user.email)
        throw new Error("Type your email address exactly to confirm.");
      await api("/api/account", "DELETE", data);
      auth.forget();
      signedOut();
      notice("Your account has been deleted.");
    },
  );
  const submit = deleteForm.querySelector("button");
  submit.className = "danger";
  submit.disabled = true;
  deleteForm.addEventListener("input", () => {
    submit.disabled = deleteForm.elements.confirm.value !== user.email;
  });
  danger.addEventListener("toggle", () => {
    if (!danger.open) {
      deleteForm.reset();
      submit.disabled = true;
    }
  });
  danger.append(deleteForm);
}
async function load() {
  if (!auth.session()) return signedOut();
  const user = await api("/api/auth/me");
  $("#identity").textContent = `${user.email} · ${auth.session().server}`;
  $("#login").hidden = true;
  $("#sign-out").hidden = false;
  settings.hidden = false;
  settings.replaceChildren();
  // Each section reports its own load failure so one unavailable service does not hide account access.
  for (const render of [
    () => keys(user),
    oauthApps,
    connections,
    credentials,
    bindings,
  ]) {
    try {
      await render();
    } catch (error) {
      if (!auth.session()) throw error;
      const last = settings.lastElementChild;
      last.append(
        el("p", `Could not load: ${error.message}`, { role: "alert" }),
      );
      last.open = true;
    }
  }
  security(user);
}
$("#login-form").elements.server.value =
  query.get("server") ||
  auth.session()?.server ||
  (location.pathname.startsWith("/account-app/")
    ? location.origin
    : "https://managoat.com");
$("#login-form").addEventListener("submit", (event) => {
  event.preventDefault();
  run(event.submitter, () =>
    auth.begin($("#login-form").elements.server.value, section),
  );
});
$("#sign-out").addEventListener("click", (event) =>
  run(event.currentTarget, async () => {
    await auth.logout();
    signedOut();
    notice("Signed out of the account app.");
  }),
);
try {
  const completed = await auth.complete();
  if (completed !== null) section = completed;
  // A link naming another server never reuses this tab's bearer token there.
  if (
    query.has("server") &&
    auth.session() &&
    serverURL(query.get("server")) !== auth.session().server
  ) {
    signedOut();
    notice(
      "This link points to another server. Sign in to that server to continue.",
    );
  } else await load();
  if (query.get("connection") === "error")
    notice(
      "The connection did not complete. Try reconnecting from Connections.",
      true,
    );
  if (query.get("connection") === "ok") notice("Connection completed.");
} catch (error) {
  notice(error.message, true);
  if (!auth.session()) signedOut();
}
