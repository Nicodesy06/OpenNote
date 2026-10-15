#!/usr/bin/env python3
"""Valutazione della qualità di trascrizioni e sbobinature.

Misura separatamente:
  1. accuratezza speech-to-text (WER) rispetto a una trascrizione di riferimento;
  2. errori sui termini tecnici (termini del glossario mancanti o storpiati);
  3. omissioni nella sbobinatura (fatti chiave presenti nel riferimento ma assenti);
  4. possibili allucinazioni (numeri e nomi propri non presenti nel riferimento,
     affermazioni vietate);
  5. completezza (rapporto di lunghezza, copertura dei fatti);
  6. qualità editoriale (indicatori euristici: intercalari residui, elenchi,
     titoli, lunghezza delle frasi).

Struttura del dataset (una cartella per lezione):
  reference_transcript.txt   trascrizione corretta a mano
  hypothesis_transcript.txt  trascrizione prodotta dall'app (export .txt)
  sbobinatura.md             sbobinatura prodotta dall'app (export Markdown)
  terms.txt                  un termine tecnico per riga
  facts.json                 {"facts": [{"id": "...", "keywords": ["..."]}], "forbidden": ["..."]}

Uso: python3 evaluate.py <cartella-dataset> [--json report.json]
Le metriche euristiche (4, 6) segnalano candidati da rivedere a mano: non
sono un giudizio definitivo.
"""
from __future__ import annotations

import argparse
import json
import re
import sys
import unicodedata
from pathlib import Path

FILLERS = ["ehm", "eh", "cioè", "allora", "diciamo", "insomma", "praticamente", "tipo", "vabbè", "okay"]


def normalize(text: str) -> list[str]:
    text = unicodedata.normalize("NFKD", text.lower())
    text = "".join(ch for ch in text if not unicodedata.combining(ch))
    text = re.sub(r"\[\[\s*s\d+[^\]]*\]\]", " ", text)
    text = re.sub(r"\[\[\s*incerto\s*:\s*([^\]]*)\]\]", r" \1 ", text)
    return re.findall(r"[a-z0-9]+", text)


def word_error_rate(reference: list[str], hypothesis: list[str]) -> dict:
    """WER con distanza di Levenshtein a livello di parola (O(n·m) memoria lineare)."""
    previous = list(range(len(hypothesis) + 1))
    for i, ref_word in enumerate(reference, start=1):
        current = [i] + [0] * len(hypothesis)
        for j, hyp_word in enumerate(hypothesis, start=1):
            cost = 0 if ref_word == hyp_word else 1
            current[j] = min(previous[j] + 1, current[j - 1] + 1, previous[j - 1] + cost)
        previous = current
    errors = previous[-1]
    return {"errors": errors, "reference_words": len(reference), "wer": errors / max(1, len(reference))}


def contains_phrase(tokens: list[str], phrase: str) -> bool:
    needle = normalize(phrase)
    if not needle:
        return False
    n = len(needle)
    return any(tokens[i:i + n] == needle for i in range(len(tokens) - n + 1))


def term_accuracy(reference: list[str], hypothesis: list[str], terms: list[str]) -> dict:
    relevant = [t for t in terms if contains_phrase(reference, t)]
    missing = [t for t in relevant if not contains_phrase(hypothesis, t)]
    return {"terms_in_reference": len(relevant), "missing_or_misspelled": missing, "term_accuracy": 1 - len(missing) / max(1, len(relevant))}


def omissions(reference: list[str], document: list[str], facts: list[dict]) -> dict:
    present = [f for f in facts if all(contains_phrase(reference, k) for k in f["keywords"])]
    omitted = [f["id"] for f in present if not all(contains_phrase(document, k) for k in f["keywords"])]
    return {"facts_in_reference": len(present), "omitted": omitted, "fact_coverage": 1 - len(omitted) / max(1, len(present))}


def hallucination_candidates(reference_text: str, document_text: str, forbidden: list[str]) -> dict:
    reference_tokens = set(normalize(reference_text))
    clean = re.sub(r"\[\[[^\]]*\]\]", " ", document_text)
    numbers = sorted({n for n in re.findall(r"\b\d{2,}\b", clean) if n not in reference_tokens})
    names = set()
    for sentence in re.split(r"(?<=[.!?])\s+", clean):
        words = re.findall(r"\b[A-ZÀ-Ý][\wà-ÿ'-]{2,}\b", sentence)
        for word in words[1:]:  # escluso l'inizio frase
            if normalize(word) and normalize(word)[0] not in reference_tokens:
                names.add(word)
    document_tokens = normalize(document_text)
    stated = [f for f in forbidden if contains_phrase(document_tokens, f)]
    return {"numbers_not_in_reference": numbers, "proper_nouns_not_in_reference": sorted(names), "forbidden_statements": stated}


def editorial(document_text: str) -> dict:
    body = re.sub(r"\[\[[^\]]*\]\]", "", document_text)
    lines = [l for l in body.splitlines() if l.strip()]
    headings = sum(1 for l in lines if l.lstrip().startswith("#"))
    bullets = sum(1 for l in lines if re.match(r"\s*([-*•]|\d+\.)\s", l))
    paragraphs = [l for l in lines if not l.lstrip().startswith(("#", "-", "*", ">")) and not re.match(r"\s*\d+\.\s", l)]
    sentences = [s for s in re.split(r"(?<=[.!?])\s+", " ".join(paragraphs)) if s.strip()]
    tokens = normalize(body)
    fillers = {f: tokens.count(f) for f in FILLERS if tokens.count(f)}
    return {
        "headings": headings,
        "paragraphs": len(paragraphs),
        "bullet_line_ratio": bullets / max(1, len(lines)),
        "avg_sentence_words": sum(len(normalize(s)) for s in sentences) / max(1, len(sentences)),
        "residual_fillers": fillers,
        "uncertain_markers": len(re.findall(r"\[\[\s*incerto", document_text, re.I)),
    }


def evaluate_item(directory: Path) -> dict:
    read = lambda name: (directory / name).read_text(encoding="utf-8") if (directory / name).exists() else ""
    reference_text = read("reference_transcript.txt")
    hypothesis_text = read("hypothesis_transcript.txt")
    document_text = read("sbobinatura.md")
    terms = [t.strip() for t in read("terms.txt").splitlines() if t.strip()]
    facts_data = json.loads(read("facts.json") or "{}")
    reference, hypothesis, document = normalize(reference_text), normalize(hypothesis_text), normalize(document_text)
    report = {"id": directory.name}
    if hypothesis:
        report["stt"] = word_error_rate(reference, hypothesis)
        report["terms_stt"] = term_accuracy(reference, hypothesis, terms)
    if document:
        report["terms_document"] = term_accuracy(reference, document, terms)
        report["omissions"] = omissions(reference, document, facts_data.get("facts", []))
        report["hallucinations"] = hallucination_candidates(reference_text, document_text, facts_data.get("forbidden", []))
        report["completeness"] = {"length_ratio": len(document) / max(1, len(reference))}
        report["editorial"] = editorial(document_text)
    return report


def main(argv: list[str]) -> int:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("dataset", type=Path)
    parser.add_argument("--json", type=Path)
    args = parser.parse_args(argv)
    items = sorted(p for p in args.dataset.iterdir() if p.is_dir())
    reports = [evaluate_item(p) for p in items]
    print(f"{'Lezione':<24}{'WER':>8}{'Termini STT':>13}{'Fatti':>8}{'Lungh.':>8}{'Sospetti':>10}")
    for r in reports:
        wer = f"{r['stt']['wer']:.1%}" if "stt" in r else "-"
        terms = f"{r['terms_stt']['term_accuracy']:.0%}" if "terms_stt" in r else "-"
        facts = f"{r['omissions']['fact_coverage']:.0%}" if "omissions" in r else "-"
        ratio = f"{r['completeness']['length_ratio']:.2f}" if "completeness" in r else "-"
        suspects = str(len(r["hallucinations"]["numbers_not_in_reference"]) + len(r["hallucinations"]["proper_nouns_not_in_reference"]) + len(r["hallucinations"]["forbidden_statements"])) if "hallucinations" in r else "-"
        print(f"{r['id']:<24}{wer:>8}{terms:>13}{facts:>8}{ratio:>8}{suspects:>10}")
    if args.json:
        args.json.write_text(json.dumps(reports, ensure_ascii=False, indent=2), encoding="utf-8")
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
