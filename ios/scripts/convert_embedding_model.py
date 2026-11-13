#!/usr/bin/env python3
"""Convert sentence-transformers/all-MiniLM-L6-v2 to Core ML and write test fixtures.

Run from the repository root (macOS, Apple silicon, Xcode command line tools):

    uv run --python 3.12 --with-requirements ios/scripts/requirements-embedding.txt \
        python -I ios/scripts/convert_embedding_model.py

What it does
  1. Downloads a pinned revision of the model (safetensors weights, configs,
     vocab) into --cache. No pickled weights and no remote code are loaded.
  2. Wraps BertModel + mean pooling over the attention mask + L2 normalization
     in one torch module, traces it with fixed shapes (batch 1, sequence 256,
     int32 input_ids and attention_mask) and converts it with coremltools to
     an ML Program (.mlpackage, fp16 compute/weights, iOS 17 / macOS 14 minimum).
  3. Checks the Core ML output against sentence-transformers (cosine >= 0.99
     on every reference sentence) and fails otherwise.
  4. Compiles the package with `xcrun coremlcompiler` and copies the compiled
     .mlmodelc, vocab.txt and a model card (MODEL.md) to --out.
  5. Writes tokenizer_fixtures.json (50 cases, Python BertTokenizer output) and
     embedding_fixtures.json (20 sentence-transformers reference embeddings)
     to --fixtures.

  --fixtures-only stops after the references are computed and rewrites just the
  two fixture files (no conversion, nothing under --out changes). The full run
  writes the same fixtures.

Model interface (pooling is baked in):
  inputs   input_ids       int32  [1, 256]  [CLS] ids [SEP] then 0 ([PAD]) padding
           attention_mask  int32  [1, 256]  1 for real tokens (incl. specials), 0 for padding
  output   embedding       float32 [1, 384] mean-pooled, L2-normalized sentence embedding
token_type_ids is not an input: it is all zeros for single-sentence input and is
built inside the graph.
"""

from __future__ import annotations

import argparse
import datetime as _dt
import hashlib
import json
import os
import platform
import shutil
import subprocess
import sys
import tempfile
import time
from pathlib import Path

import numpy as np

# Quiet the tokenizers fork warning (coremltools predicts in a subprocess).
os.environ.setdefault("TOKENIZERS_PARALLELISM", "false")

REPO_ID = "sentence-transformers/all-MiniLM-L6-v2"
# Pinned Hugging Face commit (main as of 2026-11-08).
REVISION = "1110a243fdf4706b3f48f1d95db1a4f5529b4d41"
ALLOW_PATTERNS = [
    "config.json",
    "model.safetensors",
    "modules.json",
    "sentence_bert_config.json",
    "config_sentence_transformers.json",
    "1_Pooling/config.json",
    "special_tokens_map.json",
    "tokenizer.json",
    "tokenizer_config.json",
    "vocab.txt",
    "README.md",
]

MODEL_NAME = "MiniLM_L6_v2"  # basename of the .mlpackage / .mlmodelc
# Value the app stores in `embedding_model`; change it whenever the model or
# its preprocessing changes so stored vectors are re-embedded.
EMBEDDING_MODEL_ID = "all-MiniLM-L6-v2-coreml-fp16-256"
SEQ_LEN = 256
DIMENSIONS = 384
MIN_COSINE = 0.99

IOS_DIR = Path(__file__).resolve().parents[1]
DEFAULT_OUT = IOS_DIR / "RelateBooks" / "Embedding" / "Model"
DEFAULT_FIXTURES = IOS_DIR / "Tests" / "RelateBooksCoreTests" / "Fixtures"
_SCRATCH = Path(os.environ.get("RELATE_BOOK_SCRATCH", Path(tempfile.gettempdir()) / "relate-book-embedding"))
DEFAULT_CACHE = _SCRATCH / "hf"
DEFAULT_WORK = _SCRATCH / "work"


# ---------------------------------------------------------------------------
# Fixture texts
# ---------------------------------------------------------------------------

HAIL_MARY_DESCRIPTION = (
    "Ryland Grace is the sole survivor on a desperate, last-chance mission–and if he fails, humanity "
    "and the earth itself will perish. Except that right now, he doesn’t know that. He can’t even "
    "remember his own name, let alone the nature of his assignment or how to complete it. All he knows is "
    "that he’s been asleep for a very, very long time. And he’s just been awakened to find himself "
    "millions of miles from home, with nothing but two corpses for company.\r\n\r\nHis crewmates dead, his "
    "memories fuzzily returning, he realizes that an impossible task now confronts him. Alone on this tiny "
    "ship that’s been cobbled together by every government and space agency on the planet and hurled "
    "into the depths of space, it’s up to him to conquer an extinction-level threat to our species."
    "\r\n\r\nAnd thanks to an unexpected ally, he just might have a chance.\r\n\r\nPart scientific mystery, "
    "part dazzling interstellar journey, *Project Hail Mary* is a tale of discovery, speculation, and "
    "survival to rival *The Martian*–while taking us to places it never dreamed of going."
)

SEP = " · "  # " · ", the separator BookEmbeddingText uses


def book_text(title: str, authors: list[str], subjects: list[str], description: str = "") -> str:
    parts = [title, ", ".join(authors), ", ".join(subjects)]
    if description:
        parts.append(description[:800])
    return SEP.join(p for p in parts if p)


BOOK_STRINGS = [
    book_text(
        "Project Hail Mary", ["Andy Weir"],
        ["Survival after airplane accidents, shipwrecks", "FICTION / Thrillers / Suspense",
         "FICTION / Science Fiction / Hard Science Fiction", "Habiletés de survie", "Vol spatial", "Astronautes"],
        HAIL_MARY_DESCRIPTION,
    ),
    book_text(
        "The Left Hand of Darkness", ["Ursula K. Le Guin"],
        ["Fantasy", "Classics", "LGBTQ fiction before Stonewall", "Trahison (Morale)", "Loyauté", "science fiction"],
    ),
    book_text(
        "Klara and the Sun", ["Kazuo Ishiguro"],
        ["FICTION / Visionary & Metaphysical", "FICTION / Science Fiction / General", "Amitié",
         "Intelligence artificielle"],
        "Klara and the Sun, the first novel by Kazuo Ishiguro since he was awarded the Nobel Prize in "
        "Literature, tells the story of Klara, an Artificial Friend with outstanding observational qualities.",
    ),
    book_text(
        "Station Eleven", ["Emily St. John Mandel"],
        ["Dystopias", "Prophets", "Theatrical companies", "collection:Canada Reads 2023", "Epidemics",
         "Canadian fiction"],
        "One snowy night Arthur Leander, a famous actor, has a heart attack onstage during a production of "
        "\"King Lear.\" Jeevan Chaudhary, a paparazzo-turned-EMT, is in the audience and leaps to his aid.",
    ),
    book_text(
        "Getting Things Done", ["David Allen"],
        ["Selbstorganisation", "Psychological Stress", "Creative ability in business", "Industrial management",
         "Zi wo(xin li xue)"],
        "In today's world, yesterday's methods just don't work. In Getting Things Done, veteran coach and "
        "management consultant David Allen shares the breakthrough methods for stress-free performance.",
    ),
    book_text(
        "Educated", ["Orah Danḳner", "Tara Westover"],
        ["Mormons", "Preparedness", "Adult children of dysfunctional families", "New York Times bestseller",
         "nyt:combined-print-and-e-book-nonfiction=2018-03-11", "Idaho, social conditions"],
        "*Educated* is a 2018 memoir by the American author Tara Westover.",
    ),
    book_text(
        "Sapiens", ["Yuval Noah Harari"],
        ["Anthropology", "Tecnología y civilización", "Cronología histórica",
         "Sci027000 sci086000 sci000000", "599.9", "Cb113.h4 h3713 2015"],
    ),
    book_text(
        "The Overstory", ["Richard Powers"],
        ["American literature", "nyt:hardcover-fiction=2018-05-06", "Forests and forestry", "Fiction"],
        "*The Overstory* unfolds in concentric rings of interlocking fable that range from antebellum New York "
        "to the late-twentieth-century Timber Wars of the Pacific Northwest and beyond.",
    ),
    book_text("L’étranger", ["Albert Camus"], ["Romans, nouvelles", "Absurde (Philosophie)"]),
    book_text("Le capital au XXIe siècle", ["Thomas Piketty"], ["Économie", "Inégalités"]),
    book_text("Las venas abiertas de América Latina", ["Eduardo Galeano"], ["América Latina", "Historia"]),
    book_text("Gödel, Escher, Bach", ["Douglas R. Hofstadter"],
              ["Artificial intelligence", "Music -- Philosophy and aesthetics", "Symmetry"]),
    book_text("三体 (The Three-Body Problem)", ["刘慈欣", "Liu Cixin"],
              ["Science fiction, Chinese", "Life on other planets"]),
    book_text("ノルウェイの森", ["村上春樹"],
              ["Japanese fiction", "Tokyo (Japan) -- Fiction"]),
    book_text("Piranesi", ["Susanna Clarke"], []),
]

LONG_WORD = "pneumonoultramicroscopicsilicovolcanoconiosis" * 3  # > 100 chars -> [UNK]

TOKENIZER_CASES: list[tuple[str, str]] = [
    # case
    ("lowercase", "hello world"),
    # Uppercase Greek with word-final capital sigma: Python lowercases one character at a time
    # before BasicTokenizer runs, so the final Σ becomes σ (##σ), never ς.
    ("greek_uppercase_sigma", "ΟΔΥΣΣΕΥΣ ΟΔΟΣ."),
    ("uppercase", "HELLO WORLD"),
    ("mixed_case_title", "The Left Hand of Darkness"),
    # accents
    ("accent_naive_cafe", "naïve café"),
    ("accent_french_phrase", "Crème Brûlée à la française"),
    ("accent_combining_marks", "Café Pérez"),
    ("accent_non_decomposing", "Ångström Øresund Straße"),
    ("greek_cyrillic", "Война и мир — Ὀδύσσεια"),
    # punctuation
    ("punct_attached", "Hello, world! How's it going?"),
    ("punct_dash_ellipsis_parens", "Don't stop—believing… (really)."),
    ("hyphens", "e-mail co-operation state-of-the-art"),
    ("apostrophes", "rock'n'roll O’Brien’s"),
    ("punct_symbols", "\"Quoted\" text; with: colons & ampersands #hashtag @user"),
    ("punct_brackets_path", "path/to/file.txt key=value [brackets] {braces} <angles>"),
    # numbers
    ("numbers_years", "1984 by George Orwell, published 1949"),
    ("numbers_decimal_ordinals", "3.14159 and 1,000,000 and 42nd and 2nd-edition"),
    ("numbers_isbn", "ISBN 978-0-593-13520-4"),
    ("numbers_currency", "$19.99 €5 £3 ¥100 50%"),
    # emoji
    ("emoji_simple", "I love books \U0001f4da❤️"),
    ("emoji_zwj", "\U0001f680 lonely astronaut \U0001f469‍\U0001f680 saves \U0001f30d"),
    # CJK and other scripts
    ("cjk_chinese", "三体"),
    ("cjk_mixed_latin", "百年孤独 by 加西亚·马尔克斯"),
    ("cjk_japanese_kana", "ノルウェイの森"),
    ("hangul", "한강 채식주의자"),
    ("fullwidth_latin", "Ｆｕｌｌｗｉｄｔｈ ｌｅｔｔｅｒｓ"),
    # empty-ish and whitespace
    ("empty", ""),
    ("spaces_only", "   "),
    ("whitespace_mixed", "\t\n  \r\n"),
    ("single_char", "a"),
    ("tabs_newlines", "word\twith\ttabs\nand\nnewlines"),
    ("format_controls", "zero​width space and soft­hyphen"),
    # Special tokens are split out of the raw text (the added-token trie) wherever they occur,
    # even inside a word; a lowercase "[mask]" is ordinary text.
    ("special_tokens_inline", "hello[SEP]world x[CLS]y [UNK]x [mask] [PAD]z"),
    # wordpiece edge cases
    ("long_words_wordpiece", "supercalifragilisticexpialidocious antidisestablishmentarianism"),
    ("word_over_100_chars", f"before {LONG_WORD} after"),
    # truncation
    ("exactly_256_tokens", " ".join(["book"] * 254)),
    ("one_over_256_tokens", " ".join(["book"] * 255)),
    ("long_text_truncated", HAIL_MARY_DESCRIPTION + " " + HAIL_MARY_DESCRIPTION),
]
TOKENIZER_CASES += [(f"book_{i + 1:02d}", s) for i, s in enumerate(BOOK_STRINGS[:12])]
assert len(TOKENIZER_CASES) == 50, len(TOKENIZER_CASES)

EMBEDDING_SENTENCES = [
    "lonely astronaut saves earth",
    *BOOK_STRINGS[:5],
    "A detective solves a murder in Victorian London.",
    "How to build better habits and get organized at work",
    "a memoir about growing up in a survivalist family",
    "The quick brown fox jumps over the lazy dog.",
    "Été à Paris: naïve café culture",
    "三体 science fiction",
    "Space exploration and first contact with aliens",
    "A cookbook of Italian pasta recipes",
    "Climate change and the future of forests",
    "Artificial intelligence and robots that have feelings",
    "History of the Roman Empire",
    "Poetry about love and loss",
    "I love books \U0001f4da",
    HAIL_MARY_DESCRIPTION + " " + HAIL_MARY_DESCRIPTION,  # truncated at 256 tokens
]
assert len(EMBEDDING_SENTENCES) == 20


# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    print(f"[convert] {msg}", flush=True)


def sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as f:
        for chunk in iter(lambda: f.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def tree_files(root: Path) -> list[Path]:
    return sorted(p for p in root.rglob("*") if p.is_file())


def tree_sha256(root: Path) -> str:
    """sha256 over '<relative path>\\0<sha256 of file>\\n' for every file, sorted by path."""
    h = hashlib.sha256()
    for p in tree_files(root):
        h.update(f"{p.relative_to(root).as_posix()}\0{sha256_file(p)}\n".encode())
    return h.hexdigest()


def tree_size(root: Path) -> int:
    return sum(p.stat().st_size for p in tree_files(root))


def cosine(a: np.ndarray, b: np.ndarray) -> float:
    a = np.asarray(a, dtype=np.float64).ravel()
    b = np.asarray(b, dtype=np.float64).ravel()
    return float(a @ b / (np.linalg.norm(a) * np.linalg.norm(b)))


def encode_padded(tokenizer, text: str) -> tuple[list[int], np.ndarray, np.ndarray]:
    ids = tokenizer.encode(text, add_special_tokens=True, truncation=True, max_length=SEQ_LEN)
    input_ids = np.zeros((1, SEQ_LEN), dtype=np.int32)
    mask = np.zeros((1, SEQ_LEN), dtype=np.int32)
    input_ids[0, : len(ids)] = ids
    mask[0, : len(ids)] = 1
    return ids, input_ids, mask


# ---------------------------------------------------------------------------
# Steps
# ---------------------------------------------------------------------------

def download(cache: Path) -> Path:
    from huggingface_hub import snapshot_download

    cache.mkdir(parents=True, exist_ok=True)
    path = snapshot_download(REPO_ID, revision=REVISION, cache_dir=str(cache), allow_patterns=ALLOW_PATTERNS)
    log(f"model files: {path}")
    return Path(path)


def build_wrapper(model_dir: Path):
    import torch
    from transformers import AutoModel

    bert = AutoModel.from_pretrained(str(model_dir), use_safetensors=True, attn_implementation="eager")
    bert.eval()

    class _SentenceEmbedding(torch.nn.Module):
        def __init__(self, bert):
            super().__init__()
            self.bert = bert

        def forward(self, input_ids, attention_mask):
            token_type_ids = torch.zeros_like(input_ids)
            embedded = self.bert.embeddings(input_ids=input_ids, token_type_ids=token_type_ids)
            # Additive attention mask built here instead of by BertModel: BertModel uses
            # finfo(float32).min, which becomes -inf in fp16 and turns into NaN on the
            # Core ML CPU and GPU backends (the Neural Engine happens to saturate it).
            # -1e4 is representable in fp16 and still zeroes the padded positions in softmax.
            mask_f = attention_mask.to(embedded.dtype)
            additive = (1.0 - mask_f)[:, None, None, :] * -1.0e4
            hidden = self.bert.encoder(embedded, attention_mask=additive, return_dict=False)[0]
            mask = mask_f.unsqueeze(-1)
            summed = (hidden * mask).sum(dim=1)
            counts = mask.sum(dim=1).clamp(min=1.0)
            mean = summed / counts
            norm = torch.sqrt((mean * mean).sum(dim=1, keepdim=True)).clamp(min=1e-6)
            return mean / norm

    return _SentenceEmbedding(bert).eval()


def convert(wrapper, work: Path, tokenizer):
    import coremltools as ct
    import torch

    ids, input_ids, mask = encode_padded(tokenizer, "lonely astronaut saves earth")
    example = (torch.from_numpy(input_ids), torch.from_numpy(mask))
    with torch.no_grad():
        traced = torch.jit.trace(wrapper, example)

    mlmodel = ct.convert(
        traced,
        convert_to="mlprogram",
        inputs=[
            ct.TensorType(name="input_ids", shape=(1, SEQ_LEN), dtype=np.int32),
            ct.TensorType(name="attention_mask", shape=(1, SEQ_LEN), dtype=np.int32),
        ],
        outputs=[ct.TensorType(name="embedding", dtype=np.float32)],
        compute_precision=ct.precision.FLOAT16,
        minimum_deployment_target=ct.target.iOS17,
    )
    mlmodel.author = "sentence-transformers (Reimers & Gurevych); Core ML conversion by relate-book"
    mlmodel.license = "Apache-2.0"
    mlmodel.short_description = (
        "all-MiniLM-L6-v2 sentence embedding: mean pooling over attention_mask + L2 normalization baked in. "
        f"Inputs input_ids/attention_mask int32 [1,{SEQ_LEN}] (BERT uncased WordPiece, [CLS]..[SEP], pad 0); "
        f"output embedding float32 [1,{DIMENSIONS}], unit length."
    )
    mlmodel.input_description["input_ids"] = f"WordPiece ids, [CLS]=101 ... [SEP]=102, padded with 0 to {SEQ_LEN}"
    mlmodel.input_description["attention_mask"] = "1 for real tokens (including [CLS]/[SEP]), 0 for padding"
    mlmodel.output_description["embedding"] = f"L2-normalized {DIMENSIONS}-d sentence embedding"
    mlmodel.user_defined_metadata["source_repo"] = REPO_ID
    mlmodel.user_defined_metadata["source_revision"] = REVISION
    mlmodel.user_defined_metadata["embedding_model_id"] = EMBEDDING_MODEL_ID
    mlmodel.user_defined_metadata["max_sequence_length"] = str(SEQ_LEN)
    mlmodel.user_defined_metadata["pooling"] = "mean(attention_mask) + l2norm"

    pkg = work / f"{MODEL_NAME}.mlpackage"
    if pkg.exists():
        shutil.rmtree(pkg)
    mlmodel.save(str(pkg))
    log(f"saved {pkg}")
    return mlmodel, pkg


def compile_package(pkg: Path, work: Path) -> Path:
    out = work / "compiled"
    if out.exists():
        shutil.rmtree(out)
    out.mkdir(parents=True)
    subprocess.run(["xcrun", "coremlcompiler", "compile", str(pkg), str(out)], check=True,
                   stdout=subprocess.DEVNULL)
    compiled = out / f"{MODEL_NAME}.mlmodelc"
    if not compiled.is_dir():
        raise SystemExit(f"coremlcompiler did not produce {compiled}")
    return compiled


def write_tokenizer_fixtures(path: Path, slow, fast, vocab_size: int) -> None:
    cases = []
    mismatches = []
    for name, text in TOKENIZER_CASES:
        full = slow.encode(text, add_special_tokens=True, truncation=False)
        ids = slow.encode(text, add_special_tokens=True, truncation=True, max_length=SEQ_LEN)
        fast_ids = fast.encode(text, add_special_tokens=True, truncation=True, max_length=SEQ_LEN)
        if fast_ids != ids:
            mismatches.append(name)
        cases.append({
            "name": name,
            "text": text,
            "input_ids": ids,
            "length": len(ids),  # attention_mask = [1] * length + [0] * (max_length - length)
            "truncated": len(full) > SEQ_LEN,
            "untruncated_length": len(full),
            "tokens": slow.convert_ids_to_tokens(ids),
        })
    if mismatches:
        log(f"note: fast tokenizer differs from BertTokenizer on {mismatches}")
    doc = {
        "description": "Python transformers.BertTokenizer (slow, uncased) output for "
                       f"{REPO_ID}@{REVISION[:12]}; encode(text, add_special_tokens=True, truncation=True, "
                       f"max_length={SEQ_LEN}). attention_mask is 1 for the first `length` positions and 0 "
                       f"for the padding up to max_length.",
        "generated_by": "ios/scripts/convert_embedding_model.py",
        "max_length": SEQ_LEN,
        "vocab_size": vocab_size,
        "special_tokens": {"[PAD]": 0, "[UNK]": slow.unk_token_id, "[CLS]": slow.cls_token_id,
                           "[SEP]": slow.sep_token_id, "[MASK]": slow.mask_token_id},
        "do_lower_case": True,
        "strip_accents": True,
        "tokenize_chinese_chars": True,
        "max_input_chars_per_word": 100,
        "fast_tokenizer_mismatches": mismatches,
        "cases": cases,
    }
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    log(f"wrote {path} ({len(cases)} cases)")


def write_embedding_fixtures(path: Path, slow, references: np.ndarray, st_version: str) -> None:
    cases = []
    for text, vec in zip(EMBEDDING_SENTENCES, references):
        ids = slow.encode(text, add_special_tokens=True, truncation=True, max_length=SEQ_LEN)
        cases.append({
            "text": text,
            "input_ids": ids,
            "embedding": [float(f"{x:.7g}") for x in vec.astype(np.float64)],
        })
    doc = {
        "description": f"sentence-transformers {st_version} SentenceTransformer('{REPO_ID}'@{REVISION[:12]})"
                       ".encode(text) on CPU, float32; the model's own Normalize module makes each vector "
                       "unit length. input_ids are the BertTokenizer ids (max_length 256).",
        "generated_by": "ios/scripts/convert_embedding_model.py",
        "model": REPO_ID,
        "embedding_model_id": EMBEDDING_MODEL_ID,
        "dimensions": DIMENSIONS,
        "max_length": SEQ_LEN,
        "min_cosine": MIN_COSINE,
        "cases": cases,
    }
    path.write_text(json.dumps(doc, ensure_ascii=False, indent=1) + "\n", encoding="utf-8")
    log(f"wrote {path} ({len(cases)} cases)")


def write_model_card(path: Path, info: dict) -> None:
    text = f"""# Embedding model: all-MiniLM-L6-v2 (Core ML)

Generated by `ios/scripts/convert_embedding_model.py`; do not edit by hand.
Regenerate (repository root, macOS on Apple silicon):

```sh
uv run --python 3.12 --with-requirements ios/scripts/requirements-embedding.txt \\
    python -I ios/scripts/convert_embedding_model.py
```

| | |
|---|---|
| Source | [{REPO_ID}](https://huggingface.co/{REPO_ID}) @ `{REVISION}` |
| Licence | Apache-2.0 (model weights and vocab.txt) |
| Architecture | BERT, 6 layers, hidden 384, 12 heads, uncased WordPiece vocab of {info['vocab_size']} |
| Conversion date | {info['date']} |
| Versions | {info['versions']} |
| Format | ML Program, fp16 compute and weights, minimum deployment target iOS 17 / macOS 14 |
| `embedding_model` id | `{EMBEDDING_MODEL_ID}` |
| `{MODEL_NAME}.mlmodelc` | {info['compiled_bytes']:,} bytes ({info['compiled_bytes'] / 1e6:.1f} MB); tree sha256 `{info['compiled_sha']}` |
| `{MODEL_NAME}.mlpackage` (not shipped) | {info['package_bytes']:,} bytes; tree sha256 `{info['package_sha']}`; model.mlmodel sha256 `{info['spec_sha']}` |
| Reproducible parts | weights/weight.bin sha256 `{info['weight_sha']}` (same file in the package and the compiled model); compiled model.mil sha256 `{info['mil_sha']}` |
| `vocab.txt` | sha256 `{info['vocab_sha']}` |
| Check vs sentence-transformers | min cosine {info['min_cos_pkg']:.6f} (.mlpackage), {info['min_cos_compiled']:.6f} (.mlmodelc) over {len(EMBEDDING_SENTENCES)} references; the .mlmodelc figure is the worst of the ALL, CPU_ONLY, CPU_AND_GPU and CPU_AND_NE compute units |

Tree sha256 = sha256 over `<relative path>\\0<sha256 of file>\\n` for every file, sorted by path.
The package's Manifest.json and model.mlmodel and the compiled model's metadata.json /
coremldata.bin carry per-run identifiers, so the two tree hashes change on every run. weight.bin and model.mil are
byte-for-byte reproducible from the pinned environment; compare those to verify a rebuild.

## Interface

Pooling and normalization are baked into the graph, so the output is the sentence embedding.

| Name | Kind | Type | Shape | Meaning |
|---|---|---|---|---|
| `input_ids` | input | int32 | [1, {SEQ_LEN}] | `[CLS]`=101, WordPiece ids, `[SEP]`=102, then `[PAD]`=0 up to {SEQ_LEN} |
| `attention_mask` | input | int32 | [1, {SEQ_LEN}] | 1 for real tokens including `[CLS]`/`[SEP]`, 0 for padding |
| `embedding` | output | float32 | [1, {DIMENSIONS}] | mean over the attention mask of the last hidden state, L2-normalized (cosine = dot product) |

`token_type_ids` is not an input (all zeros for one sentence; built inside the graph).
Special tokens: `[PAD]`=0, `[UNK]`=100, `[CLS]`=101, `[SEP]`=102, `[MASK]`=103.
Tokenizer: BERT uncased basic tokenizer (clean control chars, CJK characters split, NFD +
strip accents + lowercase, punctuation split) then greedy WordPiece with `##` continuation,
words over 100 characters become `[UNK]`; at most {SEQ_LEN} tokens including `[CLS]` and `[SEP]`.

## Files

- `{MODEL_NAME}.mlmodelc/`: compiled model, loaded with `MLModel(contentsOf:)`.
- `vocab.txt`: WordPiece vocabulary, one token per line, id = line index (0-based).
"""
    path.write_text(text, encoding="utf-8")
    log(f"wrote {path}")


def main() -> int:
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument("--cache", type=Path, default=DEFAULT_CACHE, help="Hugging Face download cache")
    ap.add_argument("--work", type=Path, default=DEFAULT_WORK, help="where the .mlpackage is built (not shipped)")
    ap.add_argument("--out", type=Path, default=DEFAULT_OUT, help="destination for .mlmodelc, vocab.txt, MODEL.md")
    ap.add_argument("--fixtures", type=Path, default=DEFAULT_FIXTURES, help="destination for test fixtures")
    ap.add_argument("--fixtures-only", action="store_true",
                    help="only (re)write the two fixture files; skip conversion, compilation and --out")
    args = ap.parse_args()

    if platform.system() != "Darwin":
        raise SystemExit("Core ML conversion checks and coremlcompiler need macOS")

    import coremltools as ct
    import sentence_transformers
    import torch
    import transformers
    from sentence_transformers import SentenceTransformer
    from transformers import BertTokenizer, BertTokenizerFast

    torch.manual_seed(0)
    versions = (
        f"Python {platform.python_version()}, torch {torch.__version__}, transformers {transformers.__version__}, "
        f"sentence-transformers {sentence_transformers.__version__}, coremltools {ct.__version__}, "
        f"numpy {np.__version__}"
    )
    log(versions)

    model_dir = download(args.cache.expanduser().resolve())
    work = args.work.expanduser().resolve()
    out = args.out.expanduser().resolve()
    fixtures = args.fixtures.expanduser().resolve()
    work.mkdir(parents=True, exist_ok=True)

    slow = BertTokenizer.from_pretrained(str(model_dir))
    fast = BertTokenizerFast.from_pretrained(str(model_dir))
    vocab_size = len(slow.vocab)
    assert slow.do_lower_case and slow.cls_token_id == 101 and slow.sep_token_id == 102
    assert slow.pad_token_id == 0 and slow.unk_token_id == 100

    st = SentenceTransformer(str(model_dir), device="cpu")
    assert st.max_seq_length == SEQ_LEN, st.max_seq_length
    references = st.encode(EMBEDDING_SENTENCES, convert_to_numpy=True, batch_size=8).astype(np.float32)
    assert references.shape == (len(EMBEDDING_SENTENCES), DIMENSIONS)

    # The torch wrapper must reproduce sentence-transformers before conversion.
    wrapper = build_wrapper(model_dir)
    with torch.no_grad():
        for text, ref in zip(EMBEDDING_SENTENCES, references):
            _, ids, mask = encode_padded(slow, text)
            vec = wrapper(torch.from_numpy(ids), torch.from_numpy(mask)).numpy()[0]
            c = cosine(vec, ref)
            if c < 0.99999:
                raise SystemExit(f"torch wrapper deviates from sentence-transformers ({c:.6f}): {text[:60]!r}")
    log("torch wrapper matches sentence-transformers")

    if args.fixtures_only:
        fixtures.mkdir(parents=True, exist_ok=True)
        write_tokenizer_fixtures(fixtures / "tokenizer_fixtures.json", slow, fast, vocab_size)
        write_embedding_fixtures(fixtures / "embedding_fixtures.json", slow, references,
                                 sentence_transformers.__version__)
        return 0

    mlmodel, pkg = convert(wrapper, work, slow)

    def check(predict, label: str) -> tuple[float, float]:
        worst, times = 1.0, []
        for text, ref in zip(EMBEDDING_SENTENCES, references):
            _, ids, mask = encode_padded(slow, text)
            t0 = time.perf_counter()
            vec = predict({"input_ids": ids, "attention_mask": mask})["embedding"][0]
            times.append(time.perf_counter() - t0)
            if not np.all(np.isfinite(vec)):
                raise SystemExit(f"{label}: non-finite output for {text[:60]!r}")
            c = cosine(vec, ref)
            worst = min(worst, c)
            if not c >= MIN_COSINE or abs(np.linalg.norm(vec) - 1) > 1e-2:
                raise SystemExit(f"{label}: cosine {c:.5f}, norm {np.linalg.norm(vec):.4f} for {text[:60]!r}")
        median_ms = 1000 * float(np.median(times[1:]))
        log(f"{label}: min cosine {worst:.6f}, median predict {median_ms:.1f} ms")
        return worst, median_ms

    min_cos_pkg, _ = check(mlmodel.predict, ".mlpackage")

    # The compiled model must be right on every backend: the iOS simulator runs on the CPU,
    # devices mostly on the Neural Engine.
    compiled_tmp = compile_package(pkg, work)
    min_cos_compiled = 1.0
    for units in (ct.ComputeUnit.ALL, ct.ComputeUnit.CPU_ONLY, ct.ComputeUnit.CPU_AND_GPU, ct.ComputeUnit.CPU_AND_NE):
        compiled_model = ct.models.CompiledMLModel(str(compiled_tmp), compute_units=units)
        worst, _ = check(compiled_model.predict, f".mlmodelc {units.name}")
        min_cos_compiled = min(min_cos_compiled, worst)

    # Ship: compiled model + vocab + model card.
    out.mkdir(parents=True, exist_ok=True)
    dest = out / compiled_tmp.name
    if dest.exists():
        shutil.rmtree(dest)
    shutil.copytree(compiled_tmp, dest)
    shutil.copyfile(model_dir / "vocab.txt", out / "vocab.txt")

    weight = pkg / "Data" / "com.apple.CoreML" / "weights" / "weight.bin"
    info = {
        "vocab_size": vocab_size,
        "date": _dt.date.today().isoformat(),
        "versions": versions,
        "compiled_bytes": tree_size(dest),
        "compiled_sha": tree_sha256(dest),
        "package_bytes": tree_size(pkg),
        "package_sha": tree_sha256(pkg),
        "weight_sha": sha256_file(weight) if weight.exists() else "n/a",
        "spec_sha": sha256_file(pkg / "Data" / "com.apple.CoreML" / "model.mlmodel"),
        "mil_sha": sha256_file(dest / "model.mil"),
        "vocab_sha": sha256_file(out / "vocab.txt"),
        "min_cos_pkg": min_cos_pkg,
        "min_cos_compiled": min_cos_compiled,
    }
    write_model_card(out / "MODEL.md", info)

    fixtures.mkdir(parents=True, exist_ok=True)
    write_tokenizer_fixtures(fixtures / "tokenizer_fixtures.json", slow, fast, vocab_size)
    write_embedding_fixtures(fixtures / "embedding_fixtures.json", slow, references, sentence_transformers.__version__)

    log(f"compiled model: {dest} ({info['compiled_bytes']:,} bytes)")
    log(f"package (not shipped): {pkg} ({info['package_bytes']:,} bytes)")
    log(json.dumps({k: v for k, v in info.items() if k != "versions"}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
