const repository = "euforic/AgentDock";
const releasesURL = `https://github.com/${repository}/releases`;

document.querySelectorAll("[data-year]").forEach((element) => {
  element.textContent = String(new Date().getFullYear());
});

async function resolveLatestDownload() {
  try {
    const response = await fetch(`https://api.github.com/repos/${repository}/releases/latest`, {
      headers: { Accept: "application/vnd.github+json" },
    });
    if (!response.ok) return;

    const release = await response.json();
    const dmg = release.assets?.find((asset) => asset.name.endsWith(".dmg"));
    if (!dmg?.browser_download_url) return;

    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = dmg.browser_download_url;
      link.setAttribute("download", "");
      link.setAttribute("aria-label", `Download AgentDock ${release.tag_name} for macOS`);
    });

    document.querySelectorAll("[data-download-label]").forEach((element) => {
      element.textContent = "Download for macOS";
    });

    document.querySelectorAll("[data-release-meta]").forEach((element) => {
      element.textContent = `${release.tag_name} · Notarized DMG · macOS 26 or later · Apple silicon`;
    });
  } catch {
    document.querySelectorAll("[data-download]").forEach((link) => {
      link.href = releasesURL;
    });
  }
}

function enableRevealMotion() {
  if (!("IntersectionObserver" in window) || window.matchMedia("(prefers-reduced-motion: reduce)").matches) {
    return;
  }

  document.body.classList.add("motion-ready");
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      entry.target.classList.add("is-visible");
      observer.unobserve(entry.target);
    });
  }, { rootMargin: "0px 0px -8%", threshold: 0.12 });

  document.querySelectorAll("[data-reveal]").forEach((element) => observer.observe(element));
}

resolveLatestDownload();
enableRevealMotion();
