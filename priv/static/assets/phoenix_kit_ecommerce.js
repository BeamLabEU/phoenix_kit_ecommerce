// phoenix_kit_ecommerce storefront behaviours, folded into the host's
// phoenix_kit_modules.js by core's :phoenix_kit_js_sources compiler (see
// PhoenixKit.Module.js_sources/0).
//
// What the storefront markup used to do with inline handlers (`onerror="…"`,
// `onclick="…"`). A Content-Security-Policy without 'unsafe-inline' blocks
// those and no nonce can be put on an attribute, so the markup names what it
// wants and one listener per event, on the document, does it. No LiveView
// hook: the listeners are delegated, so they also cover markup patched in
// later.
//
//   data-pkec-img-fallback="url"   an <img> that failed to load shows this
//                                  picture instead (the product placeholder)
//   data-pkec-no-toggle            a button inside a <summary>: its click
//                                  does not fold the <details>
(function () {
  "use strict";

  // No hooks; the global exists because js_sources/0 names one.
  window.PhoenixKitEcommerceHooks = window.PhoenixKitEcommerceHooks || {};

  // The file can reach a page twice (the modules bundle and a host import).
  if (window.__pkecListeners) return;
  window.__pkecListeners = true;

  function has(el, name) {
    return !!el && typeof el.hasAttribute === "function" && el.hasAttribute(name);
  }

  function closest(target, selector) {
    return target && typeof target.closest === "function" ? target.closest(selector) : null;
  }

  // Swaps in the fallback once: a fallback that fails too is left alone.
  function imageFallback(img) {
    var url = img.getAttribute("data-pkec-img-fallback");
    if (url && img.getAttribute("src") !== url) img.src = url;
  }

  // An image that failed before this file ran (a deferred bundle) never
  // fires its error again: look once the document is parsed.
  function sweepBrokenImages() {
    document.querySelectorAll("img[data-pkec-img-fallback]").forEach(function (img) {
      // An SVG with no intrinsic size can report a natural width of 0 while
      // it shows fine, so it is left to its own error event.
      var src = img.getAttribute("src") || "";
      if (!src || /\.svg(\?|#|$)/i.test(src) || src.indexOf("data:image/svg") === 0) return;
      if (img.complete && img.naturalWidth === 0) imageFallback(img);
    });
  }

  // `error` does not bubble: capture phase.
  document.addEventListener("error", function (e) {
    if (has(e.target, "data-pkec-img-fallback")) imageFallback(e.target);
  }, true);

  // Only the default action (the fold) is cancelled. The click goes on to
  // LiveView's own listener on `window`, which pushes the button's phx-click.
  document.addEventListener("click", function (e) {
    if (closest(e.target, "[data-pkec-no-toggle]")) e.preventDefault();
  });

  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", sweepBrokenImages);
  } else {
    sweepBrokenImages();
  }

  if (typeof module === "object" && module.exports) {
    module.exports.imageFallback = imageFallback;
    module.exports.sweepBrokenImages = sweepBrokenImages;
  }
})();
