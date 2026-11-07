// Shows what was blocked, and goes back to it as soon as the extension finds Socials current.
const raw = location.hash.slice(1);
// Ours carries encoded JSON; the rule's redirect the URL as it was, which is used untouched.
let info = { url: raw };
if (raw.startsWith("%7B")) {
  try {
    info = JSON.parse(decodeURIComponent(raw));
  } catch (_) {}
}
const site = document.getElementById("site");
const mode = document.getElementById("mode");
if (info.url) {
  try {
    site.textContent = new URL(info.url).hostname.replace(/^www\./, "");
  } catch (_) {}
}
if (info.mode) mode.textContent = info.mode;
document.title = `${site.textContent}: closed outside Socials`;

const api = globalThis.browser ?? globalThis.chrome;

// Only a web address is gone back to: the hash is anyone's to write.
function safe(url) {
  try {
    return ["http:", "https:"].includes(new URL(url).protocol) ? url : null;
  } catch (_) {
    return null;
  }
}

function check() {
  api.runtime.sendMessage("sync").then((now) => {
    if (!now) return;
    if (now.mode) mode.textContent = now.mode;
    const back = safe(info.url);
    if ((now.social || !now.sites.length) && back) location.replace(back);
  }).catch(() => {});
}
check();
setInterval(check, 2000);
