// App-owned geometry lookup, ported from the iOS article reader. Article scripts are blocked by CSP.

globalThis.magpieReadingMarker = (() => {
  const wordSource = String.raw`[\p{L}\p{N}][\p{L}\p{N}\p{M}'’\u2010-\u2015-]*`;
  const words = () => new RegExp(wordSource, "gu");
  const segmenter = globalThis.Intl && Intl.Segmenter
    ? new Intl.Segmenter(undefined, { granularity: "word" })
    : null;

  const segments = text => {
    if (segmenter) {
      return Array.from(segmenter.segment(text))
        .filter(part => part.isWordLike)
        .map(part => ({ value: part.segment, index: part.index }));
    }
    return Array.from(text.matchAll(words()))
      .map(match => ({ value: match[0], index: match.index }));
  };

  const key = value => value
    .normalize("NFKD")
    .toLocaleLowerCase()
    .replace(/\p{M}/gu, "")
    .replace(/[’]/g, "'")
    .replace(/[\u2010-\u2015]/g, "-");

  const tokensInString = text => {
    const result = [];
    for (const part of segments(text)) {
      result.push({
        key: key(part.value),
        start: part.index,
        end: part.index + part.value.length
      });
    }
    return result;
  };

  const tokensInDocument = () => {
    const root = document.querySelector("main");
    if (!root) return [];
    const result = [];
    const walker = document.createTreeWalker(root, NodeFilter.SHOW_TEXT);
    let node;
    while ((node = walker.nextNode())) {
      const parent = node.parentElement;
      if (!parent || parent.closest("script, style, math, [data-hearful-metadata]")) continue;
      const urlRanges = [];
      for (const url of node.data.matchAll(/https?:\/\/\S+/giu)) {
        urlRanges.push({ start: url.index, end: url.index + url[0].length });
      }
      for (const part of segments(node.data)) {
        if (urlRanges.some(url => part.index >= url.start && part.index < url.end)) continue;
        result.push({
          key: key(part.value),
          node,
          start: part.index,
          end: part.index + part.value.length
        });
      }
    }
    return result;
  };

  let speech = [];
  let visible = [];
  let mapping = [];

  const anchor = (speechIndex, visibleIndex) => {
    let best = null;
    const speechEnd = Math.min(speech.length, speechIndex + 64);
    const visibleEnd = Math.min(visible.length, visibleIndex + 256);
    for (let s = speechIndex; s < speechEnd; s += 1) {
      for (let v = visibleIndex; v < visibleEnd; v += 1) {
        if (speech[s].key !== visible[v].key) continue;
        let run = 1;
        while (run < 4 && s + run < speech.length && v + run < visible.length
            && speech[s + run].key === visible[v + run].key) {
          run += 1;
        }
        const candidate = { s, v, run, distance: s - speechIndex + v - visibleIndex };
        if (!best || candidate.run > best.run
            || (candidate.run === best.run && candidate.distance < best.distance)) {
          best = candidate;
        }
      }
    }
    return best;
  };

  const align = () => {
    mapping = new Array(speech.length).fill(null);
    let s = 0;
    let v = 0;
    while (s < speech.length && v < visible.length) {
      if (speech[s].key === visible[v].key) {
        mapping[s] = visible[v];
        s += 1;
        v += 1;
        continue;
      }
      const next = anchor(s, v);
      if (!next) {
        s += 1;
        continue;
      }
      s = next.s;
      v = next.v;
    }
  };

  const configure = text => {
    speech = tokensInString(text || "");
    visible = tokensInDocument();
    align();
    return mapping.reduce((count, token) => count + (token ? 1 : 0), 0);
  };

  const tokenForRange = (location, length) => {
    const end = location + Math.max(length, 1);
    let index = speech.findIndex(token => token.start < end && token.end > location);
    if (index < 0) index = speech.findIndex(token => token.start >= location);
    if (index < 0) index = speech.length - 1;
    if (index < 0) return null;
    if (mapping[index]) return mapping[index];
    for (let distance = 1; distance <= 12; distance += 1) {
      if (index - distance >= 0 && mapping[index - distance]) return mapping[index - distance];
      if (index + distance < mapping.length && mapping[index + distance]) return mapping[index + distance];
    }
    return null;
  };

  const rectForRange = (location, length) => {
    const token = tokenForRange(location, length);
    if (!token) return null;
    const range = document.createRange();
    range.setStart(token.node, token.start);
    range.setEnd(token.node, token.end);
    const rect = range.getClientRects()[0] || range.getBoundingClientRect();
    if (!rect || !Number.isFinite(rect.top)) return null;
    return { top: rect.top + window.scrollY, height: rect.height, width: window.innerWidth };
  };

  return { configure, rectForRange };
})();
