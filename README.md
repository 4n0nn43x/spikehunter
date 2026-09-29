# spikehunter

Détection de spikes sur les indices synthétiques Boom / Crash (Deriv, MetaTrader 5).

## Contenu

| Fichier | Rôle |
| --- | --- |
| `mql5/Indicators/SpikeHunter.mq5` | Indicateur MT5 : détecte chaque spike au tick près, place une flèche sur le graphique, alerte en direct et affiche les statistiques d'intervalle. |
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
