// Runs priv/static/assets/phoenix_kit_ecommerce.js against a fake page.
// `node --test test/js/storefront.test.cjs` (the ExUnit CSP test runs it too).
const test = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const vm = require("node:vm");

const SOURCE = fs.readFileSync(
  path.join(__dirname, "../../priv/static/assets/phoenix_kit_ecommerce.js"),
  "utf8"
);

function image(attrs, extra) {
  const img = Object.assign(
    {
      attrs: Object.assign({}, attrs),
      hasAttribute(name) { return name in this.attrs; },
      getAttribute(name) { return name in this.attrs ? this.attrs[name] : null; },
      removeAttribute(name) { delete this.attrs[name]; },
      set src(value) { this.attrs.src = value; this.swaps = (this.swaps || 0) + 1; },
      get src() { return this.attrs.src; },
      closest() { return null; },
    },
    extra || {}
  );
  return img;
}

function page(images, readyState) {
  const listeners = [];
  const document = {
    readyState: readyState || "complete",
    addEventListener(type, fn, capture) { listeners.push({ type, fn, capture: !!capture }); },
    querySelectorAll() { return images || []; },
  };
  const window = {};
  const run = () => vm.runInNewContext(SOURCE, { window, document });
  run();
  const fire = (type, event) =>
    listeners.filter((l) => l.type === type).forEach((l) => l.fn(event));
  return { window, listeners, fire, run };
}

test("a failed image is given its fallback, once", () => {
  const { fire, listeners } = page();
  const img = image({ src: "/missing.jpg", "data-pkec-img-fallback": "data:image/png;base64,AA" });

  assert.ok(listeners.find((l) => l.type === "error").capture, "error does not bubble");
  fire("error", { target: img });
  assert.strictEqual(img.src, "data:image/png;base64,AA");

  fire("error", { target: img });
  assert.strictEqual(img.swaps, 1, "a fallback that fails is not set again");
});

test("an image without the attribute is left alone", () => {
  const { fire } = page();
  const img = image({ src: "/missing.jpg" });
  fire("error", { target: img });
  assert.strictEqual(img.src, "/missing.jpg");
});

test("images already broken when the file runs are swept", () => {
  const broken = image(
    { src: "/gone.jpg", "data-pkec-img-fallback": "/ph.png" },
    { complete: true, naturalWidth: 0 }
  );
  const fine = image(
    { src: "/ok.jpg", "data-pkec-img-fallback": "/ph.png" },
    { complete: true, naturalWidth: 40 }
  );
  const svg = image(
    { src: "/logo.svg", "data-pkec-img-fallback": "/ph.png" },
    { complete: true, naturalWidth: 0 }
  );
  page([broken, fine, svg]);
  assert.strictEqual(broken.src, "/ph.png");
  assert.strictEqual(fine.src, "/ok.jpg");
  assert.strictEqual(svg.src, "/logo.svg");
});

test("the sweep waits for the document when it is still loading", () => {
  const broken = image(
    { src: "/gone.jpg", "data-pkec-img-fallback": "/ph.png" },
    { complete: true, naturalWidth: 0 }
  );
  const { fire } = page([broken], "loading");
  assert.strictEqual(broken.src, "/gone.jpg");
  fire("DOMContentLoaded", {});
  assert.strictEqual(broken.src, "/ph.png");
});

test("a click on a no-toggle button cancels the default and does not stop the event", () => {
  const { fire, listeners } = page();
  assert.strictEqual(listeners.find((l) => l.type === "click").capture, false);

  let prevented = 0;
  let stopped = 0;
  const event = (inside) => ({
    target: { closest: (selector) => (inside && selector === "[data-pkec-no-toggle]" ? {} : null) },
    preventDefault() { prevented++; },
    stopPropagation() { stopped++; },
    stopImmediatePropagation() { stopped++; },
  });

  fire("click", event(true));
  assert.strictEqual(prevented, 1);
  fire("click", event(false));
  assert.strictEqual(prevented, 1);
  assert.strictEqual(stopped, 0, "LiveView's listener on window must still get the click");
});

test("loading the file twice installs the listeners once", () => {
  const { listeners, run, window } = page();
  const count = listeners.length;
  run();
  assert.strictEqual(listeners.length, count);
  assert.deepStrictEqual(Object.keys(window.PhoenixKitEcommerceHooks), []);
});

test("a failed image with srcset drops srcset so the fallback src wins", () => {
  const { fire } = page();
  const img = image({
    src: "/missing.jpg",
    srcset: "/missing-2x.jpg 2x",
    "data-pkec-img-fallback": "/ph.png",
  });

  fire("error", { target: img });
  assert.strictEqual(img.src, "/ph.png");
  assert.strictEqual(img.hasAttribute("srcset"), false);
});

test("a click landing on a text node inside a no-toggle button still cancels the fold", () => {
  const { fire } = page();
  let prevented = 0;
  const textNode = {
    parentElement: {
      closest: (selector) => (selector === "[data-pkec-no-toggle]" ? {} : null),
    },
  };

  fire("click", { target: textNode, preventDefault() { prevented++; } });
  assert.strictEqual(prevented, 1);
});

test("loading without window or document is a no-op", () => {
  assert.doesNotThrow(() => vm.runInNewContext(SOURCE, {}));
});
