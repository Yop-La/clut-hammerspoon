# clut-hammerspoon

Basculer entre les derniers onglets Chrome utilisés au clavier, comme l'extension
[CLUT](https://chromewebstore.google.com/detail/clut-cycle-last-used-tabs/cobieddmkhhnbeldhncnfcgcaccmehgn),
mais **sans extension** : utile sur un profil Chrome géré par une organisation
qui interdit les extensions. Tourne sur macOS via [Hammerspoon](https://www.hammerspoon.org).

Bonus par rapport à CLUT : l'historique est **commun à toutes les fenêtres et à
tous les profils Chrome**.

| Raccourci | Action |
|---|---|
| `⌥W` | Bascule entre les 2 derniers onglets |
| `⌥S` | Remonte l'historique : garder `⌥` enfoncé, appuyer plusieurs fois sur `S`, relâcher `⌥` pour valider |
| `⌥⇧S` | Même chose dans l'autre sens |

Les raccourcis ne sont actifs que lorsque Chrome est au premier plan.

## Installation

```bash
brew install --cask hammerspoon
git clone https://github.com/Yop-La/clut-hammerspoon.git ~/clut-hammerspoon
mkdir -p ~/.hammerspoon
ln -s ~/clut-hammerspoon/clut.lua ~/.hammerspoon/clut.lua
cat >> ~/.hammerspoon/init.lua <<'EOF'
hs.autoLaunch(true)       -- démarrage à l'ouverture de session
clut = require("clut")
clut.start()
EOF
open -a Hammerspoon
```

Puis, une seule fois :

1. Au premier lancement, cliquer **Ouvrir** sur l'avertissement macOS.
2. **Réglages Système → Confidentialité et sécurité → Accessibilité** : cocher
   Hammerspoon, puis **quitter et relancer Hammerspoon** (il ne voit
   l'autorisation qu'après un redémarrage).
3. Au premier `⌥W`, accepter que Hammerspoon **contrôle Google Chrome**.

Mise à jour : `git -C ~/clut-hammerspoon pull`, puis *Reload Config* dans le
menu Hammerspoon.

## Configuration

Constantes en tête de `clut.lua` : taille de l'historique (`MAX_HISTORY`),
bandeau pendant `⌥S` (`SHOW_HUD`). Les raccourcis sont définis dans `M.start()`.

## Fonctionnement

Hammerspoon suit l'onglet actif (changement de titre de fenêtre + sondage léger
quand Chrome est devant), tient une liste des onglets les plus récents et
active l'onglet visé via AppleScript, qui voit toutes les fenêtres de Chrome,
quel que soit le profil.

## Dépannage

- `hs -c "return clut.dump()"` affiche l'historique avec les titres
  (CLI : `/Applications/Hammerspoon.app/Contents/Frameworks/hs/hs`).
- Le focus clavier reste sur la mauvaise fenêtre → autorisation Accessibilité
  manquante, ou Hammerspoon pas relancé après l'avoir accordée.

## Limites

- Google Chrome uniquement (un seul processus Chrome ; les instances lancées
  avec `--user-data-dir` à part ne sont pas vues).
- L'historique se remplit au fil de la navigation et repart à zéro quand Chrome
  redémarre.

## Licence

MIT
