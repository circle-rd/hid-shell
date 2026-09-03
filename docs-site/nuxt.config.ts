export default defineNuxtConfig({
  extends: ["docus"],

  app: {
    baseURL: process.env.NUXT_APP_BASE_URL ?? "/hid-shell/",
  },

  site: {
    url: process.env.NUXT_SITE_URL ?? "https://docs.circle-cyber.com/hid-shell",
  },

  // Subpath baseURL sites need this disabled to avoid @nuxt/robots errors.
  robots: {
    robotsTxt: false,
  },

  llms: {
    title: "HID-Shell",
    description:
      "Headless cross-platform raw-HID shell payload for the Vandal ESP32 agent.",
    full: {
      title: "HID-Shell — Complete Documentation",
      description:
        "HID-Shell is a headless shell payload that rides a Vandal agent's vendor HID interface. It spawns a local OS shell and pumps stdin/stdout over 64-byte raw HID reports until the agent sends BYE, the device is unplugged, or the process is killed.",
    },
    sections: [
      {
        title: "Developer Resources",
        description: "Machine-readable entry points for this project.",
        links: [
          {
            title: "HID-Shell on GitHub",
            description: "Source, issues and releases.",
            href: "https://github.com/circle-rd/hid-shell",
          },
        ],
      },
    ],
    notes: [
      "When to use HID-Shell: bring up an interactive shell on a USB host through a Vandal agent's vendor HID (0xFF00) interface, with no network path and no console window on the host.",
      "HID-Shell is a payload, not a stand-alone application — it requires a Vandal ESP32 agent to provide the HID channel and is normally launched by the agent's universal BadUSB launcher, not invoked by hand.",
      "HID-Shell is a single-purpose v1 shell bridge over one vendor HID interface; it performs no network I/O and does not itself enumerate, open, or frame HID beyond the Vandal agent's vendor usage page.",
      "Reading this documentation as an agent: append `.md` to any page URL, or send `Accept: text/markdown`.",
    ],
  },
});
