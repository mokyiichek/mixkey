#!/usr/bin/env python3
"""Build MixKey's SQLite lexicon from the downloaded raw data.

Inputs  (data/raw, fetched by scripts/fetch-data.sh):
  8105.dict.yaml, base.dict.yaml   rime-ice pinyin dictionaries (GPL-3.0)
  STPhrases.txt, STCharacters.txt  OpenCC simplified->traditional tables (Apache-2.0)
  en_50k.txt                       English word frequency list (FrequencyWords, CC-BY-SA-4.0)
Inputs  (data/lexicon, part of this repo):
  proper_nouns.txt                 place names / proper nouns with correct capitalisation

Output: build/mixkey.db
"""
import os
import sqlite3
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RAW = os.path.join(ROOT, "data", "raw")
LEX = os.path.join(ROOT, "data", "lexicon")
OUT_DIR = os.path.join(ROOT, "build")
OUT = os.path.join(OUT_DIR, "mixkey.db")


def rime_entries(path):
    """Yield (word, syllables, weight) from a rime .dict.yaml file."""
    in_body = False
    with open(path, encoding="utf-8") as f:
        for line in f:
            line = line.rstrip("\n")
            if not in_body:
                if line.strip() == "...":
                    in_body = True
                continue
            if not line or line.startswith("#"):
                continue
            parts = line.split("\t")
            if len(parts) < 2:
                continue
            word, code = parts[0], parts[1].strip()
            weight = int(parts[2]) if len(parts) > 2 and parts[2].strip().isdigit() else 0
            if not code or not all(c.isascii() and (c.isalpha() or c == " ") for c in code):
                continue
            yield word, code, weight


def opencc_pairs(path):
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("#") or "\t" not in line:
                continue
            s, t = line.rstrip("\n").split("\t", 1)
            t = t.split(" ")[0]
            if s and t:
                yield s, t


def main():
    os.makedirs(OUT_DIR, exist_ok=True)
    if os.path.exists(OUT):
        os.remove(OUT)
    db = sqlite3.connect(OUT)
    c = db.cursor()
    c.executescript(
        """
        PRAGMA journal_mode=OFF;
        PRAGMA synchronous=OFF;
        CREATE TABLE words(key TEXT NOT NULL, word TEXT NOT NULL, weight INTEGER NOT NULL);
        CREATE TABLE syllables(s TEXT PRIMARY KEY) WITHOUT ROWID;
        CREATE TABLE st_phrase(s TEXT PRIMARY KEY, t TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE st_char(s TEXT PRIMARY KEY, t TEXT NOT NULL) WITHOUT ROWID;
        CREATE TABLE english(word TEXT PRIMARY KEY, rank INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE proper(lower TEXT PRIMARY KEY, proper TEXT NOT NULL, words INTEGER NOT NULL) WITHOUT ROWID;
        CREATE TABLE meta(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID;
        """
    )

    # --- pinyin words
    seen = {}
    syllables = set()
    for fname in ("8105.dict.yaml", "base.dict.yaml"):
        for word, code, weight in rime_entries(os.path.join(RAW, fname)):
            # rime writes ü as v (lv, nve); keep as-is, users type v too.
            for s in code.split(" "):
                if fname == "8105.dict.yaml":
                    syllables.add(s)
            k = (code, word)
            if seen.get(k, -1) < weight:
                seen[k] = weight
    # "lue"/"nue" are commonly typed for lve/nve
    alias = {}
    for s in list(syllables):
        if s in ("lve", "nve"):
            alias[s.replace("v", "u")] = s
    c.executemany("INSERT INTO words VALUES (?,?,?)", ((k, w, wt) for (k, w), wt in seen.items()))
    c.executemany("INSERT OR IGNORE INTO syllables VALUES (?)", ((s,) for s in sorted(syllables)))
    total = sum(seen.values())
    c.execute("INSERT INTO meta VALUES ('total_weight', ?)", (str(total),))
    c.execute("INSERT INTO meta VALUES ('syllable_alias', ?)", (",".join(f"{a}={b}" for a, b in alias.items()),))
    c.execute("CREATE INDEX words_key ON words(key, weight DESC)")
    print(f"pinyin entries: {len(seen):,}  syllables: {len(syllables)}")

    # --- OpenCC simplified -> traditional
    c.executemany("INSERT OR IGNORE INTO st_phrase VALUES (?,?)", opencc_pairs(os.path.join(RAW, "STPhrases.txt")))
    c.executemany("INSERT OR IGNORE INTO st_char VALUES (?,?)", opencc_pairs(os.path.join(RAW, "STCharacters.txt")))
    maxlen = c.execute("SELECT max(length(s)) FROM st_phrase").fetchone()[0]
    c.execute("INSERT INTO meta VALUES ('st_phrase_maxlen', ?)", (str(maxlen),))

    # --- English frequency
    rows = []
    with open(os.path.join(RAW, "en_50k.txt"), encoding="utf-8") as f:
        for rank, line in enumerate(f, 1):
            w = line.split(" ")[0].strip().lower()
            if w.isascii() and w.replace("'", "").isalpha():
                rows.append((w, rank))
    c.executemany("INSERT OR IGNORE INTO english VALUES (?,?)", rows)
    print(f"english words: {len(rows):,}")

    # --- Proper nouns (repo list + capitalised-only words from macOS's word list)
    proper = {}
    with open(os.path.join(LEX, "proper_nouns.txt"), encoding="utf-8") as f:
        for line in f:
            name = line.strip()
            if name and not name.startswith("#"):
                proper[name.lower()] = name
    words_file = "/usr/share/dict/propernames"
    if os.path.exists(words_file):
        with open(words_file, encoding="utf-8") as f:
            english = {w for w, _ in rows[:20000]}
            for line in f:
                name = line.strip()
                if name and name.lower() not in english and name.lower() not in proper:
                    proper[name.lower()] = name
    c.executemany(
        "INSERT INTO proper VALUES (?,?,?)",
        ((k, v, len(k.split(" "))) for k, v in proper.items()),
    )
    print(f"proper nouns: {len(proper):,}")

    db.commit()
    c.execute("VACUUM")
    db.close()
    print(f"wrote {OUT} ({os.path.getsize(OUT) / 1e6:.1f} MB)")


if __name__ == "__main__":
    sys.exit(main())
