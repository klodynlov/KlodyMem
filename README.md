# KlodyMem

Garde-fou mémoire pour macOS. Surveille la pression réelle, nomme les
coupables, et agit **avant** le dialogue « Votre système a utilisé toute la
mémoire allouée aux applications ».

100 % Swift, zéro dépendance, aucun privilège root.

---

## Pourquoi pas simplement le Moniteur d'activité

Le Moniteur d'activité montre l'instant présent et ne fait rien. KlodyMem
ajoute les trois choses qui manquent :

1. **Une dérivée.** Le swap qui grimpe de 900 Mio/s alors que la marge fond
   prédit l'alerte ; le niveau absolu ne la prédit pas.
2. **Un verdict expliqué.** Pas une jauge, une phrase : *« marge 2,1 Gio ·
   volume VM plein »*.
3. **Une main.** Suspendre, quitter, ou libérer une cible avant un gros job.

## Ce que l'outil mesure, et ce qu'il ignore

Trois signaux se sont révélés trompeurs à la mesure ; ils sont explicitement
neutralisés, avec un test de régression chacun.

| Signal | Statut | Raison |
|---|---|---|
| `phys_footprint` par process | **utilisé** | C'est la colonne « Mémoire » du Moniteur d'activité. Le RSS sous-estime lourdement les process MLX/Metal. |
| marge = libre + caches récupérables | **utilisé** | Ce qui est réellement allouable sans swapper. |
| `kern.memorystatus_vm_pressure_level` | **autoritaire** | C'est ce compteur qui déclenche le dialogue système. S'il crie, on ne minimise pas. |
| croissance du swap | **pondérée** | Ignorée tant que la marge est confortable : charger un modèle 35B, ou sortir de veille, fait +900 Mio/s sans aucun danger. |
| ratio swap utilisé/total | **presque ignoré** | Mesuré sur machine saine : reste à ~96 % en permanence. Le pager redimensionne son jeu de swapfiles en continu (observé : 64 → 32 → 20 Gio en dix minutes). Ne compte que si le volume VM ne peut plus grandir. |
| place libre sur `/System/Volumes/VM` | **utilisé** | Pager acculé = plus de swap possible = c'est là que l'alerte tombe. |

Le score global est le **maximum** des composantes, pas leur moyenne : une
seule dimension saturée suffit à faire tomber la machine.

Quatre niveaux : `sain` → `surveillance` → `élevé` → `critique`.

## Installation

```sh
swift build -c release
./deploy/make-bar-app.sh     # optionnel : bundle de la barre de menus
./deploy/install.sh          # binaire + agents launchd utilisateur, sans sudo
```

L'ordre compte : `install.sh` n'installe la barre de menus que si le bundle
existe déjà.

Deux agents utilisateur sont posés, aucun privilège root :

| Agent | Rôle |
|---|---|
| `com.klody.mem` | le garde, en arrière-plan |
| `com.klody.mem.bar` | la barre de menus, `KlodyMem.app` dans `~/Applications` |

Les deux démarrent à l'ouverture de session. La barre est limitée à
`LimitLoadToSessionType: Aqua` — inutile en SSH — et n'est relancée que sur
plantage (`KeepAlive.SuccessfulExit: false`), pour que « Quitter KlodyMem »
dans le menu quitte réellement. Elles apparaissent dans Réglages Système →
Général → Ouverture, section « Autoriser en arrière-plan ».

Retrait complet — `./deploy/uninstall.sh` (retire les deux agents, l'app, et
envoie `SIGCONT` à tout ce qui aurait été suspendu).

## Commandes

```
Lecture
  status [--json]              état complet et niveau de risque
  top [-n N] [--json]          applications par empreinte réelle
  watch [-i SECONDES]          tableau de bord ; n'agit jamais
  history [-n N] [--json]      journal des changements de niveau

Action
  guard [--dry-run]            boucle de surveillance ; applique la politique
  reserve <TAILLE> [--dry-run] libère de la place avant un gros job (« 40G »)
  suspend | resume <app|pid>   SIGSTOP / SIGCONT — réversible
  quit | kill <app|pid>        arrêt propre / SIGKILL (désactivé par défaut)

Maintenance
  doctor                       auto-diagnostic ; 0 sain, 1 alertes, 2 panne
  config path | init | show
```

`status` sort en code 1 au niveau `élevé` ou plus — utilisable comme gate dans
un script avant de lancer une grosse tâche.

### `reserve` — l'usage le plus utile au quotidien

```sh
klodymem reserve 40G --dry-run   # afficher le plan
klodymem reserve 40G             # l'exécuter
```

Escalade du moins destructif au plus destructif, en remesurant la marge réelle
après chaque étape et en s'arrêtant dès que la cible est atteinte.

## Modèle de sûreté

Le défaut est **notification seule**. Rien n'est jamais suspendu ni quitté tant
que la liste `manageable` est vide.

Trois refus appliqués avant tout envoi de signal, non contournables :

- process **protégé** — 26 protections dures non surchargeables (`WindowServer`,
  `Finder`, `loginwindow`, les terminaux, KlodyMem lui-même) plus la liste
  `protected` de la config ;
- process d'un **autre utilisateur** ;
- **PID système** (< 100).

`SIGKILL` exige `actions.allowForceKill: true`. La barre de menus demande
confirmation avant tout arrêt.

Trois protections contre l'emballement : `confirmSamples` échantillons
consécutifs avant d'agir, escalade uniquement à la montée, et `cooldownSeconds`
entre deux actions **de même nature** sur la même cible — le cooldown d'un
`suspend` ne doit pas bloquer l'escalade vers un `quit`.

### L'échelle est exclusive

| Niveau | Action, si la cible est dans `manageable` |
|---|---|
| `sain`, `surveillance` | aucune |
| `élevé` | `SIGSTOP` si `suspendAtHigh` |
| `critique` | arrêt propre si `quitAtCritical`, **sinon** `SIGSTOP` |
| retour à `sain` | `SIGCONT` de tout ce qui a été gelé, si `autoResume` |

Au niveau critique on quitte, on ne suspend pas d'abord : geler une cible puis
lui demander de s'arrêter perdrait la demande, un process arrêté n'exécutant
plus rien. Pour la même raison, une cible gelée au niveau précédent reçoit
`SIGCONT` avant l'arrêt — et elle reste une candidate, puisque la suspendre
n'avait rendu aucune mémoire.

## Configuration

`~/.config/klodymem/config.json` — `klodymem config init` écrit les défauts.

Le garde relit le fichier dès qu'il change, sans redémarrage : la ligne
« config rechargée » apparaît dans `guard.log`. Une config cassée ne fait pas
retomber sur les défauts — l'ancienne reste active et l'incident est journalisé.

```jsonc
{
  "pollSeconds": 5,
  "manageable": ["Google Chrome"],   // seules cibles autorisées ; vide = notifier
  "protected": ["Xcode"],            // en plus des 26 protections dures
  "actions": {
    "notify": true,
    "suspendAtHigh": false,          // SIGSTOP au niveau « élevé »
    "quitAtCritical": false,         // arrêt propre au niveau « critique »
    "allowForceKill": false,
    "autoResume": true,              // SIGCONT au retour à « sain »
    "confirmSamples": 3,
    "cooldownSeconds": 120
  },
  "thresholds": {
    "criticalHeadroomBytes": 3221225472,
    "trendHeadroomRatio": 0.25,      // au-dessus, la croissance du swap est du travail normal
    "minVMVolumeFreeBytes": 17179869184
  }
}
```

## Bon à savoir

**La somme des empreintes dépasse la RAM installée.** C'est normal :
`phys_footprint` inclut les pages compressées et swappées, et la mémoire
partagée est comptée dans chaque process. Le Moniteur d'activité fait pareil.

**Les process root et la plupart des apps système sont invisibles.**
`proc_pid_rusage` les refuse sans privilèges — `Finder`, `Dock`, `WindowServer`
n'apparaissent donc pas dans `top`. C'est voulu : ils sont protégés de toute
façon, et les viser nommément renvoie « protégé », pas « introuvable ».

**Une action manuelle sur une cible hors `manageable` demande confirmation.**
`--yes` la contourne ; hors terminal, l'action est refusée plutôt que
supposée. Un `suspend` mal ciblé gèle un IDE — constaté en test.

**Ne jamais écraser le binaire ni le bundle installés avec `cp`.** Cela
invalide leur signature ad-hoc et macOS tue le process au lancement, code 137,
sans message. `install.sh` retire puis resigne ; `doctor` vérifie la signature.

**Les interpréteurs sont nommés par leur script.** Quatre `Python` à 36, 23, 12
et 4 Gio sont indiscernables ; `mlx_server_guarded.py`, `acestep_service.py`
ne le sont pas. Lu via `KERN_PROCARGS2`, seulement pour les process ≥ 64 Mio.

**Les helpers d'app sont regroupés** sous leur bundle parent, comme le Moniteur
d'activité — mais un `.app` niché dans un `.framework` n'en est pas un
(`Python.framework/…/Python.app`), sinon tous les interpréteurs de la machine
fusionneraient sous une seule entrée.

## Maintenance

```sh
swift test            # 43 tests
klodymem doctor       # 13 vérifications de bout en bout, sur les sondes réelles
klodymem history      # post-mortem : pourquoi la machine a ramé à 3 h
```

`doctor` vérifie que chaque brique répond réellement plutôt que de supposer
qu'elle marche : sondes système, dérivées temporelles, inventaire process,
cohérence des listes `manageable`/`protected`, signature du binaire, état de
l'agent launchd, fraîcheur du `state.json`.

## Disposition

```
Sources/KlodyMemCore/     sondes, modèle de risque, actions, boucle de garde
Sources/klodymem/         CLI et daemon
Sources/klodymem-bar/     barre de menus (NSStatusItem)
Tests/                    43 tests, dont les sondes réelles et les régressions
deploy/                   agent launchd, install/uninstall, bundle .app
```

État : `~/.local/state/klodymem/` — `state.json`, `history.jsonl`, `guard.log`.
