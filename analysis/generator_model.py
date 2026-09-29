#!/usr/bin/env python3
"""Reconstruit le modèle du générateur d'un indice à spikes à partir de ses ticks.

Le modèle ajusté est :
  - dérive du prix milieu entre spikes : log-retour par tick = s * (d0 + d1 * âge)
    (s = -1 pour un indice à spikes haussiers, +1 pour baissiers)
  - spread relatif (ask - bid) / bid : fonction de l'âge (table)
  - probabilité de spike par tick : h(âge) = a + b * âge
  - taille du spike (log) : sqrt(A + B * écart) * X, X aléatoire indépendant

Le script vérifie ensuite :
  - la compensation h(âge) * E[saut | âge] = dérive(âge), qui fait du prix
    milieu une martingale (aucune espérance de gain avant coûts) ;
  - que les tirages (écarts, tailles) ne dépendent ni du passé ni de l'horloge ;
  - qu'une simulation du modèle reproduit les statistiques observées.

Exemple :
  python generator_model.py "MAX GainX 1000.csv"
"""

import argparse
import re

import numpy as np
import pandas as pd

from spike_stats import analyse, read_mt5_csv


def ages_from_spikes(n, spike_idx):
    ages = np.empty(n, dtype=int)
    prev = 0
    for x in np.append(spike_idx, n):
        ages[prev:x] = np.arange(x - prev)
        prev = x
    return ages


def fit_linear_hazard(events, exposure, max_age):
    """Maximum de vraisemblance de h(a) = a0 + a1 * a, par grilles successives."""
    age = np.arange(max_age)
    ev, ex = events[:max_age], exposure[:max_age]
    rate = ev.sum() / ex.sum()
    lo0, hi0, lo1, hi1 = 0.0, 3 * rate, 0.0, 6 * rate / max(max_age, 1)
    best = None
    for _ in range(4):
        for a0 in np.linspace(lo0, hi0, 41):
            for a1 in np.linspace(lo1, hi1, 41):
                h = np.clip(a0 + a1 * age, 1e-12, 0.999)
                ll = (ev * np.log(h) + (ex - ev) * np.log1p(-h)).sum()
                if best is None or ll > best[0]:
                    best = (ll, a0, a1)
        _, a0, a1 = best
        w0, w1 = (hi0 - lo0) / 10, (hi1 - lo1) / 10
        lo0, hi0, lo1, hi1 = max(a0 - w0, 0), a0 + w0, max(a1 - w1, 0), a1 + w1
    return best[1], best[2]


def fit_size(log_jump, gap):
    """|log saut| = sqrt(A + B * écart) * X, avec médiane(X) = 1."""
    y = np.log(log_jump)
    s2 = np.median(log_jump) ** 2
    best = None
    for A in np.linspace(0.02 * s2, 2 * s2, 60):
        for B in np.linspace(0, 4 * s2 / np.median(gap), 60):
            r = y - 0.5 * np.log(A + B * gap)
            sse = ((r - np.median(r)) ** 2).sum()
            if best is None or sse < best[0]:
                best = (sse, A, B, np.median(r))
    _, A, B, c = best
    scale = np.exp(2 * c)          # ramène la médiane de X à 1
    A, B = A * scale, B * scale
    X = log_jump / np.sqrt(A + B * gap)
    return A, B, X


def perm_pvalue(x, y, rng, k=10, n_perm=300):
    """Test d'indépendance chi2 sur les rangs, calibré par permutation."""
    def rank(v):
        return (np.argsort(np.argsort(v)) + 0.5) / len(v)

    def chi(u, v):
        h, _, _ = np.histogram2d(u, v, bins=k, range=[[0, 1], [0, 1]])
        e = len(u) / k / k
        return ((h - e) ** 2 / e).sum()

    u, v = rank(x), rank(y)
    obs = chi(u, v)
    null = np.array([chi(u, rng.permutation(v)) for _ in range(n_perm)])
    return (null >= obs).mean()


def simulate(a0, a1, A, B, X, n_spikes, rng):
    gaps, sizes = [], []
    age = 0
    while len(gaps) < n_spikes:
        age += 1
        if rng.random() < a0 + a1 * (age - 1):
            gaps.append(age)
            sizes.append(np.sqrt(A + B * age) * rng.choice(X))
            age = 0
    return np.array(gaps), np.array(sizes)


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("csv", help="export de ticks (time_msc,bid,ask ou format MT5)")
    p.add_argument("--direction", choices=["auto", "up", "down"], default="auto")
    a = p.parse_args()

    name = a.csv.rsplit("/", 1)[-1]
    direction = a.direction
    if direction == "auto":
        low = name.lower()
        direction = "up" if any(k in low for k in ("boom", "gainx")) else "down"
    m = re.search(r"(\d{3,4})", name)
    nominal = int(m.group(1)) if m else 1000

    raw = pd.read_csv(a.csv) if "time_msc" in open(a.csv).readline() else None
    if raw is not None:
        t = raw["time_msc"].to_numpy()
        bid, ask = raw["bid"].to_numpy(), raw["ask"].to_numpy()
    else:
        df, _ = read_mt5_csv(a.csv)
        t = df["time"].to_numpy().astype("datetime64[ms]").astype(np.int64)
        bid, ask = df["close"].to_numpy(), None

    df = pd.DataFrame({"time": pd.to_datetime(t, unit="ms"), "close": bid})
    r = analyse(df, "ticks", direction, 15.0, 200, 3, nominal)
    idx = r.spike_idx
    n = len(bid)
    ages = ages_from_spikes(n, idx)
    rng = np.random.default_rng(0)
    print(f"{name} : {n} ticks, {len(idx)} spikes")

    # 1. Dérive entre spikes (prix milieu si l'ask est connu)
    mid = (bid + ask) / 2 if ask is not None else bid
    lr = np.zeros(n)
    lr[1:] = np.log(mid[1:] / mid[:-1])
    ok = np.ones(n, bool)
    ok[0] = False
    ok[idx] = False
    ok &= np.diff(t, prepend=t[0]) < 1500      # ignorer les reprises après une pause
    d1, d0 = np.polyfit(ages[ok], lr[ok], 1)
    print(f"\n1. Dérive par tick (log) : {d0:+.3e} {d1:+.3e} x âge")

    # 2. Spread relatif selon l'âge
    if ask is not None:
        rel = (ask - bid) / bid
        cells = [f"{q}:{np.median(rel[ages == q]):.2e}"
                 for q in (50, 200, 300, 500, 800, 1200) if (ages == q).sum() > 30]
        print("2. Spread relatif médian par âge :", "  ".join(cells))

    # 3. Probabilité de spike par tick
    gap = np.array([ages[i - 1] + 1 for i in idx[1:]])
    max_age = int(np.percentile(gap, 99.5))
    events = np.bincount(gap - 1, minlength=max_age + 1).astype(float)
    exposure = np.bincount(ages[idx[0]:], minlength=max_age + 1).astype(float)
    a0, a1 = fit_linear_hazard(events, exposure, max_age)
    print(f"3. Probabilité de spike par tick : {a0:.3e} + {a1:.3e} x âge")

    # 4. Taille des spikes
    jump = np.abs(np.log(bid[idx[1:]] / bid[idx[1:] - 1]))
    A, B, X = fit_size(jump, gap)
    q = np.percentile(X, [1, 5, 25, 75, 95, 99])
    print(f"4. |log saut| = sqrt({A:.3e} + {B:.3e} x écart) x X ;"
          f" X quantiles 1/5/25/75/95/99 % : {np.round(q, 2)}")

    # 5. Compensation : le prix milieu est-il une martingale ?
    print("5. Compensation h(âge) x E[saut] / |dérive| :")
    for age in (0, 200, 500, 1000):
        exp_jump = np.sqrt(A + B * (age + 1)) * X.mean()
        drift = abs(d0 + d1 * age)
        print(f"   âge {age:5d} : {(a0 + a1 * age) * exp_jump / drift:.2f}  (1.00 = martingale)")

    # 6. Le hasard est-il prévisible ?
    ts = t[idx[1:]] // 1000
    tests = {
        "écart -> écart suivant": (gap[:-1], gap[1:]),
        "taille -> taille suivante": (X[:-1], X[1:]),
        "écart -> taille du même spike": (gap, X),
        "taille -> écart suivant": (X[:-1], gap[1:]),
        "heure -> écart": ((ts // 3600) % 24 + rng.random(len(ts)) * 0.1, gap),
        "seconde -> écart": (ts % 60 + rng.random(len(ts)) * 0.1, gap),
    }
    print("6. Tests d'indépendance (p-valeur ; < 0,01 serait suspect) :")
    for label, (x, y) in tests.items():
        print(f"   {label:32s} p = {perm_pvalue(x, y, rng):.3f}")

    # 7. Validation par simulation
    sg, ss = simulate(a0, a1, A, B, X, len(gap), rng)
    print("7. Observé vs simulé :")
    print(f"   écart moyen {gap.mean():.0f} vs {sg.mean():.0f} ; CV {gap.std() / gap.mean():.3f}"
          f" vs {sg.std() / sg.mean():.3f} ; écart p95 {np.percentile(gap, 95):.0f}"
          f" vs {np.percentile(sg, 95):.0f}")
    print(f"   |log saut| médian {np.median(jump):.5f} vs {np.median(ss):.5f} ;"
          f" p95 {np.percentile(jump, 95):.5f} vs {np.percentile(ss, 95):.5f}")


if __name__ == "__main__":
    main()
