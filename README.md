# voiceannotate

Transcription de fichiers MP3 ou WAV avec **annotation des locuteurs** : le
texte est découpé en passages, et chaque passage est attribué à une voix.

Le moteur de reconnaissance est [Vosk](https://alphacephei.com/vosk/) (Kaldi),
qui fonctionne entièrement hors ligne. L'interface est en Tcl/Tk, le reste en
C++17, et tout se construit avec un seul `make` sur Windows, Linux et macOS.

```
[00:00:00.120] Speaker 1:
  bonjour et merci beaucoup d'être venu aujourd'hui pour cet entretien

[00:00:04.830] Speaker 2:
  merci à vous je suis très heureuse d'être ici ce matin
```

## Ce que fait le programme

- Décode le MP3 en interne (minimp3), sans dépendre de `ffmpeg` ni d'un codec
  système. Le WAV est également lu nativement.
- Rééchantillonne en 16 kHz mono, ce qu'attendent les modèles Vosk, avec un
  filtre sinus cardinal fenêtré.
- Transcrit le texte avec les horodatages mot à mot.
- Regroupe les voix à partir des empreintes vocales (« x-vectors ») produites
  par le modèle de locuteurs de Vosk.
- Permet d'ajuster le regroupement **sans retraiter l'audio**, de renommer les
  locuteurs et de corriger l'attribution d'un passage à la main.
- Enregistre le texte à côté du fichier audio, sous le même nom en `.txt`, dès
  que la transcription se termine.
- Exporte aussi en SRT, WebVTT, JSON (avec les mots et leurs timings) ou CSV.

L'interface est en anglais ; cette documentation est en français.

## Prérequis

| Plateforme | À installer |
|---|---|
| Windows | [MSYS2](https://www.msys2.org/), puis dans le shell **MINGW64** :<br>`pacman -S mingw-w64-x86_64-gcc mingw-w64-x86_64-make mingw-w64-x86_64-pkgconf mingw-w64-x86_64-tcl mingw-w64-x86_64-tk make unzip` |
| Debian / Ubuntu | `sudo apt install build-essential pkg-config tcl-dev tk-dev curl unzip` |
| Fedora | `sudo dnf install gcc-c++ make pkgconf tcl-devel tk-devel curl unzip` |
| Arch | `sudo pacman -S base-devel tcl tk curl unzip` |
| macOS | Outils en ligne de commande Xcode, puis `brew install tcl-tk@8 pkg-config` |

`tcl-tk@8` et non `tcl-tk` : la formule `tcl-tk` installe désormais Tcl/Tk 9,
qui n'a ni fichiers `pkg-config` ni la même API C que celle utilisée ici. Le
Makefile détecte automatiquement `tcl-tk@8` via `brew --prefix`.

## Construction

```sh
make deps      # télécharge minimp3 et la bibliothèque Vosk dans l'arborescence
make models    # télécharge un modèle français et le modèle de locuteurs (~55 Mo)
make           # construit bin/voiceannotate et bin/voiceannotate-cli
make run       # lance l'interface
```

`make deps` est déclenché automatiquement par `make` si nécessaire ; la ligne
ci-dessus sert surtout à le faire explicitement.

### Préparer l'environnement

`scripts/setup-env.sh` met la chaîne de compilation en place avant de lancer
`make`. C'est surtout utile sur Windows depuis un shell qui n'est **pas** celui
de MSYS2 — Git Bash, par exemple, n'a ni `gcc` ni `make` : le script retrouve
MSYS2 (scoop, `C:\msys64`, ou `MSYS2_ROOT`), ajoute son répertoire `mingw64\bin`
au `PATH`, oriente `pkg-config` vers Tcl/Tk et utilise `mingw32-make`.

```sh
scripts/setup-env.sh                # prépare, puis construit
scripts/setup-env.sh check          # prépare, puis "make check" (n'importe quelle cible)
scripts/setup-env.sh --verify-only  # affiche ce qui a été détecté, sans rien construire
scripts/setup-env.sh --install-deps # installe d'abord ce qui manque (pacman)
. scripts/setup-env.sh              # « sourcé » : configure le shell, ensuite "make" suffit
```

Sur Linux et macOS il n'y a rien à préparer : le script se contente alors de
vérifier les prérequis et d'indiquer la commande d'installation de ce qui
manque.

Pour un autre modèle de langue :

```sh
VOSK_LANG_MODEL=vosk-model-small-en-us-0.15 make models
scripts/fetch-deps.sh model vosk-model-fr-0.22    # modèle français complet, 1,4 Go
```

La liste des modèles disponibles est sur <https://alphacephei.com/vosk/models>.

### Cibles utiles

| Cible | Effet |
|---|---|
| `make` | les deux binaires |
| `make cli` | uniquement le binaire en ligne de commande (aucune dépendance Tk) |
| `make check` | tests du cœur C++ et test de fumée de l'interface |
| `make DEBUG=1` | `-O0 -g` |
| `make print-config` | affiche la plateforme et les options détectées |
| `make install PREFIX=~/.local` | installe les binaires et `app.tcl` |
| `make distclean` | supprime aussi les téléchargements (les modèles sont conservés) |

Si Tcl/Tk est installé ailleurs que là où `pkg-config` le trouve :

```sh
make TCLTK_CFLAGS="-I/chemin/include" TCLTK_LIBS="-L/chemin/lib -ltcl8.6 -ltk8.6"
```

## Utilisation

### Lancer l'interface

Depuis le shell où vous avez construit le projet (**MSYS2 MINGW64** sur
Windows, un terminal ordinaire ailleurs) :

```sh
make run                        # ou : bin/voiceannotate [fichier.mp3]
```

**Sur Windows, hors du shell MSYS2** — depuis l'Explorateur ou un raccourci —
utilisez `scripts\voiceannotate.cmd`, qui peut être double-cliqué. Il ne fait
que mettre les DLL de Tcl/Tk dans le `PATH` avant de démarrer l'application :
`bin\voiceannotate.exe` lancé directement s'arrête aussitôt avec une erreur de
DLL manquante, car un double-clic n'hérite pas de l'environnement MINGW64.
Pour un raccourci sur le Bureau, faites-le pointer sur ce `.cmd`.

Si MSYS2 n'est pas à un emplacement courant, définissez `MINGW64_BIN` sur son
répertoire `mingw64\bin`.

### Se servir de l'interface

L'interface est en anglais.

1. Choisissez un fichier audio (*Browse…*).
2. Vérifiez les deux modèles dans le panneau de droite (*Vosk models*). S'ils
   ont été téléchargés par `make models`, ils sont détectés automatiquement ;
   sinon, *Download a model…* les récupère depuis l'interface.
3. **Transcribe**. Les passages apparaissent au fur et à mesure.
4. Ajustez le regroupement, renommez les locuteurs. Pour un autre format,
   *File ▸ Export as*.

### Télécharger un modèle depuis l'interface

*Download a model…*, dans le panneau *Vosk models*, ouvre la liste publiée par
Vosk : une quarantaine de langues, filtrables avec le menu du haut. Le modèle
de locuteurs y figure quelle que soit la langue choisie, puisqu'il sert aux
deux. Les modèles sont classés du plus léger au plus lourd, et ceux déjà
présents sont marqués *installed*.

Le modèle choisi est téléchargé, décompressé dans `models/`, puis **sélectionné
automatiquement** dans le panneau — un modèle de locuteurs va dans le champ
*Speakers*, tout autre dans *Recognition*. La fenêtre reste utilisable pendant
le transfert, et *Close* propose de l'interrompre s'il est encore en cours.

Cela demande `curl`, présent sur Windows 10 et suivants comme sur macOS et
Linux, et de quoi ouvrir un zip : `unzip` s'il est là, sinon `tar` à condition
qu'il s'agisse de bsdtar — c'est le `tar.exe` livré avec Windows depuis la
version 1803, et celui de macOS. Le `tar` de GNU, usuel sur Linux, ne sait pas
lire un zip et n'est donc pas retenu ; `unzip` y est de toute façon un
prérequis de construction. Si l'application a été installée dans un répertoire
non inscriptible, les modèles vont dans `~/.voiceannotate/models`, où elle les
retrouve au lancement suivant.

Le fichier est demandé en **huit plages simultanées**, puis recollé. Le serveur
de Vosk plafonne chaque connexion aux alentours de 0,7 Mo/s quoi qu'il arrive,
et les connexions s'additionnent : sur une tranche de 48 Mo, une seule
connexion a mis 61 s et huit en ont mis 9. Au-delà de huit le gain s'aplatit,
et c'est déjà beaucoup demander à un service hébergé gratuitement.

Un modèle léger (~40 Mo) suffit pour essayer ; les modèles complets (1 à 2 Go)
transcrivent mieux. Vosk ne publie pas de modèle par pays pour le français : il
n'y en a qu'un, générique. Côté anglais, *US English* et *UK English* sont
distincts.

### Le texte est enregistré tout seul

Quand une transcription se termine, le texte annoté est écrit **à côté du
fichier audio**, sous le même nom avec l'extension `.txt` :

```
entretien.mp3   ->   entretien.txt
```

Le fichier est réécrit à chaque changement qui modifie le texte — un locuteur
renommé, un passage réattribué, un regroupement refait — pour qu'il ne soit
jamais une copie périmée de ce qui est affiché. *File ▸ Save transcript beside
the audio* (Ctrl+S) force l'écriture à tout moment.

Si un fichier porte déjà ce nom, l'application demande confirmation avant de
l'écraser, une seule fois par fichier source. En cas de refus, rien n'est écrit
et *File ▸ Export as* permet de choisir un autre emplacement.

Les chemins des modèles et les réglages sont mémorisés dans
`~/.voiceannotate.conf`. Le fichier porte un numéro de version : s'il a été
écrit par une version antérieure où un réglage n'avait pas le même sens, il est
ignoré et les valeurs par défaut s'appliquent.

### Ligne de commande

Même moteur, sans Tk — pratique sur un serveur ou dans un script.

```sh
bin/voiceannotate-cli \
  --model models/vosk-model-small-fr-0.22 \
  --spk-model models/vosk-model-spk-0.4 \
  --speaker-prefix Locuteur \
  --format srt --output entretien.srt \
  entretien.mp3
```

`--help` liste toutes les options. `VOSK_MODEL` et `VOSK_SPK_MODEL` fournissent
les valeurs par défaut de `--model` et `--spk-model`.

## Régler le regroupement des voix

Le modèle de locuteurs transforme chaque passage en une empreinte de 128
nombres. Deux passages d'une même personne donnent des empreintes proches.
Deux réglages décident du découpage, et **aucune valeur n'est universellement
bonne** : tout dépend des voix, du micro et du bruit de fond.

**Sensitivity** — le seuil de proximité au-delà duquel deux passages sont
attribués à la même personne.

- Deux personnes fusionnées en une → **augmentez** la sensibilité.
- Une personne éclatée en plusieurs → **diminuez**-la.

**Minimum length** — en dessous de ce seuil, un passage est rattaché au
locuteur le plus proche mais n'a pas le droit d'en créer un nouveau. Une
empreinte calculée sur une demi-seconde de parole est bruitée ; l'augmenter est
souvent plus efficace que de toucher à la sensibilité.

**Number of speakers** — si vous le connaissez, imposez-le : le regroupement
s'y tiendra quoi qu'il arrive. Attention, un plafond trop bas force des
fusions arbitraires.

L'effet est net et régulier. Nombre de locuteurs trouvés sur deux
enregistrements aux extrémités de l'échelle de difficulté — un entretien propre
à deux voix bien distinctes, et un podcast de 15 minutes où quatre personnes
partagent un seul micro :

| Sensitivity | Entretien (2 attendus) | Podcast (4 attendus) |
|---|---|---|
| −0,10 | **2** | — |
| 0,00 | **2** | **4** |
| **0,05** (défaut) | **2** | **5** |
| 0,10 | **2** | 9 |
| 0,20 | 4 | 13 |
| 0,35 | 5 | 32 |

La même plage de réglage convient aux deux, ce qui n'allait pas de soi : les
empreintes d'un enregistrement portent toutes une composante commune, due au
micro et à la salle, qui n'apprend rien sur qui parle mais gonfle toutes les
similarités. Le programme la retire avant de comparer les voix, et c'est ce qui
rend le seuil à peu près indépendant de l'enregistrement. Sans ce retrait, le
podcast ci-dessus donnait 29 locuteurs au réglage qui en donnait 2 sur
l'entretien.

Augmenter la durée minimale aplatit encore la courbe sur les enregistrements
difficiles : à 100 (1 s), le podcast donne 5 locuteurs à 0,05 et 11 à 0,20.

**La bonne méthode de travail** : transcrivez une fois, puis utilisez
**Regroup**. Ce bouton rejoue le regroupement sur les empreintes
déjà calculées — c'est instantané, même sur un fichier de plusieurs heures,
alors qu'une transcription complète prend plusieurs minutes. En revanche il
réinitialise les noms personnalisés : après un regroupement, le « locuteur 2 »
n'est plus forcément la même personne.

Un clic droit sur un passage permet enfin de le réattribuer à la main, y
compris à un locuteur entièrement nouveau.

### À quoi s'attendre

Sur un enregistrement propre où les voix sont distinctes — un entretien à deux,
chacun sur son micro — l'attribution est fiable. Sur un enregistrement difficile
— plusieurs voix proches, une seule prise de son, des gens qui se coupent la
parole — aucun réglage ne donnera un découpage parfait, et il faut s'attendre à
reprendre des passages à la main. C'est une limite de la méthode, pas un défaut
de réglage.

## Organisation du code

```
src/
  audio/      décodage MP3 et WAV, rééchantillonnage
  stt/        interface avec Vosk, regroupement des locuteurs
  core/       transcript, exports, pipeline (fil d'exécution de travail)
  tcl/        pont entre le C++ et Tcl
  util/       lecteur/écrivain JSON minimal
  platform/   le seul fichier propre à Windows (point d'entrée WinMain)
tcl/app.tcl   la totalité de l'interface
tests/        tests du cœur C++ et test de fumée de l'interface
```

Le fil d'exécution de travail ne touche jamais à l'interpréteur Tcl : il dépose
ses événements dans une file protégée par un mutex, que l'interface vide depuis
une minuterie `after`. C'est ce qui rend l'ensemble portable sans extension de
threads Tcl.

Le seul code spécifique à Windows est
[src/platform/win_main.cpp](src/platform/win_main.cpp), dix lignes qui fournissent
`WinMain` pour que l'application n'ouvre pas de console. Il n'y a pas un seul
`#ifdef` ailleurs dans les sources.

## Limites connues

- **Le découpage suit les silences.** Vosk clôt un passage quand il détecte un
  silence. Si deux personnes se coupent la parole sans pause, elles se
  retrouveront dans le même passage, donc sous la même étiquette.
- **Pas de lecture audio.** L'application annote, elle ne joue pas le son ;
  cela éviterait d'ajouter une bibliothèque audio différente par plateforme.
- **MP3 et WAV uniquement.** Pour du M4A, de l'OGG ou une piste vidéo,
  convertissez d'abord (`ffmpeg -i source.m4a -ar 16000 -ac 1 sortie.wav`).
- **Chemins non-ASCII.** L'API C de Vosk prend les chemins de modèles en
  `char*` ; gardez les répertoires de modèles en ASCII.
- Vosk affiche quelques avertissements Kaldi au chargement d'un modèle. Ils
  sont normaux et ne peuvent pas être désactivés par l'API.

## Licences

Le code de ce dépôt est à vous. Les composants téléchargés gardent la leur :
[Vosk](https://github.com/alphacep/vosk-api) est sous Apache-2.0,
[minimp3](https://github.com/lieff/minimp3) dans le domaine public (CC0), et
chaque modèle porte la sienne (indiquée sur la page des modèles Vosk).
