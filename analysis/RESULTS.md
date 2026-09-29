# Résultats : Weltrade GainX / PainX 1000 et 2000

Données : ticks `time_msc,bid,ask` du 2 août au 25 septembre 2026, environ
4,66 millions de ticks par indice, soit 1 tick par seconde.
Détection : `spike_stats.py` avec un seuil de 15 fois l'amplitude normale d'un tick.
Le résultat est identique avec un seuil de 40, et le plus petit spike fait plus
de 100 fois l'amplitude normale : la détection est donc sans ambiguïté.

## Mesures

| Indice | Spikes | Écart moyen | Médiane | CV | Spread médian | Dérive moyenne / tick |
| --- | --- | --- | --- | --- | --- | --- |
| GainX 1000 | 9 614 | 485 ticks | 407 | 0,75 | 3,4 | −0,34 |
| PainX 1000 | 9 662 | 483 ticks | 408 | 0,74 | 5,6 | +0,56 |
| GainX 2000 | 5 763 | 809 ticks | 684 | 0,72 | 7,3 | −0,59 |
| PainX 2000 | 5 858 | 796 ticks | 671 | 0,73 | 10,6 | +0,90 |

- **Le chiffre du nom n'est pas l'écart moyen.** « 1000 » donne un spike tous
  les 485 ticks environ, « 2000 » tous les 800 environ.
- **Le processus n'est pas sans mémoire**, contrairement à ce qui est publié sur
  Boom/Crash chez Deriv. Le CV vaut environ 0,73. La probabilité d'un spike dans
  les 100 prochains ticks passe d'environ 11 % juste après un spike à 35-45 %
  après 1 500 ticks (GainX/PainX 1000). Il n'y a aucun écart au-delà de
  2 500 ticks (1000) ou de 4 500 ticks (2000).
- **La dérive accélère avec l'âge du cycle.** Sur GainX 1000, elle passe de
  −0,09 point/tick au début du cycle à −0,96 après 1 200 ticks : la vitesse croît
  à peu près linéairement, et le prix suit une courbe parabolique entre deux spikes.
- **La taille du spike croît avec l'attente** (corrélation ≈ 0,63). Sur la
  moyenne, dérive × écart moyen ≈ spike moyen, à 1 % près pour les 4 indices :
  le cycle est neutre par construction.
- Écarts successifs et taille comparée à l'écart suivant : aucune corrélation (|r| < 0,02).

## Backtests (prix bid/ask réels, sortie 1 tick après le spike)

**Acheter le spike** (long GainX / short PainX), en entrant à l'âge A et en
gardant la position jusqu'au spike :

| Entrée à l'âge | GainX 1000 | PainX 1000 | GainX 2000 | PainX 2000 |
| --- | --- | --- | --- | --- |
| 0 | −4,1 ± 3,7 | −3,5 ± 6,0 | −11,3 | −7,4 |
| 600 | −7,0 | −8,6 | −14,0 | −17,0 |
| 1 000 | −8,4 | −2,4 | −7,2 | −22,3 |
| 1 500 | +13,5 ± 44,6 | +5,9 ± 81,4 | −37,1 | −5,2 |

Environ 60 à 70 % de trades gagnants, mais des pertes rares et énormes (jusqu'à
−1 900 points sur GainX 1000). En moyenne, on perd à peu près le spread.

**Suivre la dérive** (short GainX / long PainX) à partir de l'âge A pendant au
plus H ticks, avec 15 combinaisons testées par indice : aucune n'est
significativement positive. Les meilleures sont proches de zéro, l'incertitude
est plus grande que la moyenne, et le fait d'avoir choisi la meilleure sur 15
la gonfle encore. Les variantes courtes gagnent 90 % du temps, mais restent
perdantes en moyenne.

## Conclusion

Le timing n'est pas aléatoire, et l'indicateur peut afficher un « risque de
spike » qui monte réellement avec l'âge. Mais la dérive qui accélère et la taille
des spikes proportionnelle à l'attente compensent exactement ce timing : aucune
entrée testée ne bat le spread sur ces 8 semaines. Un taux de réussite élevé
ne prouve pas un avantage.
