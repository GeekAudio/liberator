const check = (condition, message) => { if (!condition) throw Error(message); };
const chinese = document.documentElement.lang.startsWith("zh-");
const layout = text => {
  const sample = document.createElement("div");
  sample.style.position = "absolute";
  sample.style.width = "450px";
  sample.style.top = "80px";
  document.querySelector(".desk").appendChild(sample);
  sample.textContent = text;
  wrapChineseProse(sample, new RegExp(technicalUnits.map(pattern => pattern.source).join("|"), "gu"));
  return sample;
};
const rowTop = el => Math.round(el.getBoundingClientRect().top);
if (chinese) {
  const font = document.documentElement.lang === "zh-Hans" ? "PingFang SC" : "PingFang TC";
  for (const selector of [".desk", "h1", ".nav", ".sh", ".b", "select"]) {
    check(getComputedStyle(document.querySelector(selector)).fontFamily.includes(font), "Chinese font missing: " + selector);
  }
  check(getComputedStyle(document.querySelector("#log")).fontFamily.includes("Menlo"), "the log must retain a monospace font");
  const sample = layout("設備已就緒。請繼續。");
  const [first, second] = sample.querySelectorAll(":scope > .sentence");
  check(rowTop(first) === rowTop(second), "short sentences should fit together");
  const widest = Math.max(first.getBoundingClientRect().width, second.getBoundingClientRect().width);
  sample.style.width = (Math.ceil(widest) + 1) + "px";
  check(rowTop(first) < rowTop(second), "second sentence should move as a unit");
  check(first.getBoundingClientRect().height === second.getBoundingClientRect().height, "neither fitted sentence may split");
  sample.remove();
  const copy = "如果可用空間不足，請保留 2048 MB，再使用 2.9.102 查看 /Library/A/B/status.json。請檢查 x86_64 和 Wi-Fi。";
  const long = layout(copy);
  long.style.width = "155px";
  const clauses = [...long.querySelectorAll(".phrase")];
  check(clauses.length >= 3 && rowTop(clauses[0]) < rowTop(clauses.at(-1)), "long sentence must wrap by clause");
  for (const unit of ["2048 MB", "2.9.102", "/Library/A/B/status.json", "x86_64", "Wi-Fi"]) {
    check([...long.querySelectorAll(".text-unit")].some(el => el.textContent === unit), "technical unit split: " + unit);
  }
  check(long.textContent === copy, "rendered text must remain copyable in full");
  long.remove();
  const updates = document.querySelector("#t-drv .pair [data-l10n-rich]");
  const br = updates.querySelector(":scope > br");
  const nextText = document.documentElement.lang === "zh-Hans" ? "遇到问题时请发送日志。" : "遇到問題時請發送記錄。";
  check(br && br.nextElementSibling.textContent === nextText, "explicit early update line missing");
  check(rowTop(br.previousElementSibling) < rowTop(br.nextElementSibling), "early update sentence kept on same row");
  check(rowTop(updates.firstElementChild) === rowTop(br.previousElementSibling), "intro of early updates must fit on the first visual line");
} else {
  check(!document.querySelector(".chinese-prose") && document.querySelector("h1").textContent === "Your Mac, mapped", "English fallback layout");
}
NM.on({event:"scan",data:{version:"0.4.0",macos:"26.7.4",major:26,arch:"x86_64",gpus:[{name:"NVIDIA GeForce RTX 3080",vendor:"10DE",supported:true,tested:false}],
  kexts:4,metal:["NVIDIA GeForce RTX 3080","Intel UHD Graphics 770"],files:true,opencore:"DBG-108-2026-11-18",installedDriverVersion:"2.9.102",goldenGate:true,ggKit:"current",ggKeptMB:27000,packages:[]}});
const path = "/Library/Logs/NullMoth/" + ("測試路徑-very-long-segment/".repeat(14)) + "status.json";
const why = "無法下載更新，請檢查快取檔案 " + path + "，確認空間後再試一次。";
NM.on({event:"upd", data:{state:"error",why}});
await new Promise(resolve => setTimeout(resolve, 0));
const error = document.querySelector("#updr");
check(error.textContent === why, "dynamic error changed or truncated");
if (chinese) {
  check(error.querySelector(".sentence"), "dynamic error not laid out");
  const device = [...document.querySelectorAll("#mac .tech-value")].find(el=>el.textContent === "NVIDIA GeForce RTX 3080");
  check(device && device.getBoundingClientRect().width > 0, "dynamic device model missing");
}
const content = document.querySelector(".content");
for (const tab of document.querySelectorAll(".tab")) {
  tab.click();
  check(!document.getElementById("t-" + tab.dataset.t).hidden, "tab not shown: " + tab.dataset.t);
  const allowed = content.clientWidth + 2;
  check(content.scrollWidth <= allowed, "horizontal overflow: " + tab.dataset.t + " (" + content.scrollWidth + " > " + allowed + ")");
}
return {locale:document.documentElement.lang, width:innerWidth, ok:true};
