#!/usr/bin/env python3
"""Verify translated paragraphs preserve inline elements and wrap naturally."""
from collections import Counter
from html.parser import HTMLParser
import json
from pathlib import Path
import re

MAC = Path(__file__).resolve().parents[1]
VOID_TAGS = {"br", "img", "input", "link", "meta"}
EARLY_UPDATES = ("{1} A new driver goes first to people who turn this on, "
                 "and reaches everyone once their machines show it made nothing worse.")
LOGS_LINE = {"zh-Hans": "遇到问题时请发送日志。", "zh-Hant": "遇到問題時請發送記錄。"}


class RichParagraphs(HTMLParser):
    def __init__(self):
        super().__init__()
        self.keys = []
        self.parts = []
        self.depth = 0
        self.slots = 0

    def handle_starttag(self, tag, attributes):
        if self.depth:
            assert tag != "br", "Localized paragraphs must flow without a hard line break"
            if self.depth == 1:
                self.slots += 1
                self.parts.append(f"{{{self.slots}}}")
            if tag not in VOID_TAGS:
                self.depth += 1
        elif "data-l10n-rich" in dict(attributes):
            self.parts = []
            self.depth = 1
            self.slots = 0

    def handle_data(self, text):
        if self.depth == 1:
            self.parts.append(text)

    def handle_endtag(self, tag):
        if self.depth:
            self.depth -= 1
            if not self.depth:
                self.keys.append(" ".join("".join(self.parts).split()))


def main():
    page = RichParagraphs()
    page.feed((MAC / "Resources/index.html").read_text(encoding="utf-8"))
    assert page.keys and not page.depth
    catalogs = {
        path.parent.stem: json.loads(path.read_text(encoding="utf-8"))
        for path in sorted((MAC / "Localizations").glob("zh-*.lproj/Interface.json"))
    }
    assert catalogs.keys() == LOGS_LINE.keys()
    assert catalogs["zh-Hans"].keys() == catalogs["zh-Hant"].keys()
    placeholders = re.compile(r"%@|\{(?:[1-9]\d*|n)\}")
    for locale, catalog in catalogs.items():
        assert all(key in catalog for key in page.keys), "Missing complete paragraph"
        for key in page.keys:
            if key == EARLY_UPDATES:
                first_line, second_line = catalog[key].split("\n")
                assert first_line.endswith("。") and second_line == LOGS_LINE[locale]
            else:
                assert "\n" not in catalog[key], key
        for source, translation in catalog.items():
            assert translation.strip(), f"Missing translation for {source}"
            assert Counter(placeholders.findall(source)) == Counter(placeholders.findall(translation)), source
            if source == EARLY_UPDATES:
                continue
            paragraphs = translation.strip("\n").split("\n\n")
            assert all(not re.search(r"[\r\n\u2028\u2029]", p) for p in paragraphs), source
            assert all(p.endswith(("。", "！", "？")) for p in paragraphs[:-1]), source
    print(f"{len(page.keys)} paragraphs passed in both locales, including the explicit early update line")


if __name__ == "__main__":
    main()
