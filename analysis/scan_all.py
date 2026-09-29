#!/usr/bin/env python3
"""Balaye un dossier d'exports de ticks et cherche une règle gagnante par actif.

Chaque fichier doit contenir time_msc,bid,ask (script mql5/Scripts/ExportTicks.mq5).
Pour chaque actif, toutes les règles sont calibrées sur les 60 premiers pour cent
des ticks (TRAIN) puis la meilleure est vérifiée une seule fois sur les 40 derniers
(TEST). Les trades paient le vrai spread : achat à l'ask, vente au bid, avec un
tick de latence entre le signal et l'entrée.

Familles de règles :
  - momentum / retour à la moyenne : signe du mouvement sur L ticks, tenu H ticks ;
  - si l'actif a des spikes : entrée à l'âge A (ticks depuis le dernier spike),
    dans le sens du spike ou de la dérive, tenue H ticks ou jusqu'au spike.

Un actif n'est déclaré GAGNANT que si la règle choisie sur TRAIN est positive
sur TEST de plus de 2 erreurs-types.

Exemple :
  python scan_all.py ~/.wine/.../MQL5/Files/spikehunter_ticks --out resume.csv
"""

import argparse
import glob
import os

import numpy as np
import pandas as pd

TRAIN = 0.6


def load(path):
    df = pd.read_csv(path, usecols=["time_msc", "bid", "ask"])
    df = df[(df.bid > 0) & (df.ask >= df.bid)]
    return df.time_msc.to_numpy(), df.bid.to_numpy(float), df.ask.to_numpy(float)


def find_spikes(mid):
    """Détecte des spikes unidirectionnels : sauts > 30 x le mouvement médian."""
    d = np.diff(mid, prepend=mid[0])
    noise = np.median(np.abs(d[d != 0])) if (d != 0).any() else 0.0
    if noise <= 0:
        return None, None
    up = np.flatnonzero(d > 30 * noise)
    down = np.flatnonzero(d < -30 * noise)
    idx, sign = (up, 1) if len(up) >= len(down) else (down, -1)
    if len(idx) < 40 or len(idx) < 5 * min(len(up), len(down)):
        return None, None
    keep = np.r_[True, np.diff(idx) > 3]          # fusionne les spikes sur plusieurs ticks
    return idx[keep], sign


def trade_pnl(bid, ask, entry, exit_, long_):
    """PnL en points de base du prix, entrée au tick `entry`, sortie au tick `exit_`."""
    pnl = np.where(long_, bid[exit_] - ask[entry], bid[entry] - ask[exit_])
    return 1e4 * pnl / bid[entry]


def stats(p):
    if len(p) < 30:
        return None
    return p.mean(), 2 * p.std(ddof=1) / np.sqrt(len(p)), len(p), (p > 0).mean()


def candidates(t, bid, ask, split):
    n = len(bid)
    mid = (bid + ask) / 2
    out = []

    # 1. Momentum / retour à la moyenne (échantillons sans chevauchement)
    for L in (5, 20, 60, 300):
        for H in (5, 20, 60, 300):
            i = np.arange(L, n - H - 2, H)
            sig = np.sign(mid[i] - mid[i - L])
            i, sig = i[sig != 0], sig[sig != 0]
            for rule, s in (("momentum", sig > 0), ("retour", sig < 0)):
                p = trade_pnl(bid, ask, i + 1, i + 1 + H, s)
                out.append((f"{rule} L={L} H={H}", i, p))

    # 2. Âge du cycle, si l'actif a des spikes
    spikes, sign = find_spikes(mid)
    if spikes is not None:
        nxt = np.r_[spikes[1:], n - 1]
        for A in range(0, 1601, 100):
            start = spikes[:-1] + A + 1
            ok = start < spikes[1:]
            e = start[ok]
            ends = nxt[:-1][ok] + 1                      # un tick après le spike suivant
            ends = np.minimum(ends, n - 1)
            for H in (20, 60, 200, 600, 0):
                ex = ends if H == 0 else np.minimum(e + H, ends)
                valid = ex < n
                label = "jusqu'au spike" if H == 0 else f"H={H}"
                for rule, long_ in (("spike", sign > 0), ("dérive", sign < 0)):
                    p = trade_pnl(bid, ask, e[valid], ex[valid],
                                  np.full(valid.sum(), long_))
                    out.append((f"{rule} âge={A} {label}", e[valid], p))
    return out, (len(spikes) if spikes is not None else 0), sign


def scan(path):
    t, bid, ask = load(path)
    n = len(bid)
    split = int(n * TRAIN)
    cands, n_spikes, sign = candidates(t, bid, ask, split)
    best = None
    for name, idx, p in cands:
        tr = stats(p[idx < split])
        if tr is None:
            continue
        score = tr[0] / max(tr[1], 1e-12)
        if best is None or score > best[0]:
            best = (score, name, idx, p, tr)
    if best is None:
        return None
    _, name, idx, p, tr = best
    te = stats(p[idx >= split])
    spread = 1e4 * np.median((ask - bid) / bid)
    days = (t[-1] - t[0]) / 86400000
    winner = te is not None and te[0] > te[1] and te[0] > 0
    return {
        "actif": os.path.basename(path)[:-4],
        "ticks": n,
        "jours": round(days, 1),
        "spread_pb": round(spread, 2),
        "spikes": n_spikes,
        "sens_spikes": {1: "haut", -1: "bas"}.get(sign, ""),
        "regles_testees": len(cands),
        "meilleure_regle": name,
        "train_pb": round(tr[0], 3),
        "train_2se": round(tr[1], 3),
        "test_pb": round(te[0], 3) if te else None,
        "test_2se": round(te[1], 3) if te else None,
        "test_trades": te[2] if te else 0,
        "test_gagnants_pct": round(100 * te[3], 1) if te else None,
        "verdict": "GAGNANT" if winner else "non",
    }


def main():
    p = argparse.ArgumentParser(description=__doc__,
                                formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("dossier", help="dossier contenant les CSV time_msc,bid,ask")
    p.add_argument("--out", default="scan_resume.csv", help="fichier récapitulatif")
    a = p.parse_args()

    rows = []
    files = sorted(glob.glob(os.path.join(a.dossier, "*.csv")))
    for k, f in enumerate(files, 1):
        try:
            r = scan(f)
        except Exception as exc:          # un fichier illisible ne doit pas tout arrêter
            print(f"[{k}/{len(files)}] {os.path.basename(f)} : erreur {exc}")
            continue
        if r is None:
            print(f"[{k}/{len(files)}] {os.path.basename(f)} : pas assez de données")
            continue
        rows.append(r)
        print(f"[{k}/{len(files)}] {r['actif']:28s} {r['verdict']:8s} "
              f"{r['meilleure_regle']:32s} train {r['train_pb']:+.3f} "
              f"test {r['test_pb']:+.3f} ± {r['test_2se']:.3f} pb/trade "
              f"(spread {r['spread_pb']} pb)")
    if rows:
        pd.DataFrame(rows).sort_values("test_pb", ascending=False).to_csv(a.out, index=False)
        print(f"\nRécapitulatif : {a.out}  ({sum(r['verdict'] == 'GAGNANT' for r in rows)}"
              f" actif(s) gagnant(s) sur {len(rows)})")


if __name__ == "__main__":
    main()
