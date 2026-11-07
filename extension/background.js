// Blocks social sites unless Workspace Bar's current mode is a gated one (Socials). The dock tells
// the mode at http://127.0.0.1:47391/mode. A page is sent to blocked.html, which goes back to it
// once Socials is current. With the dock not running, nothing is blocked. One file for Brave,
// Chrome and Firefox: Firefox's `browser` promises, Chromium's `chrome`.

const api = globalThis.browser ?? globalThis.chrome;

// The browser by name, so that the dock can switch each one's add-in on and off: Firefox has
// getBrowserInfo, and Brave names itself among the user-agent brands that Chrome also gives.
function browserName() {
  if (globalThis.browser?.runtime?.getBrowserInfo) return "firefox";
  const brands = (navigator.userAgentData?.brands ?? []).map((b) => b.brand);
  if (brands.includes("Brave")) return "brave";
  return "chrome";
}

const SERVER = `http://127.0.0.1:47391/mode?browser=${browserName()}`;
const BLOCKED = api.runtime.getURL("blocked.html");
const RULE = 1;
const OPEN = { social: true, sites: [], mode: "" };   // the dock not answering: block nothing

let last = OPEN;

async function ask() {
  try {
    const r = await fetch(SERVER, { cache: "no-store", signal: AbortSignal.timeout(800) });
    if (r.ok) return await r.json();
  } catch (_) {}
  return null;
}

function onSite(url, sites) {
  try {
    const host = new URL(url).hostname.replace(/\.$/, "");
    return sites.some((s) => host === s || host.endsWith("." + s));
  } catch (_) {
    return false;
  }
}

function blockedPage(url, mode) {
  return `${BLOCKED}#${encodeURIComponent(JSON.stringify({ url, mode }))}`;
}

// The page a blocked tab stands in for, from either form of its address: ours carries JSON, the
// rule's redirect the bare URL.
// Only a web address is gone back to: anyone can open blocked.html with a hash of their own.
function original(tabUrl) {
  if (!tabUrl || !tabUrl.startsWith(BLOCKED)) return null;
  const raw = tabUrl.slice(tabUrl.indexOf("#") + 1);
  let url = raw;
  if (raw.startsWith("%7B")) {
    try {
      url = JSON.parse(decodeURIComponent(raw)).url;
    } catch (_) {
      return null;
    }
  }
  try {
    return ["http:", "https:"].includes(new URL(url).protocol) ? url : null;
  } catch (_) {
    return null;
  }
}

let syncing = null;
function sync() {
  if (syncing) return syncing;
  syncing = (async () => {
    const now = (await ask()) || OPEN;
    const block = !now.social && now.sites.length > 0;
    // Any page or frame on a listed site goes to blocked.html, its URL after the #.
    const rules = block
      ? [{
          id: RULE,
          priority: 1,
          action: { type: "redirect", redirect: { regexSubstitution: `${BLOCKED}#\\0` } },
          condition: { regexFilter: "^.*$", requestDomains: now.sites, resourceTypes: ["main_frame", "sub_frame"] },
        }]
      : [];
    await api.declarativeNetRequest.updateDynamicRules({ removeRuleIds: [RULE], addRules: rules });
    // Tabs already open: a social page goes to blocked.html, and a blocked tab goes back when allowed.
    const tabs = await api.tabs.query({});
    for (const t of tabs) {
      const url = t.url || t.pendingUrl || "";
      if (block && onSite(url, now.sites)) {
        api.tabs.update(t.id, { url: blockedPage(url, now.mode) }).catch(() => {});
      } else if (!block) {
        const back = original(url);
        if (back) api.tabs.update(t.id, { url: back }).catch(() => {});
      }
    }
    last = now;
    return now;
  })().finally(() => {
    syncing = null;
  });
  return syncing;
}

function wake() {
  api.alarms.create("sync", { periodInMinutes: 0.5 });
  sync();
}

api.runtime.onInstalled.addListener(wake);
api.runtime.onStartup.addListener(wake);
api.alarms.onAlarm.addListener(() => sync());
// Coming back to the browser after a switch in the dock is when it matters: ask again then.
api.windows.onFocusChanged.addListener((w) => {
  if (w !== api.windows.WINDOW_ID_NONE) sync();
});
api.tabs.onActivated.addListener(() => sync());
api.webNavigation.onBeforeNavigate.addListener((d) => {
  if (d.frameId === 0) sync();
});
api.runtime.onMessage.addListener((msg, _sender, reply) => {
  if (msg === "sync") {
    sync().then((now) => reply(now || last));
    return true;
  }
});
sync();
