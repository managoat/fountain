export const CLIENT_ID = "managoat-account";
const SESSION = "managoat-account.session";
const PENDING = "managoat-account.pending";
export function serverURL(value) {
  const url = new URL(value);
  if (
    url.username ||
    url.password ||
    url.search ||
    url.hash ||
    url.pathname !== "/" ||
    !(
      url.protocol === "https:" ||
      (url.protocol === "http:" &&
        ["localhost", "127.0.0.1", "[::1]"].includes(url.hostname))
    )
  ) {
    throw new Error(
      "Use an HTTPS server URL (HTTP is supported on localhost).",
    );
  }
  return url.origin;
}
export const base64url = (bytes) =>
  btoa(String.fromCharCode(...new Uint8Array(bytes)))
    .replaceAll("+", "-")
    .replaceAll("/", "_")
    .replaceAll("=", "");
export async function challenge(verifier) {
  return base64url(
    await crypto.subtle.digest("SHA-256", new TextEncoder().encode(verifier)),
  );
}
const random = () => base64url(crypto.getRandomValues(new Uint8Array(32)));
export function createAuth({
  storage = sessionStorage,
  location = window.location,
  history = window.history,
  fetcher = fetch,
  now = Date.now,
} = {}) {
  const redirect = location.origin + location.pathname;
  function session() {
    try {
      const saved = JSON.parse(storage.getItem(SESSION));
      if (
        saved &&
        saved.expires > now() &&
        serverURL(saved.server) === saved.server
      )
        return saved;
    } catch {
      /* Invalid or expired local state is signed out. */
    }
    storage.removeItem(SESSION);
    return null;
  }
  async function request(path, method = "GET", body) {
    const saved = session();
    if (!saved) throw new Error("Sign in to continue.");
    const response = await fetcher(saved.server + path, {
      method,
      credentials: "omit",
      redirect: "error",
      cache: "no-store",
      headers: {
        Authorization: `Bearer ${saved.token}`,
        "Content-Type": "application/json",
      },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    if (response.status === 401) storage.removeItem(SESSION);
    return decode(response);
  }
  return {
    session,
    request,
    forget() {
      storage.removeItem(SESSION);
    },
    async begin(server, section = "") {
      server = serverURL(server);
      const verifier = random(),
        state = random();
      storage.setItem(
        PENDING,
        JSON.stringify({
          server,
          verifier,
          state,
          redirect,
          section,
          created: now(),
        }),
      );
      const query = new URLSearchParams({
        client_id: CLIENT_ID,
        redirect_uri: redirect,
        response_type: "code",
        code_challenge_method: "S256",
        code_challenge: await challenge(verifier),
        state,
      });
      location.assign(`${server}/oauth/authorize?${query}`);
    },
    async complete() {
      const params = new URLSearchParams(location.search);
      if (!params.has("code") && !params.has("error")) return null;
      const pending = JSON.parse(storage.getItem(PENDING) || "null");
      storage.removeItem(PENDING);
      history.replaceState(null, "", redirect);
      if (
        !pending ||
        !params.get("state") ||
        params.get("state") !== pending.state ||
        pending.redirect !== redirect ||
        now() - pending.created > 600000
      ) {
        throw new Error(
          "The sign-in expired or did not start in this tab. Sign in again.",
        );
      }
      if (params.has("error")) throw new Error("Sign-in was declined.");
      const response = await fetcher(
        serverURL(pending.server) + "/api/oauth/token",
        {
          method: "POST",
          credentials: "omit",
          redirect: "error",
          cache: "no-store",
          headers: { "Content-Type": "application/json" },
          body: JSON.stringify({
            grant_type: "authorization_code",
            client_id: CLIENT_ID,
            redirect_uri: redirect,
            code: params.get("code"),
            code_verifier: pending.verifier,
          }),
        },
      );
      const token = await decode(response);
      if (!token.access_token || !(token.expires_in > 0))
        throw new Error("The server returned an invalid sign-in.");
      storage.setItem(
        SESSION,
        JSON.stringify({
          server: pending.server,
          token: token.access_token,
          expires: now() + token.expires_in * 1000,
        }),
      );
      return pending.section;
    },
    async logout() {
      await request("/api/oauth/revoke", "POST");
      storage.removeItem(SESSION);
    },
  };
}
async function decode(response) {
  if (response.status === 204) return null;
  const data = await response.json();
  if (!response.ok)
    throw new Error(
      data.message ||
        (typeof data.error === "string"
          ? data.error
          : JSON.stringify(data.errors || data.error)) ||
        `Request failed (${response.status}).`,
    );
  return data;
}
