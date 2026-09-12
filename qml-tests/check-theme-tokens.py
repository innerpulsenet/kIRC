#!/usr/bin/env python3
"""Theme token completeness + palette check for kIRC (theme schema 4).

Enumerates the token table (Theme.js -> THEME_TOKENS) against:

  * every built-in theme JSON in rust/qml/themes/*.json
  * every built-in theme object in Theme.js itself

and FAILS on a missing or an extra token, on any JSON<->JS value drift, on a
theme whose `schema` does not match THEME_SCHEMA_VERSION, on a BUILTIN_IDS
entry with no theme, and on a retro theme whose palette is not legible
(WCAG contrast) or whose per-kind colours are not visually distinguishable
(CIE76 delta-E).

This is the regression test for the failure mode that shipped before: a new
token added to the engine while a shipped theme (or the JS mirror) never
defined it — the theme silently rendered the fallback, or the token never
applied at all because the schema version was not bumped.

Exit code: 0 = everything consistent; 1 = at least one failure (all printed).
"""
import json
import os
import re
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
ROOT = os.path.dirname(HERE)
THEME_JS = os.path.join(ROOT, "rust/qml/Theme.js")
THEMES_DIR = os.path.join(ROOT, "rust/qml/themes")

# Palette thresholds. "Contrast is the constraint, not the vibe."
CONTRAST_MIN = 4.5   # every kind's text on the log surface
DELTAE_MIN = 14.0    # pairwise separation of the kinds within a theme.
# The tightest shipped palette is `tui` at 14.05 (fgMessage/fgHighlight), so
# 14.0 is the floor every theme actually clears; it was left at 12.0 once and
# drifted.
# ruleColor is 1px box-drawing furniture, not text: all palettes keep it
# deliberately subtle (the neutral tui theme has sat at 1.50 since schema 3).
RULE_CONTRAST_MIN = 1.2
KINDS = ["fgEvent", "fgMessage", "fgPrivate", "fgNotice", "fgAction",
         "fgHighlight", "fgWarn"]

failures = []
notes = []


def fail(msg):
    failures.append(msg)


# --------------------------------------------------------------------- colour

def parse(c):
    h = c.lstrip("#")
    return tuple(int(h[i:i + 2], 16) / 255.0 for i in (0, 2, 4))


def lin(v):
    return v / 12.92 if v <= 0.04045 else ((v + 0.055) / 1.055) ** 2.4


def lum(c):
    r, g, b = parse(c)
    return 0.2126 * lin(r) + 0.7152 * lin(g) + 0.0722 * lin(b)


def contrast(a, b):
    la, lb = lum(a), lum(b)
    return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)


def rgb_to_lab(c):
    r, g, b = parse(c)
    rl, gl, bl = lin(r), lin(g), lin(b)
    x = 0.4124564 * rl + 0.3575761 * gl + 0.1804375 * bl
    y = 0.2126729 * rl + 0.7151522 * gl + 0.0721750 * bl
    z = 0.0193339 * rl + 0.1191920 * gl + 0.9503041 * bl

    def f(t):
        return t ** (1 / 3) if t > 0.008856 else 7.787 * t + 16 / 116
    fx, fy, fz = f(x / 0.95047), f(y / 1.0), f(z / 1.08883)
    return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))


def deltae(a, b):
    la, lb = rgb_to_lab(a), rgb_to_lab(b)
    return sum((p - q) ** 2 for p, q in zip(la, lb)) ** 0.5


# ------------------------------------------------------------- JS extraction

def js_block(src, var_name):
    """The `{...}` literal assigned to `var <name>`, comment-stripped."""
    m = re.search(r"var %s = (\{)" % re.escape(var_name), src)
    if not m:
        fail("Theme.js: `var %s` not found" % var_name)
        return None
    i, depth, start = m.start(1), 0, m.start(1)
    while i < len(src):
        if src[i] == "{":
            depth += 1
        elif src[i] == "}":
            depth -= 1
            if depth == 0:
                break
        i += 1
    block = src[start:i + 1]
    # Full-line // comments only: values are plain JSON (hex strings, numbers).
    block = "\n".join(re.sub(r"^\s*//.*$", "", line)
                      for line in block.split("\n"))
    try:
        return json.loads(block)
    except Exception as exc:  # noqa: BLE001
        fail("Theme.js: cannot parse `%s` as JSON: %s" % (var_name, exc))
        return None


src = open(THEME_JS).read()
schema_m = re.search(r"var THEME_SCHEMA_VERSION = (\d+)", src)
ids_m = re.search(r"var BUILTIN_IDS = \[(.*?)\]", src, re.S)
if not schema_m or not ids_m:
    print("FAIL Theme.js: schema version or BUILTIN_IDS missing")
    sys.exit(1)
SCHEMA = int(schema_m.group(1))
BUILTIN_IDS = [s.strip().strip('"') for s in ids_m.group(1).split(",")]

tokens = js_block(src, "THEME_TOKENS")
builtins = js_block(src, "builtins")
if tokens is None or builtins is None:
    for f in failures:
        print("FAIL", f)
    sys.exit(1)

root_keys = tokens.pop("root")
section_keys = tokens  # remaining name -> [tokens]

# ------------------------------------------------------------------- checks

# 1. the themes/*.json file set == BUILTIN_IDS == the builtins object
files = sorted(f[:-5] for f in os.listdir(THEMES_DIR) if f.endswith(".json"))
if files != sorted(BUILTIN_IDS):
    fail("themes/*.json %s != BUILTIN_IDS %s" % (files, BUILTIN_IDS))
if sorted(builtins.keys()) != sorted(BUILTIN_IDS):
    fail("Theme.js builtins %s != BUILTIN_IDS %s"
         % (sorted(builtins.keys()), BUILTIN_IDS))

# 2. token completeness: every theme, both sides, exactly the table
def check_shape(theme, label):
    extra = [k for k in theme if k not in root_keys and k not in section_keys]
    missing_root = [k for k in root_keys if k not in theme]
    for k in extra:
        fail("%s: extra top-level token `%s`" % (label, k))
    for k in missing_root:
        fail("%s: missing root token `%s`" % (label, k))
    for sec, keys in section_keys.items():
        if sec not in theme:
            fail("%s: missing section `%s`" % (label, sec))
            continue
        have = set(theme[sec]) if isinstance(theme[sec], dict) else None
        if have is None:
            fail("%s: section `%s` is not an object" % (label, sec))
            continue
        for k in keys:
            if k not in have:
                fail("%s: missing token `%s.%s`" % (label, sec, k))
        for k in sorted(have - set(keys)):
            fail("%s: extra token `%s.%s`" % (label, sec, k))


def flatten(theme):
    out = {k: theme[k] for k in root_keys if k in theme}
    for sec in section_keys:
        for k, v in theme.get(sec, {}).items():
            out["%s.%s" % (sec, k)] = v
    return out


for tid in BUILTIN_IDS:
    path = os.path.join(THEMES_DIR, tid + ".json")
    data = json.load(open(path))
    check_shape(data, "themes/%s.json" % tid)
    if tid in builtins:
        check_shape(builtins[tid], "Theme.js builtin %s" % tid)
        # 3. JSON <-> JS parity, per token (keys AND values)
        fj, js = flatten(data), flatten(builtins[tid])
        for k in sorted(set(fj) | set(js)):
            if fj.get(k, "<absent>") != js.get(k, "<absent>"):
                fail("%s: JSON/JS drift on `%s`: %r != %r"
                     % (tid, k, fj.get(k, "<absent>"), js.get(k, "<absent>")))
    # 4. schema version stamp
    if data.get("schema") != SCHEMA:
        fail("%s: schema %r != THEME_SCHEMA_VERSION %d"
             % (tid, data.get("schema"), SCHEMA))
    if builtins.get(tid, {}).get("schema") != SCHEMA:
        fail("Theme.js builtin %s: schema %r != %d"
             % (tid, builtins.get(tid, {}).get("schema"), SCHEMA))

# 5. palette quality on every fixed-palette theme
for tid in BUILTIN_IDS:
    term = builtins[tid]["terminal"]
    if term.get("fgPrimary", "") == "":
        notes.append("%-9s palette follows the desktop scheme (no fixed colours)"
                     % tid)
        continue
    bg = term["bgLog"]
    min_c, min_c_what = 1e9, ""
    for k in KINDS + ["fgDim", "fgAccent", "fgSelf"]:
        v = term.get(k, "")
        if v == "":
            # Missing or empty: the shape/parity checks above already failed;
            # the palette pass must not crash on it.
            fail("%s: %s is empty but fgPrimary is fixed" % (tid, k))
            continue
        cr = contrast(v, bg)
        if cr < CONTRAST_MIN:
            fail("%s: %s %s contrast %.2f:1 on bgLog %s < %.1f"
                 % (tid, k, v, cr, bg, CONTRAST_MIN))
        if cr < min_c:
            min_c, min_c_what = cr, k
    rule = term.get("ruleColor", "")
    if rule == "":
        fail("%s: ruleColor is empty but fgPrimary is fixed" % tid)
    elif contrast(rule, bg) < RULE_CONTRAST_MIN:
        fail("%s: ruleColor contrast %.2f < %.1f"
             % (tid, contrast(rule, bg), RULE_CONTRAST_MIN))
    min_d, min_d_pair = 1e9, ""
    for i, a in enumerate(KINDS):
        for b in KINDS[i + 1:]:
            if term.get(a, "") == "" or term.get(b, "") == "":
                continue  # already reported above; skip the pair
            d = deltae(term[a], term[b])
            if d < min_d:
                min_d, min_d_pair = d, "%s/%s" % (a, b)
            if d < DELTAE_MIN:
                fail("%s: %s (%s) vs %s (%s) delta-E %.1f < %.0f"
                     % (tid, a, term[a], b, term[b], d, DELTAE_MIN))
    if min_c < 1e9:
        notes.append("%-9s palette OK: min contrast %.2f:1 (%s), min delta-E %.1f (%s)"
                     % (tid, min_c, min_c_what, min_d, min_d_pair))

# ------------------------------------------------------------------- report
print("THEME-TOKENS: schema %d, %d tokens, %d built-in themes"
      % (SCHEMA, sum(len(v) for v in tokens.values()) + len(root_keys),
         len(BUILTIN_IDS)))
for n in notes:
    print("  " + n)
if failures:
    print("THEME-TOKENS: %d FAILURE(S)" % len(failures))
    for f in failures:
        print("  FAIL " + f)
    sys.exit(1)
print("THEME-TOKENS: ALL PASS (every theme defines exactly the token table)")
