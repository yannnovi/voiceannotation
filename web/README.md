# voiceannotate — version web

La même application, dans un navigateur : on dépose un MP3 ou un WAV, le
serveur le transcrit et attribue chaque passage à une voix, puis on regroupe,
renomme, réattribue et exporte exactement comme dans l'interface Tk.

```sh
docker compose up -d --build     # depuis la racine du dépôt
docker compose logs -f          # suivre les journaux
docker compose down             # arrêter (les données sont conservées)
```

puis <http://localhost:8000>. Au premier lancement il n'y a aucun modèle :
*Download a model…*, dans le panneau de droite, récupère le modèle de
reconnaissance et le modèle de locuteurs (≈ 55 Mo pour le français léger).

## Ce qui est repris de l'application native

Tout ce que propose l'interface Tk, avec les mêmes libellés :

| Application native | Version web |
|---|---|
| *Browse…* / *File ▸ Open audio file* (Ctrl+O) | idem, plus le glisser-déposer sur le champ du fichier |
| *Transcribe*, *Cancel* (Ctrl+R) | idem ; *Cancel* conserve les passages déjà reconnus |
| Passages qui s'affichent au fur et à mesure, barre de progression, vitesse | idem, en direct |
| Onglets *Segments* et *Running text* | idem |
| Panneau *Speakers* : temps de parole, nombre de passages, *Rename* | idem |
| Clic droit sur un passage : *Assign to…*, *New speaker* | idem |
| *Sensitivity*, *Number of speakers*, *Minimum length*, *Regroup* | idem, instantané |
| Préfixe des locuteurs (`--speaker-prefix` de la ligne de commande) | champ *Speaker label* |
| *Vosk models* : modèle de reconnaissance, modèle de locuteurs facultatif | menus déroulants des modèles installés |
| *Download a model…* : catalogue Vosk, filtre par langue, *installed* | idem, huit plages simultanées |
| Texte enregistré à côté de l'audio, tenu à jour | écrit à côté de l'audio téléversé ; *Save transcript* (Ctrl+S) le télécharge |
| *File ▸ Export as* : txt, srt, vtt, json, csv | idem |
| Réglages mémorisés dans `~/.voiceannotate.conf` | mémorisés par navigateur, côté serveur |

S'y ajoute *Help ▸ Earlier transcriptions*, qui rouvre ou supprime les
transcriptions précédentes : sur un serveur, on revient à un travail d'hier
sans avoir gardé l'onglet ouvert.

## Les deux limites

**Le serveur ne transcrit jamais plus de quatre fichiers à la fois.** C'est une
limite de la machine : chaque transcription garde un modèle Vosk en mémoire et
occupe un cœur, et une cinquième ne ferait que ralentir les quatre autres. Au-delà,
les fichiers attendent dans une file. La page affiche la place qu'on y occupe
(*Waiting: number 2 in the queue*, *1 ahead in the queue · 4/4 slots busy*) et
le badge en haut à droite indique en permanence l'occupation du serveur ; une
transcription en attente démarre seule dès qu'une place se libère, et peut
être annulée avant.

**Un utilisateur ne transcrit qu'un fichier à la fois.** C'est une règle
d'équité : sans elle, une seule personne pourrait occuper les quatre places.
Pendant qu'une transcription est en cours ou en attente, *Transcribe* est
désactivé et en donne la raison au survol ; un deuxième onglet du même
utilisateur retrouve la transcription en cours plutôt que d'en lancer une
autre. Le serveur refuse de toute façon (HTTP 409) : le bouton désactivé est
une politesse, pas la protection.

Un « utilisateur » est un navigateur, identifié par un cookie : il n'y a pas
de comptes.

Les deux valeurs se règlent dans `docker-compose.yml`, à la racine du dépôt :

| Variable | Défaut | Rôle |
|---|---|---|
| `VA_MAX_CONCURRENT` | `4` | transcriptions simultanées, tous utilisateurs confondus |
| `VA_MAX_PER_USER` | `1` | transcriptions simultanées par utilisateur |
| `VA_MAX_UPLOAD_MB` | `512` | taille maximale d'un fichier |
| `VA_MAX_JOBS_PER_USER` | `20` | transcriptions conservées par utilisateur ; les plus anciennes sont supprimées |
| `VA_ALLOW_MODEL_DOWNLOAD` | `1` | `0` pour interdire le téléchargement de modèles depuis la page |
| `VA_EXTRA_MODEL_DIRS` | — | répertoires de modèles supplémentaires, séparés par `:` |

Un modèle complet occupe 1 à 2 Go en mémoire, et quatre transcriptions en
chargent quatre. La limite de mémoire du fichier compose (10 Go) est à
relever avant `VA_MAX_CONCURRENT`.

## Architecture

```
navigateur ──HTTP / SSE──▶ FastAPI (web/backend) ──lance──▶ voiceannotate-cli ×4 au plus
                              │                                  │
                              └── transcript en mémoire ◀── JSON + empreintes vocales
```

Le moteur est **le même binaire C++** que l'application native, compilé dans
l'image par `make cli`. Chaque transcription est un processus
`voiceannotate-cli`, qui rend compte de sa progression ligne par ligne en JSON
(`--progress-json`) et écrit un transcript qui garde les empreintes vocales
(`--embeddings`). Le processus se termine avec le fichier, et la mémoire du
modèle avec lui.

Tout ce qui suit — regrouper, renommer, réattribuer, exporter — ne touche plus
l'audio et n'a besoin d'aucun modèle : c'est fait en Python, sur le transcript
conservé. C'est ce qui rend *Regroup* instantané, comme dans l'application
native, sans garder un modèle en mémoire par utilisateur.

`web/backend/transcript.py` et `web/backend/diarize.py` reprennent donc
`src/core/transcript.cpp` et le regroupement de `src/stt/diarizer.cpp`. Une
reprise qui dériverait sans bruit serait pire que pas de reprise du tout : un
export depuis le navigateur ne correspondrait plus à celui de l'application
native. La parité est vérifiée, pas supposée — voir *Tests*.

La progression arrive par *Server-Sent Events* ; le premier message d'un flux
est toujours l'état complet, si bien qu'une page rechargée en cours de route
reprend exactement où elle en était. Seul l'onglet visible garde un flux
ouvert : un navigateur n'ouvre que six connexions HTTP/1.1 vers un même
serveur, et mesuré, six flux ouverts suffisent à bloquer toute autre requête.

Un seul processus uvicorn, volontairement : la file et les deux limites vivent
dans sa mémoire, et un deuxième processus en aurait sa propre copie — la limite
de quatre deviendrait huit sans que rien ne le signale. Ce n'est pas un goulet :
le travail est fait par les processus enfants.

### Ajouts au programme en ligne de commande

Trois options, qui ne changent rien quand on ne les donne pas :

- `--embeddings` : le JSON garde `speaker_vector` et `speaker_frames` pour
  chaque passage, de quoi regrouper les voix plus tard sans l'audio ;
- `--progress-json` : la progression sur la sortie d'erreur, un objet JSON par
  ligne (`status`, `progress`, `segment`, `finished`, `failed`, `written`) ;
- Ctrl-C (ou SIGTERM) arrête au prochain bloc d'audio et écrit quand même ce
  qui a été reconnu — ce que fait le bouton *Cancel*.

### Données

Tout ce qui est écrit va dans le volume `/var/lib/voiceannotate` : fichiers
téléversés, transcripts, réglages, et les modèles téléchargés, qui survivent
ainsi à une reconstruction de l'image. Une transcription terminée survit à un
redémarrage, noms et empreintes compris. Une transcription interrompue par un
redémarrage revient marquée en échec, ce qui est la vérité : son processus a
disparu.

Pour utiliser des modèles déjà récupérés par `make models`, décommentez dans
`docker-compose.yml` le second volume (`./models:/opt/models:ro`) et la ligne
`VA_EXTRA_MODEL_DIRS: /opt/models`.

Le port se change sans toucher au fichier : `VA_PORT=9000 docker compose up -d`.

## Limites

- **Image x86_64 uniquement.** Vosk ne publie qu'une bibliothèque Linux, pour
  x86_64 ; il n'existe pas d'archive aarch64. Sur un Mac Apple Silicon ou un
  serveur ARM, l'image tourne donc en émulation — le fichier compose le
  précise, rien à retenir. Mesuré en émulation sur un Mac M-series : environ
  19× le temps réel avec le modèle français léger, soit 4 minutes d'audio
  transcrites en 12 à 13 secondes.
- **Pas d'authentification ni de HTTPS.** Pour une exposition hors d'un réseau
  de confiance, placez un reverse proxy devant (nginx, Caddy, Traefik) ; les
  en-têtes nécessaires au flux de progression sont déjà envoyés
  (`X-Accel-Buffering: no`).
- Les limites de l'application native s'appliquent telles quelles : MP3 et WAV
  uniquement, découpage des passages sur les silences, pas de lecture audio.

## Tests

```sh
python3 web/tests/run_tests.py
```

Aucun framework de test, pour la même raison que côté C++. 104 vérifications :
formats d'export, horodatages, renommage et réattribution, regroupement, et
les deux limites — neuf transcriptions simultanées de neuf utilisateurs
(quatre tournent, cinq attendent avec leur rang, jamais plus de quatre en même
temps), une deuxième soumission du même utilisateur refusée, une annulation en
file d'attente. Le groupe HTTP est sauté si FastAPI n'est pas installé.

La **parité avec le C++** se vérifie en comparant deux sorties :

```sh
docker run --rm -v "$PWD":/repo:ro -w /repo gcc:13 sh -c \
  'g++ -std=c++17 -O2 -Isrc -o /tmp/h web/tests/parity_harness.cpp \
     src/core/transcript.cpp src/stt/diarizer.cpp src/util/json.cpp && /tmp/h' > cpp.txt
python3 web/tests/parity.py > python.txt
diff cpp.txt python.txt && echo identique
```

Les deux côtés construisent le même transcript à partir du même générateur,
puis écrivent le regroupement obtenu sous 45 réglages (sensibilité × durée
minimale × nombre de locuteurs) et les cinq formats d'export. Les deux sorties
sont identiques octet pour octet.

L'image exécute en outre `make check-core` pendant sa construction : une image
qui embarquerait un moteur cassé ne se construit pas.
