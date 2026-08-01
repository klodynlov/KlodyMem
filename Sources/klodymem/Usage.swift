import Foundation
import KlodyMemCore

func printUsage() {
    let text = """

      \(Ansi.bold("klodymem")) — garde-fou mémoire pour macOS

      \(Ansi.bold("Lecture"))
        status [--json]              état mémoire complet et niveau de risque
        top [-n N] [--json]          applications par empreinte réelle
        watch [-i SECONDES]          tableau de bord rafraîchi, n'agit jamais
        history [-n N] [--json]      journal des changements de niveau

      \(Ansi.bold("Action"))
        guard [--dry-run]            boucle de surveillance ; applique la politique
        reserve <TAILLE> [--dry-run] libère de la place avant un gros job (« 40G »)
        suspend <app|pid>            SIGSTOP — réversible, libère vers le compresseur
        resume <app|pid>             SIGCONT
        quit <app|pid>               arrêt propre (l'app peut sauvegarder)
        kill <app|pid>               SIGKILL — refusé sauf actions.allowForceKill

      \(Ansi.bold("Maintenance"))
        doctor                       auto-diagnostic ; 0 = sain, 1 = alertes, 2 = panne
        config path|init|show        emplacement, création, contenu de la config

      \(Ansi.bold("Options"))
        --json                       sortie machine
        --dry-run, -n                décide et affiche, n'envoie aucun signal
        --yes, -y                    pas de confirmation sur une cible hors `manageable`

      Config   \(Config.configURL.path)
      État     \(Config.stateDirectory.path)

      \(Ansi.dim("Par défaut le garde ne fait que notifier. Il ne suspend ou ne quitte"))
      \(Ansi.dim("que les applications listées dans `manageable`, jamais les autres."))

    """
    print(text)
}
