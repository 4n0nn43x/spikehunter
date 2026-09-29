#!/usr/bin/env python3
"""Analyse hors-ligne des spikes Boom/Crash à partir d'un export CSV de MetaTrader 5.

Même algorithme que l'indicateur SpikeHunter.mq5 : un tick (ou une bougie) est un
spike quand son mouvement dans le sens attendu dépasse `threshold` fois l'amplitude
moyenne des ticks normaux récents.

Formats acceptés (séparateur tabulation, virgule ou point-virgule détecté seul) :
  - ticks MT5 : <DATE> <TIME> <BID> <ASK> ...
  - bougies MT5 : <DATE> <TIME> <OPEN> <HIGH> <LOW> <CLOSE> ...
  - export MQL5 CopyTicks : time_msc,bid,ask
  - générique : une colonne date/heure et une colonne bid ou close

Exemples :
  python spike_stats.py "Boom 1000 Index_ticks.csv"
  python spike_stats.py crash500_M1.csv --direction down --out crash500.png
  python spike_stats.py --demo 1000
"""

import argparse
import re
import sys
from dataclasses import dataclass

import numpy as np
import pandas as pd

HAZARD_BINS = 6


@dataclass
class Result:
    times: np.ndarray
    prices: np.ndarray
    spike_idx: np.ndarray    # index de la donnée qui termine chaque spike
    spike_size: np.ndarray   # amplitude signée
    gaps: np.ndarray         # unités (ticks ou bougies) entre spikes consécutifs
    drift: float             # dérive moyenne par unité hors spikes
    haz_events: np.ndarray
    haz_exposure: np.ndarray
    nominal: int
    unit: str


def read_mt5_csv(path):
    with open(path, "r", encoding="utf-8-sig", errors="replace") as f:
        head = f.readline()
    sep = "\t" if "\t" in head else (";" if head.count(";") > head.count(",") else ",")
    df = pd.read_csv(path, sep=sep, encoding_errors="replace")
    df.columns = [c.strip().strip("<>").lower() for c in df.columns]

    if "time_msc" in df.columns:
        stamp = pd.to_datetime(pd.to_numeric(df["time_msc"], errors="coerce"), unit="ms")
    elif "date" in df.columns and "time" in df.columns:
        stamp = pd.to_datetime(df["date"].astype(str) + " " + df["time"].astype(str),
                               errors="coerce")
    else:
        col = next((c for c in df.columns if c in ("datetime", "time", "timestamp", "date")), None)
        if col is None:
            sys.exit(f"Colonne date/heure introuvable. Colonnes : {list(df.columns)}")
        stamp = pd.to_datetime(df[col], errors="coerce")

    if "bid" in df.columns:
        # Les exports de ticks laissent le bid vide quand seul l'ask change.
        price = pd.to_numeric(df["bid"], errors="coerce").ffill()
        out = pd.DataFrame({"time": stamp, "close": price})
        unit = "ticks"
    elif {"open", "high", "low", "close"} <= set(df.columns):
        out = pd.DataFrame({"time": stamp,
                            **{c: pd.to_numeric(df[c], errors="coerce")
                               for c in ("open", "high", "low", "close")}})
        unit = "bougies"
    elif "close" in df.columns:
        out = pd.DataFrame({"time": stamp, "close": pd.to_numeric(df["close"], errors="coerce")})
        unit = "ticks"
    else:
        sys.exit(f"Colonne de prix introuvable (bid/close). Colonnes : {list(df.columns)}")
    return out.dropna().reset_index(drop=True), unit


def detect(moves, direction, threshold, window, merge, nominal, noise_input=None):
    """Détection séquentielle, identique à l'indicateur MQL5.

    moves : mouvement signé de chaque unité (delta de tick, ou mouvement de bougie).
    noise_input : amplitude "normale" de chaque unité (|delta| par défaut, range pour les bougies).
    """
    if noise_input is None:
        noise_input = np.abs(moves)
    if direction == "up":
        signed = moves
    elif direction == "down":
        signed = -moves
    else:
        signed = np.abs(moves)

    alpha = 2.0 / (max(window, 2) + 1.0)
    width = 0.5 * nominal
    haz_events = np.zeros(HAZARD_BINS)
    haz_exposure = np.zeros(HAZARD_BINS)
    noise, noise_n = 0.0, 0
    drift_sum, drift_n = 0.0, 0
    age, last_spike = 0, -10**9
    idx, size, gaps = [], [], []

    for i in range(len(moves)):
        age += 1
        b = min(max(int((age - 1) / width), 0), HAZARD_BINS - 1)
        haz_exposure[b] += 1
        warm = noise_n >= window // 4 and noise > 0
        if warm and signed[i] > threshold * noise:
            haz_events[b] += 1
            if idx and i - last_spike <= merge:
                idx[-1] = i
                size[-1] += moves[i]
            else:
                if idx:
                    gaps.append(age)
                idx.append(i)
                size.append(moves[i])
            last_spike = i
            age = 0
            continue
        a = noise_input[i]
        noise = a if noise_n == 0 else noise + alpha * (a - noise)
        noise_n += 1
        drift_sum += moves[i]
        drift_n += 1

    return (np.array(idx, dtype=int), np.array(size), np.array(gaps),
            drift_sum / max(drift_n, 1), haz_events, haz_exposure)


def analyse(df, unit, direction, threshold, window, merge, nominal):
    if unit == "bougies":
        # Mouvement dans le sens du spike : plus haut - ouverture (Boom) ou
        # plus bas - ouverture (Crash) ; l'amplitude normale est le range.
        up = (df["high"] - df["open"]).to_numpy()
        down = (df["low"] - df["open"]).to_numpy()
        moves = {"up": up, "down": down}.get(direction,
                                              np.where(up >= -down, up, down))
        noise_input = (df["high"] - df["low"]).to_numpy()
        prices = df["close"].to_numpy()
        # La dérive se mesure sur les clôtures, pas sur les extrêmes.
        idx, size, gaps, _, he, hx = detect(moves, direction, threshold, window, merge,
                                            nominal, noise_input)
        closes = np.diff(prices, prepend=prices[0])
        mask = np.ones(len(closes), bool)
        mask[idx] = False
        drift = closes[mask].mean() if mask.any() else 0.0
    else:
        prices = df["close"].to_numpy()
        moves = np.diff(prices, prepend=prices[0])
        idx, size, gaps, drift, he, hx = detect(moves, direction, threshold, window,
                                                merge, nominal)
    return Result(df["time"].to_numpy(), prices, idx, size, gaps, drift, he, hx, nominal, unit)


def report(r):
    n = len(r.spike_idx)
    u = r.unit
    lines = [f"Données : {len(r.prices)} {u}, {n} spikes détectés"]
    if len(r.gaps) > 1:
        mean, std = r.gaps.mean(), r.gaps.std(ddof=1)
        lines.append(f"Écart moyen : {mean:.1f} {u}  médiane : {np.median(r.gaps):.0f}  "
                     f"CV : {std / mean:.3f}  (1.0 = sans mémoire)")
        lines.append(f"Dérive x écart moyen : {abs(r.drift) * mean:.4f}  "
                     f"vs spike moyen : {np.abs(r.spike_size).mean():.4f}")
    if n:
        lines.append(f"Taille des spikes : médiane {np.median(np.abs(r.spike_size)):.4f}  "
                     f"max {np.abs(r.spike_size).max():.4f}")
    lines.append(f"Dérive moyenne par {u[:-1]} hors spikes : {r.drift:.6f}")
    lines.append(f"Taux par âge ({u} par spike ; plat = aucune valeur prédictive) :")
    w = 0.5 * r.nominal
    for b in range(HAZARD_BINS):
        rng = f"{b * w:.0f}-{(b + 1) * w:.0f}" if b < HAZARD_BINS - 1 else f"{b * w:.0f}+"
        rate = (f"1 / {r.haz_exposure[b] / r.haz_events[b]:.0f}"
                if r.haz_events[b] else "n/d")
        lines.append(f"   âge {rng:>11} : {rate:>9}   ({r.haz_events[b]:.0f} spikes)")
    return "\n".join(lines)


def plot(r, title, out):
    import matplotlib
    matplotlib.use("Agg")
    import matplotlib.pyplot as plt

    fig = plt.figure(figsize=(13, 9), constrained_layout=True)
    gs = fig.add_gridspec(2, 2, height_ratios=[1.3, 1])
    ax = fig.add_subplot(gs[0, :])
    # Au-delà de 40 spikes, les flèches couvrent toute la courbe : on zoome
    # sur les 40 derniers pour garder les spikes lisibles.
    lo, zoom = 0, ""
    if len(r.spike_idx) > 40:
        lo = max(r.spike_idx[-40] - 200, 0)
        zoom = " (zoom sur les 40 derniers)"
    t, pr = r.times[lo:], r.prices[lo:]
    step = max(len(pr) // 200_000, 1)   # alléger le tracé des gros fichiers
    ax.plot(t[::step], pr[::step], lw=0.6, color="#4a5568")
    sel = r.spike_idx >= lo
    if sel.any():
        up = r.spike_size > 0
        for mask, marker, color, label in ((sel & up, "^", "#16a34a", "spike haussier"),
                                           (sel & ~up, "v", "#dc2626", "spike baissier")):
            if mask.any():
                ax.scatter(r.times[r.spike_idx[mask]], r.prices[r.spike_idx[mask]],
                           marker=marker, color=color, s=30, zorder=3, label=label)
        ax.legend(loc="upper left")
    ax.set_title(f"{title} : {len(r.spike_idx)} spikes{zoom}")
    ax.grid(alpha=0.3)

    ax2 = fig.add_subplot(gs[1, 0])
    if len(r.gaps) > 1:
        mean = r.gaps.mean()
        bins = np.linspace(0, np.percentile(r.gaps, 99), 40)
        ax2.hist(r.gaps, bins=bins, density=True, color="#60a5fa", alpha=0.8,
                 label="écarts observés")
        x = np.linspace(0, bins[-1], 200)
        ax2.plot(x, np.exp(-x / mean) / mean, color="#1e3a8a", lw=2,
                 label=f"sans mémoire (moyenne {mean:.0f})")
        cv = r.gaps.std(ddof=1) / mean
        ax2.set_title(f"Écarts entre spikes (CV = {cv:.2f})")
        ax2.legend()
    ax2.set_xlabel(r.unit)
    ax2.grid(alpha=0.3)

    ax3 = fig.add_subplot(gs[1, 1])
    w = 0.5 * r.nominal
    labels = [f"{b * w:.0f}-{(b + 1) * w:.0f}" if b < HAZARD_BINS - 1 else f"{b * w:.0f}+"
              for b in range(HAZARD_BINS)]
    with np.errstate(divide="ignore", invalid="ignore"):
        rate = np.where(r.haz_exposure > 0, r.haz_events / r.haz_exposure, np.nan)
    mean_rate = r.haz_events.sum() / max(r.haz_exposure.sum(), 1)
    ax3.bar(labels, rate / mean_rate if mean_rate else rate, color="#f59e0b")
    ax3.axhline(1.0, color="#1e3a8a", ls="--", label="taux moyen observé")
    ax3.set_title("Probabilité de spike selon l'âge (1 = moyenne ; plat = sans mémoire)")
    ax3.set_xlabel(f"{r.unit} depuis le dernier spike")
    ax3.legend()
    ax3.grid(alpha=0.3, axis="y")

    fig.savefig(out, dpi=110)
    return out


def demo_series(nominal, n, seed=7):
    """Série synthétique de type Boom : spikes haussiers sans mémoire + dérive baissière."""
    rng = np.random.default_rng(seed)
    moves = rng.normal(-0.002, 0.004, n)
    spikes = rng.random(n) < 1.0 / nominal
    moves[spikes] = rng.uniform(1.0, 4.0, spikes.sum())
    prices = 10000 + np.cumsum(moves)
    times = pd.date_range("2026-01-01", periods=n, freq="s")
    return pd.DataFrame({"time": times, "close": prices}), "ticks"


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", nargs="?", help="export CSV de MetaTrader 5")
    p.add_argument("--direction", choices=["auto", "up", "down", "both"], default="auto")
    p.add_argument("--threshold", type=float, default=None,
                   help="multiple de l'amplitude normale (15 ticks, 4 bougies par défaut)")
    p.add_argument("--window", type=int, default=None,
                   help="fenêtre de l'amplitude normale (200 ticks, 20 bougies par défaut)")
    p.add_argument("--merge", type=int, default=None,
                   help="fusionner les spikes distants de <= N unités (3 ticks, 1 bougie)")
    p.add_argument("--nominal", type=int, default=None,
                   help="période nominale ; lue dans le nom du fichier sinon")
    p.add_argument("--out", default=None, help="image PNG de sortie")
    p.add_argument("--demo", type=int, metavar="N",
                   help="générer une série synthétique Boom N au lieu de lire un CSV")
    a = p.parse_args()

    if a.demo:
        df, unit = demo_series(a.demo, 40 * a.demo)
        name = f"Démo Boom {a.demo}"
    elif a.csv:
        df, unit = read_mt5_csv(a.csv)
        name = a.csv.rsplit("/", 1)[-1]
    else:
        p.error("indiquer un fichier CSV ou --demo N")

    direction = a.direction
    if direction == "auto":
        low = name.lower()
        if any(k in low for k in ("boom", "gainx")):
            direction = "up"
        elif any(k in low for k in ("crash", "painx")):
            direction = "down"
        else:
            direction = "both"
    nominal = a.nominal or a.demo
    if not nominal:
        m = re.search(r"(\d{3,4})", name)
        nominal = int(m.group(1)) if m else 1000
    ticks = unit == "ticks"
    threshold = a.threshold or (15.0 if ticks else 4.0)
    window = a.window or (200 if ticks else 20)
    merge = a.merge if a.merge is not None else (3 if ticks else 1)
    r = analyse(df, unit, direction, threshold, window, merge, nominal)
    if not ticks and a.nominal is None and len(r.gaps) > 1:
        # En bougies, la période nominale en ticks ne s'applique pas : on prend
        # l'écart moyen observé comme référence pour les tranches d'âge.
        nominal = max(int(round(r.gaps.mean())), 2)
        r = analyse(df, unit, direction, threshold, window, merge, nominal)
    print(f"{name}  (sens : {direction}, seuil : {threshold} x, nominal : {nominal})")
    print(report(r))
    out = a.out or re.sub(r"\.csv$", "", name, flags=re.I).replace(" ", "_") + "_spikes.png"
    print(f"Graphique : {plot(r, name, out)}")


if __name__ == "__main__":
    main()
