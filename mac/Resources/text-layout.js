"use strict";

const prose = "p:not(.row):not(.sh), .todo li, #efiout li, #efiout summary, #efiout .now, " +
  "#mac td, #ports caption, #ggkept, #ggt, #updr, #earlyr, #efimountr, #tccr, #gpumapr";
const punctuation = /[，、：；。！？]+[”’」』）】]*/gu;
const endOfSentence = /[。！？]/u;
const leadingWords = /(?:请|請|如果|否则|否則|需要|无法|無法|不要|不能)/u;
const wordBoundaries = new Intl.Segmenter("zh", {granularity: "word"});
const technicalUnits = [
  /(?:https?:\/\/|file:\/\/)[^\s，。；！？“”「」）]+/,
  /(?:~?\/|(?:[\w.-]+\/)+)[\p{L}\p{N}_.%+~/=-]+/u,
  /(?:macOS|USB|RTX)\s*\d+(?:\.\d+)*(?:\s*Type-[AC])?/,
  /(?:--?[A-Za-z][\w.-]+(?:=[\w.,:+/-]+)?|[A-Za-z][A-Za-z0-9]*(?:[._-][A-Za-z0-9]+)+)/,
  /(?<![A-Za-z0-9_])\d+(?:\.\d+|:\d+)*(?:\s*(?:GHz|MHz|Hz|GiB|GB|MB|KB|%|秒|分钟|分鐘))?/,
  /(?:Golden Gate|NullMoth|OpenCore|Privacy & Security)/,
  leadingWords,
];

function wrapChineseProse(region, units) {
  const unitsAtStart = new RegExp("^\\s*(?:" + units.source + ")", "u");
  const output = [], sentence = [], clause = [];
  const inline = (className, contents) => {
    const span = document.createElement("span");
    span.className = className;
    span.append(...contents);
    return span;
  };
  const finishClause = () => {
    if (clause.length) sentence.push(inline("phrase", clause.splice(0)));
  };
  const finishSentence = () => {
    finishClause();
    if (sentence.length) output.push(inline("sentence", sentence.splice(0)));
  };
  const appendWords = (text) => {
    let start = 0;
    for (const word of text.matchAll(units)) {
      if (word.index < start) continue;
      clause.push(text.slice(start, word.index));
      let value = word[0];
      if (leadingWords.exec(value)?.[0] === value) {
        const tail = text.slice(word.index + value.length);
        const following = tail.match(unitsAtStart)?.[0] ?? wordBoundaries.segment(tail).containing(0)?.segment;
        if (following?.trim() && !/^[，、：；。！？“”「」]/u.test(following)) value += following;
      }
      const unit = inline("text-unit", [value]);
      // A path or URL can wrap after separators if it exceeds the entire row.
      if (value.includes("/")) {
        const pieces = value.split(/(?<=[/?&=#])/u);
        unit.replaceChildren(...pieces.flatMap((part, index) => index ? [document.createElement("wbr"), part] : [part]));
      }
      clause.push(unit);
      start = word.index + value.length;
    }
    if (start < text.length) clause.push(text.slice(start));
  };
  const appendProse = (text) => {
    let start = 0;
    for (const mark of text.matchAll(punctuation)) {
      const end = mark.index + mark[0].length;
      appendWords(text.slice(start, end));
      if (endOfSentence.test(mark[0])) finishSentence();
      else finishClause();
      start = end;
    }
    appendWords(text.slice(start));
  };

  for (const child of [...region.childNodes]) {
    if (child.nodeType === Node.TEXT_NODE) {
      appendProse(child.textContent);
    } else if (child.nodeName === "BR") {
      finishSentence();
      output.push(child);
    } else {
      if (child.nodeName === "SPAN" && child.matches(".bad, .good, .warn") && child.childElementCount === 0) {
        wrapChineseProse(child, units);
      }
      clause.push(child);
      if (endOfSentence.test(child.textContent.trim().slice(-1))) finishSentence();
    }
  }
  finishSentence();
  region.classList.add("chinese-prose");
  region.replaceChildren(...output);
}

function observeChineseProse(content) {
  const captions = [...new Set([...content.querySelectorAll("button, a")]
    .map((element) => element.textContent.trim()).filter((text) => text.length >= 2))]
    .sort((a, b) => b.length - a.length);
  const labelPatterns = captions.map((caption) => caption.replace(/[.*+?^${}()|[\]\\]/g, "\\$&"));
  const units = new RegExp([...labelPatterns, ...technicalUnits.map((pattern) => pattern.source)].join("|"), "gu");
  const apply = (region) => {
    if (region.querySelector(":scope > .sentence")) return;
    if (region.isConnected && region.textContent.trim()) wrapChineseProse(region, units);
  };
  const observer = new MutationObserver((records) => {
    const affected = new Set();
    for (const {target, addedNodes} of records) {
      const owner = target.closest(prose);
      if (owner) affected.add(owner);
      for (const node of addedNodes) {
        if (node.nodeType !== Node.ELEMENT_NODE) continue;
        if (node.matches(prose)) affected.add(node);
        node.querySelectorAll(prose).forEach((region) => affected.add(region));
      }
    }
    observer.disconnect();
    affected.forEach(apply);
    observer.observe(content, {childList: true, subtree: true});
  });
  content.querySelectorAll(prose).forEach(apply);
  observer.observe(content, {childList: true, subtree: true});
}
