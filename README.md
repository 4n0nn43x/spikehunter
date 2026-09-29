# spikehunter

Détection de spikes sur les indices synthétiques Boom / Crash (Deriv, MetaTrader 5).

## Contenu

| Fichier | Rôle |
| --- | --- |
| `mql5/Indicators/SpikeHunter.mq5` | Indicateur MT5 : détecte chaque spike au tick près, place une flèche sur le graphique, alerte en direct et affiche les statistiques d'intervalle. |
| `mql5/Experts/SpikeHunterEA.mq5` | EA : entre à un âge donné du cycle (ticks depuis le dernier spike), soit dans le sens du spike, soit dans le sens de la dérive, et sort après le spike ou au bout d'une durée maximale. |
| `analysis/spike_stats.py` | Même algorithme hors-ligne sur un export CSV de MT5 (ticks ou bougies), avec rapport texte et graphique PNG. |

## Méthode

Un tick est un spike quand son mouvement dans le sens attendu (haut pour Boom,
bas pour Crash, détecté d'après le nom du symbole) dépasse `seuil x` l'amplitude
moyenne des ticks normaux récents (moyenne exponentielle qui exclut les spikes).
Les ticks consécutifs d'un même spike sont fusionnés.

L'outil mesure aussi si le timing a une valeur prédictive :

- **CV des écarts entre spikes** : proche de 1, le processus est sans mémoire
  (Poisson). Le nombre de ticks écoulés depuis le dernier spike ne dit alors rien
  sur le prochain.
- **Taux de spike selon l'âge** : barres plates, le spike n'est pas « dû » après
  une longue attente. Barres croissantes, il le devient.
- **Dérive x écart moyen vs spike moyen** : si les deux s'équilibrent, le cycle
  est neutre par construction.

Une étude publique sur environ 15 millions de ticks Deriv donne un CV de 0,987
(Boom 1000) et 1,072 (Crash 1000), avec un taux plat. L'indicateur **détecte et
confirme** les spikes : il ne les prédit pas. Utilise ces statistiques pour
vérifier ce qu'il en est sur tes propres données avant de bâtir une stratégie.

## Installation de l'indicateur

1. Copier `mql5/Indicators/SpikeHunter.mq5` dans `MQL5/Indicators/` (menu
   Fichier > Ouvrir le dossier des données dans MT5).
2. Le compiler dans MetaEditor (F7), puis le glisser sur un graphique Boom ou Crash.

Paramètres principaux : sens, multiple du seuil (15 par défaut), taille minimale
en points, jours d'historique analysés au démarrage, alertes et notifications
push, export CSV (`MQL5/Files/spikehunter_<symbole>.csv`).

## Analyse d'un CSV

Export depuis MT5 : Affichage > Symboles > onglet Ticks ou Barres > Exporter.

```bash
pip install numpy pandas matplotlib
python analysis/spike_stats.py "Boom 1000 Index_ticks.csv"
python analysis/spike_stats.py "Crash 500 Index_M1.csv" --out crash500.png
python analysis/spike_stats.py --demo 1000     # série synthétique de test
```

Options : `--direction up|down|both`, `--threshold`, `--window`, `--merge`,
`--nominal`. Sur des bougies, le seuil par défaut est 4 x le range moyen.

## EA

Copier `mql5/Experts/SpikeHunterEA.mq5` dans `MQL5/Experts/`, compiler, puis le
lancer dans le testeur de stratégie en mode « Chaque tick basé sur les ticks
réels ». Paramètres : stratégie (attraper le spike / suivre la dérive), âge
d'entrée, durée maximale, délai de sortie après le spike, lot, stop loss, take
profit. Sur les données GainX/PainX analysées (voir `analysis/RESULTS.md`),
aucune combinaison testée n'a eu d'espérance positive après spread.

## Balayer tous les actifs d'un courtier (Deriv, Weltrade...)

1. Dans MT5, afficher dans le Market Watch les symboles à tester, puis lancer le
   script `mql5/Scripts/ExportTicks.mq5` (14 jours par défaut). Les CSV arrivent
   dans `MQL5/Files/spikehunter_ticks/`.
2. Lancer le scanner sur ce dossier :

```bash
python analysis/scan_all.py "<dossier MQL5/Files/spikehunter_ticks>" --out resume.csv
```

Pour chaque actif, le scanner teste environ 200 règles (momentum, retour à la
moyenne, âge du cycle de spikes). Il les calibre sur les 60 premiers pour cent
des ticks et vérifie la meilleure sur les 40 derniers, avec le vrai spread. Il
n'affiche « GAGNANT » que si le gain de test dépasse 2 erreurs-types. Sur des
séries de contrôle, il trouve un avantage caché et ne trouve rien sur une marche
aléatoire. Le fichier `resume.csv` est petit : c'est lui qu'il faut partager,
pas les ticks.
