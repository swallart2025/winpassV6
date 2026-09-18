# Winpass — Moteur de fidélité (Earn + Burn + Annulation) avec tableau de bord

Application **Ruby on Rails 7.2** (API) + **PostgreSQL 16**. Le service expose une
API REST et **sert aussi un tableau de bord web** pour piloter et observer le
moteur en temps réel, directement sur la vraie base.

Moteurs couverts :

- **Achat → Earn** : récompense Personnelle (45 %) + remontée **Parrainage** (20 %)
  sur 5 générations, distribution géométrique 0,70 renormalisée, arrondi conservatif ;
- **Achat mixte → Earn + Burn** : la fraction réglée en points est consommée en
  **FEFO** (premier expiré, premier sorti), le reste de la commande génère l'earn ;
- **Annulation → Reversal** : clawback de l'earn (acheteur **et** parrains en
  cascade) et/ou restitution des points, selon ce que la commande contenait
  (`reversal_type` = `earn` | `burn` | `earn+burn`).

Garanties transverses :

- **idempotence** en base (unicité de la clé d'événement + `rescue RecordNotUnique`) ;
- **sérialisation** des écritures concurrentes par verrou de ligne (`lock!`) ;
- journaux comptables **immuables**, montants en `BigDecimal` ;
- configuration **versionnée** (`reward_configs`) ;
- suite **RSpec** rejouant des scénarios à résultats connus (golden), l'idempotence,
  la concurrence (même clé et clés différentes), la compression, le burn FEFO et
  les annulations en cascade.

---

## Lancer (Docker) — rien à installer sauf Docker

```bash
docker compose up --build
```

Au premier lancement, Docker installe Ruby, Rails, PostgreSQL et les dépendances,
crée la base, applique le schéma, amorce la configuration **et un réseau de
démonstration** (Alice ← Bruno ← David ← Sophie ← Emma), puis démarre le service.

Quand la console affiche :

```
   Winpass — API + tableau de bord PRÊTS
   Ouvre le tableau de bord :  http://localhost:3000
```

ouvre **http://localhost:3000**. Dans **GitHub Codespaces**, va dans l'onglet
**PORTS** (en bas), ligne du port **3000**, et clique l'icône 🌐 *(Open in Browser)*.

> Le tableau de bord appelle la véritable API, qui lit et écrit dans PostgreSQL.
> Change une donnée, rafraîchis la page : tout est persistant. Rien n'est simulé.

### Repartir d'une base vierge

```bash
docker compose down -v && docker compose up --build
```

(Le point d'entrée détecte aussi automatiquement un ancien schéma et reconstruit
la base proprement.)

---

## Le tableau de bord

Servi à la racine (`public/index.html`). Trois zones :

1. **Réseau de parrainage** — établir/modifier qui parraine qui, (dés)activer un
   membre. « Appliquer » envoie `PUT /v1/sponsorships`.
2. **Scénarios (client API)** — boutons *Commande livrée → Earn*, *Achat payé en
   points → Earn + Burn*, *Annulation → Reversal*. Champs modifiables ; rejouer un
   même n° de commande renvoie `duplicate` (idempotence).
3. **Journal des échanges API** — chaque requête et sa réponse s'empilent ;
   téléchargeable en fichier `.log`.

À droite, la **fiche de chaque membre** (solde, rôle, **toutes** ses transactions,
remontée de gains nette), rafraîchie depuis `GET /v1/members` après chaque action.

---

## API REST

| Méthode & route | Rôle |
|---|---|
| `POST /v1/purchases` | Achat livré : earn (+ burn si `points_redeemed` > 0). En-tête `Idempotency-Key` requis. |
| `POST /v1/reversals` | Annule une commande (`{ order_id }`). En-tête `Idempotency-Key` requis. |
| `PUT  /v1/sponsorships` | Établit le réseau (`{ relations: [ { member_id, sponsor_member_id, active } ] }`). |
| `GET  /v1/members` | État complet du réseau (soldes, rôles, transactions, remontée). |
| `GET  /v1/members/:id` | Fiche d'un membre. |

Exemple :

```bash
curl -X POST http://localhost:3000/v1/purchases \
  -H "Content-Type: application/json" -H "Idempotency-Key: ord-1001" \
  -d '{"order_id":1001,"member_id":500,"order_amount":"400","commission_rate":"0.02","merchant_id":"CARREFOUR","points_redeemed":"0"}'
```

---

## Lancer la suite de tests (RSpec)

```bash
docker compose run --rm app env RAILS_ENV=test bundle exec rspec
```

| Scénario | Vérifie |
|---|---|
| Attribution profondeur 3 | Montants exacts acheteur + 3 parrains, conservation du budget |
| Invariant comptable | Σ(relevé) == solde du portefeuille |
| Idempotence | Un rejeu de la même clé ne crée aucun doublon |
| Concurrence même clé | Un seul traitement accepté, l'autre rejeté |
| Concurrence clés différentes | Toutes exécutées, sérialisées, solde exact |
| Compression verticale | Un parrain inactif est sauté, les suivants remontent |
| Achat mixte earn+burn | Burn FEFO + earn sur la commande, solde exact |
| Annulation earn / earn+burn | Clawback en cascade + restitution des points |

---

## V3 — Comportemental, campagnes, expiration & paramétrage versionné

| Méthode & route | Rôle |
|---|---|
| `POST /v1/expirations/run` | Batch d'expiration (lots dont la validité est dépassée). |
| `PATCH /v1/lots/:id` | Modifie la date de fin de validité d'un lot (test FEFO/expiration). |
| `GET /v1/lots` | Vue brute des lots (`wallet_lots`). |
| `POST /v1/behavioral/run` | Batch mensuel comportemental (potentiel, score, récompense, CIC). |
| `GET /v1/behavioral` | CIC, cagnottes, campagnes, photos mensuelles. |
| `GET /v1/behavioral/score` | Détail du score par catégorie à une date (`?member_id=&as_of=`) — détail + émulation temporelle. |
| `POST /v1/behavioral/purge` | Purge/rollback du batch mensuel (`{ period }`) pour le rejeu — conserve les récompenses utilisées. |
| `GET /v1/orders` | Vue lisible des commandes (n°, acheteur, enseigne, montant, earn, burn, annulée). |
| `POST /v1/campaigns` · `GET /v1/campaigns` | Campagnes financées par la CIC (cashback temps réel). Budget > fonds CIC → abondement auto. |
| `POST /v1/cic/credit` | Abondement manuel de la CIC (`{ amount }`) — banc d'essai. |
| `GET/PUT /v1/reward-configs` | Répartition du budget (versionnée). |
| `GET/PUT /v1/loyalty-categories` | Catégories comportementales (versionnées). |
| `GET/PUT /v1/adherence-scales` | Barème d'adhésion (versionné). |
| `GET/PUT /v1/merchant-categories` | Table marchand → catégorie. |

**Moteur comportemental** : score d'adhésion par catégorie avec décroissance dans le
temps (mensuelle, bi-hebdomadaire pour les catégories à validité 1 mois) et seuil de
rechargement (montant minimum qualificatif) ; batch mensuel (potentiel = 15 % du budget
de commission, récompense = potentiel × taux d'adhésion, reliquat → **CIC**).
**Campagnes** en temps réel : éligibilité score-catégorie ≤ seuil, cashback crédité à
l'achat (tout-ou-rien), clôture au budget épuisé ou à la date de fin, reliquat rendu à la CIC.

Le **tableau de bord** (`public/index.html`) est à **onglets** : Tableau de bord,
Commandes, Lots & Expiration, Comportemental, Paramétrage. Servi par Rails, il appelle la vraie API.

## V4 — Correctifs, émulation, charge & qualité

- **Bug #1 corrigé** : l'annulation invalide désormais les lots (statut `reversed`,
  clawback clampé au reliquat, plus de lot fantôme consommable en FEFO). Couvert par
  `spec/services/reversal_lots_spec.rb`.
- **Affichage** : n° de commande + filleul + taux appliqué sur chaque ligne ; enseigne
  en **menu déroulant** ; **cagnottes** (Fonctionnement / Grands leaders / Comportemental /
  CIC) ; **origine** sur les récompenses comportementales ; **vue Commandes**.
- **Émulation de la dégressivité** : onglet Comportemental → « Score & émulation » : choisir
  un membre et avancer le temps (+1/+2/+3/… mois) pour voir le score décroître ; antidater
  un achat (champ « Date d'achat ») puis ré-avancer pour voir le rechargement.
- **N° de commande auto-incrémenté** (compteur unifié earn/burn) après chaque génération.
- **Abondement de la CIC** (banc d'essai) : bouton « Créditer la CIC » (`POST /v1/cic/credit`, écriture
  `manual_credit`). Et une campagne dont le budget dépasse les fonds CIC est **acceptée** : la CIC est
  **abondée automatiquement du manque** (au lieu du refus `cic_insuffisante`), de sorte qu'elle reste ≥ 0 après réserve.
- **Batch mensuel rejouable** (banc d'essai) : bouton « Purger & rejouer » (`POST /v1/behavioral/purge`).
  Les récompenses **intactes** sont réinitialisées (crédit repris, lot `reversed`, contribution CIC
  annulée, photo supprimée) puis recalculées ; les récompenses déjà **(partiellement) utilisées** sont
  **conservées** (acquises) et sautées au rejeu — pas de double versement. Immuabilité des journaux préservée
  (écritures compensatoires, pas de suppression de ledger). Couvert par `spec/services/behavioral_rollback_spec.rb`.
- **Affichage anti-saturation** (pour le bombardement) : les listes qui grossissent
  (transactions d'un membre, Commandes, Lots) montrent les **8 plus récentes** et
  rangent **le reste dans un menu déroulant** ; les payloads correspondants sont
  bornés côté serveur (200 transactions/membre, 500 commandes, 500 lots — les plus récents).
- **Banc de charge** : `bench/bombard.py` (bombardement de l'API, sans dépendance).
- **Rapport** : `RAPPORT_Qualite_Performance_Securite.md` (qualité, perf, sécurité — mesuré).
- **Outils qualité** : `bundle exec rubocop` et `bundle exec brakeman` (dans l'image).

## Organisation du code

```
domain/
  app/models/          # tables + validations + immuabilité des journaux
  app/services/        # cœur métier :
    loyalty_ledger.rb        (module) écriture comptable partagée (verrou + relevé)
    distribution_table.rb    répartition parrainage + arrondi conservatif
    sponsorship_tree.rb      arbre à une date + compression verticale
    purchase_engine.rb       achat : earn (+ burn FEFO) — idempotent, verrouillé
    reversal_engine.rb       annulation par commande, en cascade
  app/controllers/api/v1/    endpoints REST
  public/index.html          tableau de bord (servi par Rails)
  db/migrate/          # schéma (contraintes fortes en base)
  db/seeds.rb          # config + réseau de démonstration
  spec/                # RSpec : golden + idempotence + concurrence + burn + annulation
```
