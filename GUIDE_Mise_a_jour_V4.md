# Mettre à jour Winpass en V4 (depuis ta V3 qui tourne)

Tu as déjà la V3 installée sur GitHub et qui tourne dans un Codespace. Passer en
V4 = **remplacer les fichiers**, **envoyer sur GitHub**, puis **reconstruire**.

> Important : la V4 ajoute une **migration** (nouveau statut de lot + index) et deux
> **outils** (RuboCop, Brakeman). Il faut donc **reconstruire l'image une fois**
> (`--build`, ou repartir d'un nouveau Codespace). Ce n'est pas un simple `up`.

## 1. Décompresser
- Double-clique **`winpass-loyalty-v4.zip`** → dossier **`winpass-loyalty`** (SOURCE).

## 2. Remplacer le contenu du dépôt
- Ouvre ton dépôt en local (GitHub Desktop ▸ **Repository ▸ Show in Finder**).
- Dans la SOURCE : **Cmd + A** (tout sélectionner), **glisse** dans le dossier du dépôt,
  **en acceptant de remplacer** les fichiers existants.
- Vérifie que `Dockerfile` est bien **à la racine** du dépôt (pas dans un sous-dossier).

## 3. Envoyer sur GitHub
- GitHub Desktop liste les fichiers modifiés. Summary : `Winpass V4` → **Commit to main** → **Push origin**.

## 4. Reconstruire et lancer (Codespaces)
Deux options, au choix :

- **Le plus simple** — nouveau Codespace : **Code ▸ Codespaces ▸ Create codespace on main**.
  Puis, dans le terminal : `docker compose up` (l'image se construit toute seule, ~2-3 min).
- **Codespace existant** : dans le terminal, `docker compose up --build`
  (le `--build` réinstalle les nouvelles gems et rejoue la migration).

Attends `Listening on http://0.0.0.0:3000`, puis onglet **PORTS** ▸ port **3000** ▸
clic droit ▸ **Port Visibility ▸ Public** ▸ 🌐.

→ Le tableau de bord a maintenant **5 onglets** (Tableau de bord, **Commandes**,
Lots & Expiration, Comportemental, Paramétrage).

## 5. Ce que tu peux vérifier tout de suite
- **Annulation** : fais un achat, annule-le → dans l'onglet **Lots**, le lot passe en
  `reversed` (barré, non consommable). C'est le bug #1 corrigé.
- **N° de commande** : il **s'incrémente tout seul** après chaque achat.
- **Enseigne** : c'est un **menu déroulant** (plus de faute de frappe possible).
- **Comportemental** : carte **Cagnottes** (soldes) + carte **Score & émulation**
  (choisis un membre, clique **+1 mois**, **+2 mois**… pour voir le score décroître).
- **Créditer la CIC** : onglet Comportemental → carte Campagnes → **« + Créditer »** (montant à ajouter).
  Et si tu crées une campagne dont le budget dépasse les fonds CIC, elle est acceptée : la CIC est
  **abondée automatiquement** du manque (plus de blocage « CIC insuffisante »).
- **Batch mensuel rejouable** : onglet Comportemental → bouton **« ↺ Purger & rejouer »**.
  Il rejoue le mois ; les récompenses déjà (partiellement) utilisées sont conservées (acquises),
  les intactes sont recalculées. Plus besoin de repartir d'une base vierge pour tester.
- **Commandes** : l'onglet liste les commandes (earn, burn, annulée).
- **Anti-saturation** : les listes qui grossissent (transactions, Commandes, Lots)
  montrent les **8 plus récentes** ; clique le **menu déroulant** (« + N … plus anciennes »)
  pour voir le reste. Idéal pendant le bombardement : `python3 bench/bombard.py --n 1000 --concurrency 40`.

## 6. Preuves (optionnel, pour ton CTO)
Dans le terminal du Codespace :

```bash
# Le bug #1 prouvé sur ta pile Rails+Postgres :
docker compose run --rm app env RAILS_ENV=test bundle exec rspec spec/services/reversal_lots_spec.rb
# Toute la suite :
docker compose run --rm app env RAILS_ENV=test bundle exec rspec
# Qualité & sécurité :
docker compose run --rm app bundle exec rubocop
docker compose run --rm app bundle exec brakeman -q
# Charge (bombardement de l'API, l'app devant tourner en parallèle) :
python3 bench/bombard.py --n 1000 --concurrency 40
```

Le détail est dans **`RAPPORT_Qualite_Performance_Securite.md`**.
