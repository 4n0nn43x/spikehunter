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

## Modèle du générateur (`generator_model.py`)

Entre deux spikes, **le prix et le spread sont entièrement déterministes**. Le
chemin se répète d'un cycle à l'autre à environ 3 décimales près. Le hasard ne
porte que sur deux choses : **quand** le spike arrive et **quelle taille** il a.

| | GainX 1000 | PainX 1000 | GainX 2000 | PainX 2000 |
| --- | --- | --- | --- | --- |
| Dérive du milieu par tick (log) | −(0,98e-6 + 0,998e-8·âge) | +(0,99e-6 + 0,998e-8·âge) | −(1,08e-6 + 0,98e-8·âge) | +(0,99e-6 + 1,00e-8·âge) |
| Probabilité de spike par tick | 1,20e-3 + 2,28e-6·âge | 1,20e-3 + 2,33e-6·âge | 6,4e-4 + 0,97e-6·âge | 6,6e-4 + 0,98e-6·âge |
| \|log saut\| | √(9,3e-7 + 8,7e-9·écart)·X | √(9,6e-7 + 8,8e-9·écart)·X | √(3,7e-6 + 3,6e-8·écart)·X | √(3,4e-6 + 3,5e-8·écart)·X |
| Spread relatif | 4,0e-5 jusqu'à ~200 ticks, puis croissant (2,2e-4 à 1 200) | idem | 7,5e-5 jusqu'à ~400, puis croissant | idem |

- La dérive vaut, à arrondi près, **1e-6 + 1e-8 × âge** par tick sur les 4 indices :
  ce sont des constantes choisies par le concepteur.
- X est un facteur aléatoire indépendant de l'écart. Il reste entre environ
  0,53 et 2,05 fois sa médiane (1er et 99e centiles).
- **Compensation** : probabilité de spike × taille moyenne du spike ≈ dérive, à
  chaque âge (ratio 0,92 à 1,06 entre 200 et 1 000 ticks ; environ 1,25 à l'âge 0,
  là où le modèle de taille est le moins précis). Le prix milieu est donc une
  **martingale par construction** : son espérance ne bouge pas, quel que soit le
  moment. Comme le spread s'ajoute, toute stratégie a une espérance négative.
- **Le hasard n'est pas prévisible** avec ce qu'on observe. Les écarts et les tailles
  ne dépendent ni des précédents (tests de permutation, p entre 0,05 et 0,98), ni de
  l'heure, de la minute, de la seconde ou de la parité. Les spikes des 4 indices sont
  indépendants entre eux. Aucun signal n'apparaît avant un spike (spread,
  horodatage, ask). Le seul effet un peu bas (taille → écart suivant) change de
  signe entre l'entraînement et le test : c'est du bruit.
- **Validation** : une simulation du modèle reproduit l'écart moyen (485 contre 486),
  le CV (0,746 contre 0,743), le 95e centile des écarts et les tailles des spikes.

## Recherche d'une stratégie gagnante (protocole entraînement / test)

Tout a été calibré sur les 60 premiers pour cent des ticks, puis vérifié une seule
fois sur les 40 derniers. J'ai testé environ 2 500 combinaisons âge × durée × sens,
les spikes sur plusieurs ticks et leur continuation (0,1 % des spikes seulement),
le rebond après un spike, les liens entre indices, les signaux avant un spike,
et le suivi de la dérive. **Aucune règle n'a une espérance positive**, ni à
l'entraînement ni au test : elles perdent toutes à peu près le spread. C'est
exactement ce que prédit le modèle.
