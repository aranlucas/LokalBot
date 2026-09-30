/* LokalBot landing page interactions. Vanilla, no dependencies. */
(function () {
  "use strict";

  var reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  var $ = function (sel, ctx) { return (ctx || document).querySelector(sel); };
  var $$ = function (sel, ctx) { return Array.prototype.slice.call((ctx || document).querySelectorAll(sel)); };

  /* ---------- scroll reveal (IntersectionObserver, no scroll listeners) ---------- */
  var reveals = $$(".reveal");
  if (reduce || !("IntersectionObserver" in window)) {
    reveals.forEach(function (el) { el.classList.add("in"); });
  } else {
    var io = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (e.isIntersecting) { e.target.classList.add("in"); io.unobserve(e.target); }
      });
    }, { threshold: 0.15, rootMargin: "0px 0px -7% 0px" });
    reveals.forEach(function (el) { io.observe(el); });
  }

  /* ---------- demo videos: never autoplay; one at a time; pause if the user scrolls away ---------- */
  var demos = $$(".hero__demo");
  demos.forEach(function (video) {
    video.addEventListener("play", function () {
      demos.forEach(function (other) { if (other !== video) other.pause(); });
    });
  });
  if (demos.length && "IntersectionObserver" in window) {
    var demoIO = new IntersectionObserver(function (entries) {
      entries.forEach(function (e) {
        if (!e.isIntersecting) { e.target.pause(); }
      });
    }, { threshold: 0.05 });
    demos.forEach(function (video) { demoIO.observe(video); });
  }

  /* ---------- phones and tablets: a DMG is no use here, so hand the link to a Mac ---------- */
  var ua = navigator.userAgent || "";
  var handheld = /iPhone|iPad|iPod|Android/i.test(ua) ||
    (/Macintosh/.test(ua) && navigator.maxTouchPoints > 1) ||
    !!(navigator.userAgentData && navigator.userAgentData.mobile);
  var dmgLinks = $$('a[href$="LokalBot.dmg"]');

  if (handheld && dmgLinks.length) {
    var SITE_URL = "https://www.lokalbot.com/";
    var canShare = typeof navigator.share === "function";
    var status = $("[data-copy-status]");
    if (!status) {
      status = document.createElement("p");
      status.className = "visually-hidden";
      status.setAttribute("role", "status");
      document.body.appendChild(status);
    }

    /* the visible label is the last non-empty text node; icons stay put */
    var labelNode = function (el) {
      var last = null;
      for (var i = 0; i < el.childNodes.length; i++) {
        var n = el.childNodes[i];
        if (n.nodeType === 3 && n.nodeValue.trim()) last = n;
      }
      if (!last) { last = document.createTextNode(""); el.appendChild(last); }
      return last;
    };
    var relabel = function (el, text, icon) {
      labelNode(el).nodeValue = text;
      var glyph = $("i.ph", el);
      if (glyph && icon) glyph.className = "ph " + icon;
    };

    var legacyCopy = function () {
      var ta = document.createElement("textarea");
      ta.value = SITE_URL;
      ta.setAttribute("readonly", "");
      ta.style.position = "fixed";
      ta.style.opacity = "0";
      document.body.appendChild(ta);
      ta.select();
      ta.setSelectionRange(0, SITE_URL.length);
      var ok = false;
      try { ok = document.execCommand("copy"); } catch (_) {}
      document.body.removeChild(ta);
      return ok;
    };
    var flash = function (el, ok) {
      if (!ok) {
        window.prompt("Copy this link and open it on your Mac:", SITE_URL);
        return;
      }
      status.textContent = "";
      status.textContent = "Link copied. Open it on your Mac to download LokalBot.";
      if (el.dataset.copying) return;
      var node = labelNode(el);
      var glyph = $("i.ph", el);
      var before = { text: node.nodeValue, icon: glyph ? glyph.className : "" };
      el.dataset.copying = "1";
      node.nodeValue = el.classList.contains("text-button") ? "link copied" : "Link copied";
      if (glyph) glyph.className = "ph ph-check";
      setTimeout(function () {
        node.nodeValue = before.text;
        if (glyph) glyph.className = before.icon;
        delete el.dataset.copying;
      }, 2200);
    };
    var copyLink = function (el) {
      if (navigator.clipboard && navigator.clipboard.writeText) {
        navigator.clipboard.writeText(SITE_URL).then(
          function () { flash(el, true); },
          function () { flash(el, legacyCopy()); }
        );
      } else {
        flash(el, legacyCopy());
      }
    };
    var sendToMac = function (e) {
      e.preventDefault();
      var el = e.currentTarget;
      if (!canShare) { copyLink(el); return; }
      navigator.share({ title: "LokalBot", url: SITE_URL }).catch(function (err) {
        if (!err || err.name !== "AbortError") copyLink(el);
      });
    };

    dmgLinks.forEach(function (link) {
      relabel(link, canShare ? "Send to my Mac" : "Copy link", canShare ? "ph-share" : "ph-copy");
      link.setAttribute("href", SITE_URL);
      link.setAttribute("role", "button");
      link.removeAttribute("download");
      link.addEventListener("click", sendToMac);
      link.addEventListener("keydown", function (e) {
        if (e.key === " ") sendToMac(e);
      });
    });
    $$("[data-phone-label]").forEach(function (el) {
      relabel(el, el.getAttribute("data-phone-label"), el.getAttribute("data-phone-icon"));
    });
    $$("[data-copy-link]").forEach(function (button) {
      button.addEventListener("click", function () { copyLink(button); });
    });

    var hint = $("[data-handoff]");
    if (hint) {
      var shareCopy = $("[data-handoff-share]", hint);
      var plainCopy = $("[data-handoff-copy]", hint);
      var methods = $("[data-handoff-methods]", hint);
      if (!canShare && shareCopy && plainCopy) {
        shareCopy.hidden = true;
        plainCopy.hidden = false;
      } else if (/Android/i.test(ua) && methods) {
        methods.textContent = "email or a chat app";
      }
      hint.hidden = false;
    }
  }

  /* ---------- full-size screenshot links open the appearance on screen ---------- */
  $$(".home-image-link").forEach(function (link) {
    var source = $("source[media]", link);
    var img = $("img", link);
    if (!source || !img || !window.matchMedia) return;
    var mq = window.matchMedia(source.media);
    var sync = function () { link.href = mq.matches ? source.getAttribute("srcset") : img.getAttribute("src"); };
    sync();
    if (mq.addEventListener) { mq.addEventListener("change", sync); } else if (mq.addListener) { mq.addListener(sync); }
  });

  /* ---------- waveform: randomize bar timing for an organic pulse ---------- */
  if (!reduce) {
    $$("[data-wave] span").forEach(function (bar) {
      var dur = 560 + Math.random() * 720;
      bar.style.animationDuration = dur.toFixed(0) + "ms";
      bar.style.animationDelay = (-Math.random() * dur).toFixed(0) + "ms";
    });
  }

  /* ---------- cotyping demo: ghost text + Tab to accept ---------- */
  var input = $("#ctInput");
  var typedEl = $("#ctTyped");
  var ghostEl = $("#ctGhost");
  var field = $("#cotypeField");
  var cotype = field ? field.closest(".cotype") : null;

  if (input && typedEl && ghostEl && field) {
    var SNIPPETS = [
      "Following up on our sync, the on-device build is ready to ship.",
      "Thanks for the call. I'll send the recap and action items shortly.",
      "Action item: ship the on-device summary by Friday.",
      "Let's circle back on this once the transcript lands."
    ];
    var dismissed = false;

    function ghostFor(val) {
      if (!val || dismissed) return "";
      var v = val.toLowerCase();
      for (var i = 0; i < SNIPPETS.length; i++) {
        if (SNIPPETS[i].toLowerCase().indexOf(v) === 0) return SNIPPETS[i].slice(val.length);
      }
      return "";
    }
    function render() {
      typedEl.textContent = input.value;
      ghostEl.textContent = ghostFor(input.value);
    }
    function acceptWord() {
      var g = ghostFor(input.value);
      if (!g) return false;
      var m = g.match(/^\s*\S+/);
      input.value += m ? m[0] : g;
      render();
      return true;
    }

    /* seed with the static teaser so the field is meaningful before any motion */
    input.value = (typedEl.textContent || "").trim() === "" ? "" : typedEl.textContent;
    render();

    field.addEventListener("mousedown", function (e) {
      e.preventDefault();
      input.focus();
      var L = input.value.length;
      try { input.setSelectionRange(L, L); } catch (_) {}
    });
    input.addEventListener("focus", function () { if (cotype) cotype.classList.add("is-focused"); });
    input.addEventListener("blur", function () { if (cotype) cotype.classList.remove("is-focused"); });
    input.addEventListener("input", function () { dismissed = false; render(); });
    input.addEventListener("keydown", function (e) {
      if (e.key === "Tab" && ghostFor(input.value)) {
        e.preventDefault();
        acceptWord();
      } else if (e.key === "Escape") {
        dismissed = true;
        render();
      }
    });
  }
})();
