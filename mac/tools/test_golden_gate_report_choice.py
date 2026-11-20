#!/usr/bin/env python3
# The owner's answer about start reports from macOS 27: asked by the app, passed by setup, written onto the macOS 27
# data volume by the Golden Gate script, and taken back by a later "no". The function is run as it stands in the
# script, against a made-up volume.
import pathlib, re, subprocess, sys, tempfile

root = pathlib.Path(__file__).resolve().parents[2]
gg = (root / "mac/Resources/nullmoth-golden-gate.sh").read_text()
setup = (root / "mac/Resources/nullmoth-setup.sh").read_text()
main = (root / "mac/Sources/main.swift").read_text()
failed = 0

def arm(name, ok, detail=""):
    global failed
    print(("ok   " if ok else "FAIL ") + name + (f" ({detail})" if detail and not ok else ""))
    failed += 0 if ok else 1

def fn(name):
    start = gg.index(name + "() {")
    return gg[start:gg.index("\n}\n", start) + 3]
body = fn("put_on_data") + fn("report_drop") + fn("report_choice")

def run(report, tag, pre=(), link=None):
    with tempfile.TemporaryDirectory() as d:
        vol = pathlib.Path(d) / "vol"; rep = vol / "Library/NullMoth/report"; vol.mkdir()
        away = pathlib.Path(d) / "away"; away.mkdir(); (away / "consent").write_text("theirs\n"); (away / "victim").write_text("theirs\n")
        if link == "folder":      # the report folder itself is a link to somewhere else
            rep.parent.mkdir(parents=True); rep.symlink_to(away)
        if link == "file":        # the two files are links to a file somewhere else
            rep.mkdir(parents=True); (rep / "consent").symlink_to(away / "victim"); (rep / "kit-tag").symlink_to(away / "victim")
        for f in pre:
            rep.mkdir(parents=True, exist_ok=True); (rep / f).write_text("x\n")
        script = 'ok() { echo "OK $*"; }; note() { echo "NOTE $*"; }\n' + body + f'\nREPORT="$1"; KITTAG="$2"; report_choice "$3"\n'
        out = subprocess.run(["/bin/bash", "-c", script, "x", report, tag, str(vol)], capture_output=True, text=True)
        have = {p.name: p.read_text() for p in rep.iterdir()} if rep.is_dir() else {}
        if link: have = {"away": sorted((q.name, q.read_text()) for q in away.iterdir()), "linked": (rep / "consent").is_symlink() or rep.is_symlink()}
        return out.returncode, out.stdout, have

rc, out, have = run("yes", "v3.0.0-beta.3")
arm("a yes writes the consent file and the kit's release tag", rc == 0 and "consent" in have and have.get("kit-tag") == "v3.0.0-beta.3\n", str(have))
arm("and says so", "start reports from macOS 27: on" in out, out)
rc, out, have = run("no", "v3.0.0-beta.3")
arm("a no writes no consent file", rc == 0 and "consent" not in have, str(have))
rc, out, have = run("", "v3.0.0-beta.3")
arm("no answer at all is a no", rc == 0 and "consent" not in have, str(have))
rc, out, have = run("no", "v3.0.0-beta.3", pre=("consent",))
arm("a later no takes an earlier yes back", rc == 0 and "consent" not in have and "off" in out, str(have))
rc, out, have = run("yes", "v3; rm -rf /")
arm("a tag that is not a plain release name is not written", rc == 0 and "consent" in have and "kit-tag" not in have, str(have))
rc, out, have = run("YES", "v3.0.0-beta.3")
arm("control: only the exact word yes turns reports on", "consent" not in have, str(have))

UNTOUCHED = [("consent", "theirs\n"), ("victim", "theirs\n")]
rc, out, have = run("yes", "v3.0.0-beta.3", link="folder")
arm("a report folder that is a link is not written through, and says nothing will be sent", rc == 0 and have["away"] == UNTOUCHED and "will send nothing" in out, str(have) + out)
rc, out, have = run("no", "v3.0.0-beta.3", link="folder")
arm("a no does not remove a file through a linked folder", rc == 0 and have["away"] == UNTOUCHED and "left alone" in out, str(have) + out)
rc, out, have = run("yes", "v3.0.0-beta.3", link="file")
arm("a consent file that is a link is refused; what it names is untouched", rc == 0 and have["away"] == UNTOUCHED and "will send nothing" in out, str(have) + out)
rc, out, have = run("no", "v3.0.0-beta.3", link="file")
arm("a no removes a linked consent file itself, never what it names", rc == 0 and have["away"] == UNTOUCHED and not have["linked"], str(have) + out)

arm("the script takes --report and --kit-tag", "--report) REPORT=${2:-}; shift;; --kit-tag) KITTAG=${2:-}; shift;;" in gg)
arm("the choice is written right after the system package is installed",
    re.search(r'\$sinst" --payload "\$SPAY" --system "\$SYS" --data "\$DATA" --esp "\$ROOT" --apply \|\| stop [^\n]*\n  report_choice "\$DATA"\n', gg) is not None)
arm("setup passes the answer on the finish step only, with the tag from the kit pin",
    '$([ "$1" = finish ] && echo "--report $([ -n "${GGREPORT:-}" ] && echo yes || echo no) --kit-tag ' in setup and "--report-consent) GGREPORT=1;;" in setup)
ask = main.find('r.messageText = L10n.text("Tell NullMoth how macOS 27 starts on this PC?")')
arm("the app asks before the one-button run and sends the option only on Send",
    ask > 0 and 'if r.runModal() == .alertFirstButtonReturn { extra.append("--report-consent") }' in main[ask:ask + 1500]
    and 'r.addButton(withTitle: L10n.text("Send")); r.addButton(withTitle: L10n.text("Don\'t send"))' in main[ask:ask + 1500])
print(f"{failed} failed"); sys.exit(1 if failed else 0)
