# Winpass V5.1 — Correctifs appliqués & procédure d'installation

> Version corrigée suite à la recette en direct. Elle règle les bugs des trois modules
> (Comportemental, Bâtisseurs, Prime de Statut), rend les calculs **transparents**, et
> ajoute un **auto-test qui s'exécute sur l'application réelle** (vrais moteurs, vraie
> base) et affiche PASS/FAIL avec les vrais chiffres.

---

## 1. Correctifs appliqués

### A. Garde-fous « un clic = une fois » (fin des doubles / du pot RFA infini)
- **Primes de rang Bâtisseurs (le bug le plus grave)** : l'ancien garde-fou ne se
  déclenchait que si une prime était versée. Comme personne n'était rangé, il ne se
  déclenchait jamais → **chaque clic ré-ajoutait la poche 7,5 % au pot RFA**. Désormais
  le trimestre est marqué traité par une ligne **unique** (`builder_prime_runs`) : un
  reclic renvoie « déjà distribué » et **aucun euro ne bouge**. (Migration additive 0010.)
- Comportemental et Prime de Statut : idempotence par état déjà en place, conservée.

### B. Purges « point barre » (remise à zéro, sans rejeu)
Les trois purges **remettent la période à zéro** puis s'arrêtent (elles ne rejouent plus) :
- **Comportemental** (`behavioral#purge`) : supprime les photos du mois, reverse les
  crédits encore présents (jamais de solde négatif : on reverse au plus le solde restant),
  annule les contributions CIC du mois. Le mois redevient **vierge**, le batch est rejouable.
- **Prime de Statut** (`prime-statut#purge`, **nouveau**) : idem pour la période.
- **Primes Bâtisseurs** (`builders/primes#purge_primes`, **nouveau**) : reverse les primes,
  **retire du pot RFA la poche du trimestre** et supprime le marqueur → rejouable proprement.

Côté back-office : le bouton « Purger & rejouer » devient **« Purger le mois »** (il ne
rejoue plus), et des boutons **« Purger le mois / le trimestre »** sont ajoutés pour la
Prime de Statut et les primes Bâtisseurs.

### C. Transparence du calcul de rang (ta demande)
« Batch rangs » renvoie et affiche désormais, **pour chaque membre**, toutes les variables
sous-jacentes du Score Forêt : **filleuls qualifiés / gate, Équipe, Arbre secondaire,
Racines, Activité, Score Forêt, Rang**. On voit ainsi *pourquoi* un membre est à tel rang
(ou à 0 : gate des 7 filleuls non ouvert).

### D. Textes explicatifs & messages « vide »
- Encart **Prime de Statut** réécrit dans l'appli : à quoi elle correspond, qui elle
  concerne, ce qui la finance (poche 5 %), en quoi elle est collective, sa poche.
- Quand une poche est vide, le message dit pourquoi et quoi faire (ex. « aucun achat de
  cette période n'a alimenté la poche 5 % »), au lieu d'un silence.

### E. Jeu de démonstration cohérent V5 (`db/seeds/demo_v5.rb`)
Un leader **Léa (#900)** avec **8 filleuls directs qualifiés** (niveaux acheteur pré-posés
pour la démo) et des **achats réels** (via le vrai moteur d'achat, config V5-2026) qui
**alimentent les 3 poches** (Prime de Statut 5 %, Comportemental 15 %, Grands leaders 7,5 %).
Résultat : les trois modules ont enfin de la matière à distribuer, et les Bâtisseurs
affichent de vrais rangs.
> Note : en démo, les niveaux acheteur sont pré-posés pour rendre les modules visibles. En
> production, ils viennent du batch de statut acheteur (`status/run`).

### F. Correctifs d'installation intégrés au paquet
- **Réseau** : l'app partage le réseau de la base (`network_mode: service:db`) → fin du
  blocage « Attente de PostgreSQL » propre aux Codespaces.
- **Bibliothèque JSON figée** (`json 2.6.3`) → fin de l'erreur `unknown keyword: quirks_mode`
  qui bloquait les migrations.

### Ce qui a été vérifié, honnêtement
- **Syntaxe** de tous les fichiers Ruby (90) et du JavaScript du back-office : OK.
- Je **ne peux pas** démarrer Rails dans mon environnement (rubygems bloqué), donc la
  preuve « ça tourne » se fait **chez toi** via l'auto-test ci-dessous — vrais moteurs,
  vraies données, PASS/FAIL affichés.

---

## 2. Installation (dans ton Codespace déjà ouvert)

> Même méthode que la dernière fois (GitHub → pull), qui a fonctionné.

**Étape 1 — déposer le nouveau paquet sur GitHub.**
Sur la page de ton dépôt `winpass-v4` : **Add file → Upload files** → glisse
`winpass-loyalty-v5.1.zip` → **Commit changes** (directement sur `main`).

**Étape 2 — dans le terminal du Codespace**, récupère-le puis applique-le :
```
git pull
unzip -o winpass-loyalty-v5.1.zip -d _v51 && cp -rf _v51/winpass-loyalty/. . && rm -rf _v51 winpass-loyalty-v5.1.zip
```

**Étape 3 — reconstruire proprement** (base repartie à neuf = démo cohérente) :
```
docker compose down -v && docker compose up -d --build
```
Attends ~2-3 min (le `$` revient). Les migrations 0001→0010 s'appliquent, les seeds créent
le jeu de démo V5.

**Étape 4 — LANCER L'AUTO-TEST (la preuve) :**
```
docker compose exec app bundle exec rails runner verification/recette_e2e.rb
```
Résultat attendu : une série de **[PASS]** avec les chiffres réels, dont la ligne
**« ★ LE POT RFA NE GONFLE PLUS »**, et pour finir **« TOUT VERT »**.

**Étape 5 — ouvrir le tableau de bord** : onglet **PORTS** → port **3000** → icône 🌐.
Onglet **« ✨ V5 · Générosité »**. Les périodes sont pré-remplies sur **2026-09** /
**2026-Q3** (la période de la démo). Ordre conseillé pour voir vivre le système :
1. **Batch rangs** (Bâtisseurs) → le tableau détaillé des rangs s'affiche (Léa = Arbre).
2. **Distribuer primes** → primes versées + pot RFA ; reclique → « déjà distribué », RFA inchangé.
3. **Purger le trimestre** → tout revient à zéro ; re-**Distribuer** → repart proprement.
4. **Lancer la Prime de Statut** → primes par niveau ; **Purger le mois** → à zéro ; relance → OK.
5. **Batch mensuel comportemental** → **Purger le mois** → relance → OK.

---

## 3. Nouveaux points d'API
`POST /v1/prime-statut/purge` · `POST /v1/builders/primes/purge` — purges « point barre ».
`POST /v1/builders/run` renvoie désormais le **détail transparent** du Score Forêt par membre.
