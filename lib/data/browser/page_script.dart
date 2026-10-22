/// What the agent runs inside a page, in an isolated world of its own: the
/// DOM is the page's, the globals are not, so nothing the page runs can see
/// or replace it. A world is made per evaluation, so the numbering lives on
/// the DOM — an element keeps its number for as long as the document does.
const pageScript = r"""
(() => {
  if (window.__entoli) return;
  const SELECTOR = 'a[href], button, input:not([type=hidden]), select, textarea, summary, iframe, ' +
    '[role=button], [role=link], [role=checkbox], [role=radio], [role=tab], [role=menuitem], ' +
    '[role=option], [role=switch], [role=textbox], [role=combobox], [role=searchbox], ' +
    '[contenteditable=""], [contenteditable=true], [onclick]';
  const root = document.documentElement;
  const visible = (el, r) => {
    if (r.width <= 1 || r.height <= 1) return false;
    const s = getComputedStyle(el);
    return s.visibility !== 'hidden' && s.display !== 'none' && Number(s.opacity) !== 0;
  };
  const inView = r => r.bottom > 0 && r.right > 0 && r.top < innerHeight && r.left < innerWidth;
  const clip = (s, n) => {
    s = String(s || '').replace(/\s+/g, ' ').trim();
    return s.length > n ? s.slice(0, n - 1) + '…' : s;
  };
  const role = el => {
    const explicit = el.getAttribute('role');
    if (explicit) return explicit;
    const tag = el.tagName;
    if (tag === 'A') return 'link';
    if (tag === 'INPUT') {
      const t = (el.type || 'text').toLowerCase();
      if (['submit', 'reset', 'image', 'button'].includes(t)) return 'button';
      if (['checkbox', 'radio', 'range', 'file', 'color', 'date'].includes(t)) return t;
      return 'textbox';
    }
    if (tag === 'SELECT') return 'select';
    if (tag === 'TEXTAREA' || el.isContentEditable) return 'textbox';
    if (tag === 'IFRAME') return 'frame';
    if (tag === 'BUTTON' || tag === 'SUMMARY') return 'button';
    return 'clickable';
  };
  const name = el => {
    if (el.tagName === 'IFRAME') {
      let host = '';
      try { host = new URL(el.src, location.href).host; } catch (_) {}
      return clip(el.title || host, 60);
    }
    const label = el.getAttribute('aria-label') ||
      (el.labels && el.labels[0] && el.labels[0].innerText) || '';
    if (el.tagName === 'SELECT') return clip(label || el.name, 60);
    return clip(label || el.innerText || el.placeholder || el.title || el.alt ||
      (el.tagName === 'INPUT' && ['submit', 'button'].includes(el.type) ? el.value : '') ||
      el.name || '', 80);
  };
  const refOf = el => {
    let ref = el.getAttribute('data-entoli-ref');
    if (!ref) {
      const next = Number(root.getAttribute('data-entoli-next') || '1');
      ref = String(next);
      root.setAttribute('data-entoli-next', String(next + 1));
      el.setAttribute('data-entoli-ref', ref);
    }
    return ref;
  };
  const describe = el => {
    let line = `[${refOf(el)}] ${role(el)} "${name(el)}"`;
    const tag = el.tagName;
    if (tag === 'INPUT' && ['checkbox', 'radio'].includes(el.type)) {
      line += el.checked ? ' checked' : ' unchecked';
    } else if (tag === 'SELECT') {
      const chosen = el.options[el.selectedIndex];
      line += ` = "${clip(chosen ? chosen.text : '', 40)}" of: ` +
        clip([...el.options].map(o => o.text).join(' | '), 160);
    } else if ((tag === 'INPUT' || tag === 'TEXTAREA') && el.value) {
      // A password, or what the user typed for a sign-in, is theirs alone.
      line += el.type === 'password' || el.hasAttribute('data-entoli-secret')
        ? ' value=(hidden)'
        : ` value="${clip(el.value, 60)}"`;
    }
    if (el.disabled) line += ' disabled';
    return line;
  };
  const elements = all => {
    const out = [];
    for (const el of document.querySelectorAll(SELECTOR)) {
      const r = el.getBoundingClientRect();
      if (visible(el, r) && (all || inView(r))) out.push(describe(el));
    }
    return out;
  };
  // The text in view, a line break wherever the next run starts lower down.
  const viewText = () => {
    const parts = [];
    const walker = document.createTreeWalker(document.body || root, NodeFilter.SHOW_TEXT);
    const range = document.createRange();
    let lastTop = null;
    for (let n = walker.nextNode(); n; n = walker.nextNode()) {
      const parent = n.parentElement;
      if (!parent || ['SCRIPT', 'STYLE', 'NOSCRIPT'].includes(parent.tagName)) continue;
      const words = n.textContent.replace(/\s+/g, ' ').trim();
      if (!words) continue;
      range.selectNodeContents(n);
      const r = range.getBoundingClientRect();
      if (r.width === 0 || !inView(r)) continue;
      if (lastTop !== null) parts.push(Math.abs(r.top - lastTop) > 4 ? '\n' : ' ');
      parts.push(words);
      lastTop = r.top;
    }
    return parts.join('');
  };
  const byRef = ref => document.querySelector(`[data-entoli-ref="${ref}"]`);
  window.__entoli = {
    snapshot(all) {
      return JSON.stringify({
        title: document.title,
        url: location.href,
        scrollY: Math.round(scrollY),
        height: Math.round(root.scrollHeight),
        width: innerWidth,
        view: innerHeight,
        elements: elements(all),
        text: all ? (document.body ? document.body.innerText : '') : viewText(),
        frames: [...document.querySelectorAll('iframe')].map(f => f.src || '').filter(Boolean),
      });
    },
    // Scrolled into view first, so the point is on screen to be clicked.
    rect(ref) {
      const el = byRef(ref);
      if (!el) return null;
      el.scrollIntoView({block: 'center', inline: 'center', behavior: 'instant'});
      const r = el.getBoundingClientRect();
      return JSON.stringify({
        left: r.left, top: r.top, width: r.width, height: r.height,
        scrollX: scrollX, scrollY: scrollY, tag: el.tagName,
      });
    },
    // What is at a ref, or at a viewport point, for an approval to name.
    // With neither, what has focus — into a same-site frame, where a canvas
    // editor keeps the field its keys go to.
    line(ref, x, y) {
      let el;
      if (ref != null) {
        el = byRef(ref);
      } else if (x != null) {
        el = document.elementFromPoint(x, y);
        if (el) el = el.closest(SELECTOR) || el;
      } else {
        el = document.activeElement;
        try {
          while (el && el.tagName === 'IFRAME' && el.contentDocument) {
            el = el.contentDocument.activeElement;
          }
        } catch (_) {}
        if (!el || el === document.body) return 'the page, with nothing focused';
        if (!el.matches(SELECTOR)) return `the focused ${el.tagName.toLowerCase()}`;
      }
      if (!el) return null;
      return el.matches(SELECTOR) ? describe(el) : `${el.tagName.toLowerCase()} "${clip(el.innerText, 80)}"`;
    },
    markSecret(ref) {
      const el = byRef(ref);
      if (el) el.setAttribute('data-entoli-secret', '');
      return !!el;
    },
    selectContents(ref) {
      const el = byRef(ref);
      if (!el) return false;
      el.focus();
      if (typeof el.select === 'function') {
        el.select();
      } else {
        const range = document.createRange();
        range.selectNodeContents(el);
        const selection = getSelection();
        selection.removeAllRanges();
        selection.addRange(range);
      }
      return true;
    },
    choose(ref, wanted) {
      const el = byRef(ref);
      if (!el || el.tagName !== 'SELECT') return null;
      const low = String(wanted).toLowerCase();
      const options = [...el.options];
      const option = options.find(o => o.text.trim().toLowerCase() === low || o.value.toLowerCase() === low) ||
        options.find(o => o.text.toLowerCase().includes(low));
      if (!option) return 'none';
      el.value = option.value;
      el.dispatchEvent(new Event('input', {bubbles: true}));
      el.dispatchEvent(new Event('change', {bubbles: true}));
      return option.text;
    },
  };
})();
""";
