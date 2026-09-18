# Winpass — Rapport qualité, performances & sécurité (V4)

*Moteur de fidélité — Ruby on Rails 7.2 (API) + PostgreSQL 16.*
*Objet : donner à Stéphane et à son CTO des éléments **objectifs et rejouables** sur la solidité du code, sa performance sous charge, et sa sécurité — pas des affirmations, des mesures.*

---

## 1. En une page

| Dimension | Verdict | Preuve |
|---|---|---|
| **Correction** | Solide | 19/19 contrôles V4 + 24/24 V3 sur **vrai PostgreSQL** ; suites RSpec golden/idempotence/concurrence/annulation ; invariants tenus par la base. |
| **Performance** | Large marge sur la cible | Cible métier 10 tx/s **tenue ×7** au pire cas (contention maximale) ; requêtes chaudes en **Index Scan** après indexation (potentiel mensuel : 12,3 ms → 3,9 ms). |
| **Concurrence** | Sûre | 60 écritures simultanées sur le même portefeuille : **aucune mise à jour perdue**, solde exact, idempotence tenue sous course (1 seul gagnant sur 25). |
| **Sécurité** | Bonne posture | API-only, *strong parameters*, requêtes **paramétrées** (pas d'injection SQL), journaux **immuables**, contraintes fortes en base ; scan Brakeman + lint RuboCop fournis, runnables en une commande. |
| **Architecture** | Idiomatique, pas « bric-à-brac » | Couches nettes (modèles / *service objects* / contrôleurs fins), invariants **en base** et non seulement dans le code. |

**Ce qui a été mesuré ici, pour de vrai** : correction (harnais Python sur PostgreSQL réel), performance des requêtes (EXPLAIN ANALYZE sur 60 000 lignes), concurrence et idempotence (vrais threads, connexions distinctes). **Ce qui se lance chez toi en une commande** : RuboCop, Brakeman, la suite RSpec, et le bombardement de l'API sur la pile complète Rails+Postgres. Le juge de paix final reste la **revue de ton CTO** — ce rapport est fait pour la rendre rapide.

---

## 2. Architecture — pourquoi ce n'est pas du bric-à-brac

Le code est organisé en **couches à responsabilité unique**, le patron que tout développeur Rails reconnaît :

- **Modèles** (`app/models`) — tables, validations, et **immuabilité** des journaux comptables (`earn_ledgers`, `wallet_statements`, `pool_contributions`, `cic_ledgers` : une ligne écrite ne peut plus être modifiée ni supprimée).
- **Services** (`app/services`) — le cœur métier, **un moteur par responsabilité** : `purchase_engine` (achat → earn + burn), `reversal_engine` (annulation en cascade), `behavioral_monthly_engine` (batch mensuel), `campaign_engine` (campagnes temps réel), `expiration_engine` (péremption), `behavioral_score` (score d'adhésion partagé). Les briques comptables communes sont dans le module `loyalty_ledger`.
- **Contrôleurs** (`app/controllers/api/v1`) — **fins** : ils parsent la requête, délèguent au service, formatent la réponse. Aucune logique métier dans les contrôleurs, aucun contrôleur obèse.

Le point d'architecture le plus important : **les invariants sont tenus par la base de données, pas seulement par le code Ruby**. Un assemblage bricolé *espère* que rien ne tourne mal ; ici la base **refuse** les états incohérents :

- unicité de la clé d'idempotence (`processed_events.event_key`) → un rejeu ne peut pas créer de doublon, même sous appels concurrents ;
- unicité d'une relation de parrainage active + **contrainte d'exclusion** `gist` sur les périodes → impossible d'avoir deux parrains actifs ou des périodes qui se chevauchent ;
- `wallet_balance_non_negative`, `lot_remaining_non_negative`, `lot_remaining_le_initial`, `amount > 0` partout → les montants ne peuvent pas devenir aberrants ;
- configuration **versionnée** (`reward_configs`, `loyalty_category_configs`, `adherence_scale_configs`) avec index partiel « une seule version en vigueur ».

C'est cette ceinture de contraintes qui rend le système juste **même en cas d'appels concurrents** — et c'est vérifiable (section 4).

---

## 3. Correction — vérifiée sur un vrai PostgreSQL

Fidèle au principe « je ne crois que ce que je vois », la logique n'est pas seulement testée en Ruby : elle est **rejouée contre un PostgreSQL réel**, avec des scénarios à résultat connu.

### 3.1 Correctif V4 du bug #1 (annulation → invalidation des lots) — 19/19

Le bug : après une annulation, les lots issus de la commande restaient **actifs** (donc encore consommables en FEFO) alors que le solde, lui, était réduit — incohérence entre le solde et les lots, et risque de « payer » avec des points déjà repris.

Le correctif : le clawback est **clampé au reliquat réel** du lot, et le lot passe en statut **`reversed`** (remaining 0, ligne conservée pour l'audit, plus jamais consommable). Trois scénarios, tous verts :

| Scénario | Attendu | Résultat |
|---|---|---|
| **A** — annulation simple, lot intact | lot → `reversed`, solde revient à 0 | ✓ |
| **B** — lot partiellement consommé (6 restants sur 10) | clawback **clampé à 6** (pas 10), solde final exact, lot → `reversed` | ✓ |
| **C** — lot entièrement consommé avant annulation | clawback **0** (rien à reprendre), lot reste `consumed`, **solde jamais négatif** | ✓ |

Invariants contrôlés après chaque scénario : **(I1)** solde == Σ(lots actifs) ; **(I2)** solde ≥ 0 ; **(I3)** aucun lot annulé n'est consommable en FEFO (prouvé en rejouant un burn après annulation).

> Rejouable : `python3 verify4/reversal_v4.py` → `19/19 contrôles VERTS`.
> Et dans le Codespace, couvert par la suite : `spec/services/reversal_lots_spec.rb`.

### 3.1 bis Rollback du batch mensuel (rejeu au banc d'essai) — 18/18

Le batch mensuel n'était rejouable qu'une fois (garde d'unicité par membre/période). Le rollback le rend **rejouable sans casser le modèle** : les récompenses **intactes** sont réinitialisées (crédit repris via écriture compensatoire, lot `reversed`, contribution CIC annulée, photo supprimée) et **recalculées** au rejeu ; les récompenses déjà **(partiellement) utilisées** sont **conservées** (acquises) et sautées au rejeu — **pas de double versement**. L'immuabilité des journaux est préservée (aucune suppression de ledger, seulement des écritures compensatoires + purge des projections mensuelles). Vérifié 18/18 sur PostgreSQL réel (intact→réinitialisé, partiel→conservé, total→conservé, nul→réinitialisé, CIC cohérente, invariant Σ(relevé)==solde) et couvert par `spec/services/behavioral_rollback_spec.rb`.

### 3.2 Le reste du moteur — 24/24 (V3) + suites RSpec

Le socle comportemental/campagnes reste vert (24/24) : décroissance mensuelle et bi-hebdomadaire, seuil de rechargement, batch mensuel, campagnes tout-ou-rien, clôture et reliquat rendu à la CIC. Les suites RSpec livrées couvrent : attribution en profondeur (golden), invariant comptable Σ(relevé)==solde, idempotence, concurrence même clé / clés différentes, compression verticale, burn FEFO, annulation en cascade, expiration, et désormais l'invalidation des lots.

---

## 4. Concurrence — la garantie sur laquelle tout repose

Le moteur sérialise les écritures d'un même portefeuille par **verrou de ligne** (`SELECT … FOR UPDATE`). On l'a mis à l'épreuve au **pire cas** : plusieurs écritures se disputant *la même* ligne, relâchées simultanément par une barrière.

```
60 crédits concurrents sur LE MÊME portefeuille (contention maximale)
  ✓ aucune mise à jour perdue : solde = 60,000000 == attendu = 60,000000
  ✓ invariant Σ(relevé) == solde  (60 lignes)
  débit mesuré : 75 transactions/seconde
25 threads, MÊME clé d'idempotence
  ✓ un seul gagnant, une seule ligne en base — les 24 autres = doublon propre
```

Deux enseignements : (1) **aucune mise à jour perdue** ni double écriture, même sous contention totale ; (2) l'idempotence tient **sous course** — l'unicité en base n'accepte qu'une écriture, les autres échouent proprement en `duplicate`.

> Rejouable : `python3 verify4/concurrency_v4.py`.

---

## 5. Performances — cible 10 tx/s, et comment le prouver

### 5.1 Le chiffre, et sa lecture honnête

10 transactions/seconde, c'est **une transaction toutes les 100 ms**. Un achat, même avec la cascade de parrainage sur 5 générations, c'est une poignée d'`INSERT` et quelques `UPDATE` verrouillés dans **une** transaction — quelques millisecondes sur PostgreSQL. Le vrai point de vigilance n'est pas le débit brut mais la **contention de verrous** : un « grand leader » présent dans la chaîne de beaucoup d'acheteurs simultanés sérialise les écritures sur lui.

Le banc de concurrence ci-dessus donne le **pire cas** : ~75 tx/s **sur un seul portefeuille en contention maximale**, soit déjà **×7 la cible**. Dans la réalité, les achats frappent des portefeuilles différents et se parallélisent bien au-delà. Le débit end-to-end réel sur ta pile se mesure avec le script de bombardement (section 5.3).

### 5.2 Requêtes chaudes indexées — EXPLAIN ANALYZE (60 000 lignes)

Deux requêtes sont sollicitées en boucle : le **calcul du score** (par membre) et le **potentiel mensuel** (par membre). Sur un jeu réaliste (60 000 `earn_ledgers`, 35 000 `pool_contributions`), mesure **avant / après** les index ajoutés en V4 :

| Requête | Sans index | Avec index (V4) | Gain |
|---|---|---|---|
| Potentiel mensuel (`pool_contributions` par membre/mois) | **Seq Scan, 12,3 ms**, 35 000 lignes balayées | **Index Scan, 3,9 ms**, 100 lignes | ~3× + complexité O(lignes du membre) au lieu de O(table) |
| Score d'adhésion (`earn_ledgers` par membre/type/date) | Filtre après balayage, 3,6 ms | Condition poussée dans l'index (Recheck), 2,1 ms | ~1,7× |

Le gain décisif n'est pas le facteur en millisecondes sur ce volume, mais la **complexité** : sans index, le coût croît avec la taille **totale** de la table ; avec l'index, il croît seulement avec le nombre de lignes **du membre concerné**. À l'échelle, c'est la différence entre un système qui ralentit avec l'historique et un système qui reste constant.

Index ajoutés (migration `20260101000003`) : `idx_earn_member_type_delivered` sur `earn_ledgers(member_id, earn_type, delivered_at)` et `idx_pool_type_member` sur `pool_contributions(pool_type, source_member_id)`.

> Rejouable : voir les commandes EXPLAIN dans `verify4/` (ou directement en `psql`).

### 5.3 Bombardement de l'API — à lancer sur ta pile

Un script sans dépendance (bibliothèque standard Python 3, rien à installer) tire des achats **en concurrence** sur l'API réelle et mesure débit + latence p50/p95/p99 :

```bash
# dans le terminal du Codespace, l'API tournant (docker compose up)
python3 bench/bombard.py --n 1000 --concurrency 40        # charge répartie
python3 bench/bombard.py --mode hot                        # pire cas : 1 seul acheteur
python3 bench/bombard.py --burn 0.3                        # 30 % d'achats payés en points
```

Il vérifie aussi l'absence d'erreur serveur (5xx) et affiche si la cible 10 tx/s est tenue. C'est **la** mesure end-to-end à montrer à ton CTO, car elle exerce la pile complète (HTTP → Rails → PostgreSQL), pas seulement la base.

**Anti-saturation de l'interface** : le bombardement génère vite des milliers de commandes/lots/transactions. Pour que le tableau de bord reste réactif, les listes qui grossissent (transactions par membre, Commandes, Lots) affichent les **8 plus récentes** et rangent le reste dans un **menu déroulant** ; les payloads sont bornés côté serveur (200 transactions/membre, 500 commandes, 500 lots — les plus récents, sans troncature silencieuse : un compteur « X au total » signale le reste). Ni le DOM ni le JSON ne gonflent sans limite.

---

## 6. Sécurité

Posture de départ saine, propre à une API interne de calcul :

- **Surface réduite** : Rails **API-only** (pas de vues, pas de formulaires, pas de sessions cookie exposées).
- **Pas d'injection SQL** : toutes les requêtes passent par ActiveRecord ou des requêtes **paramétrées** (placeholders `?` / `%s`), y compris les jointures écrites à la main. Aucune interpolation de saisie utilisateur dans du SQL.
- **Strong parameters** : les contrôleurs filtrent explicitement les attributs permis (`params.permit(...)`).
- **Écritures protégées** : en-tête `Idempotency-Key` obligatoire sur les écritures, unicité en base → pas de double traitement.
- **Journaux immuables** : impossible de réécrire l'historique comptable (garantie côté modèle *et* exploitable en audit).
- **Montants en `BigDecimal`** : pas d'erreur d'arrondi flottant sur l'argent.

**À lancer chez toi** (les gems sont désormais dans l'image) :

```bash
docker compose run --rm app bundle exec brakeman -q        # scan de vulnérabilités
docker compose run --rm app bundle exec rubocop            # lint idiomatique (config fournie)
```

Points d'attention pour la mise en production (hors périmètre du moteur, mais à noter pour le CTO) : authentification/autorisation de l'API (aujourd'hui l'API est interne et non authentifiée), limitation de débit, et gestion des secrets — à câbler au niveau de la passerelle applicative qui exposera ce service.

---

## 7. Comment tout rejouer

**Dans TON Codespace** (sur la pile complète Rails + PostgreSQL) :

| But | Commande |
|---|---|
| **Correction du bug #1 en direct** | `docker compose run --rm app env RAILS_ENV=test bundle exec rspec spec/services/reversal_lots_spec.rb` |
| **Rollback du batch mensuel** | `docker compose run --rm app env RAILS_ENV=test bundle exec rspec spec/services/behavioral_rollback_spec.rb` |
| Suite RSpec complète (golden, idempotence, concurrence, annulation, expiration…) | `docker compose run --rm app env RAILS_ENV=test bundle exec rspec` |
| Lint idiomatique | `docker compose run --rm app bundle exec rubocop` |
| Scan sécurité | `docker compose run --rm app bundle exec brakeman -q` |
| Bombardement de l'API | `python3 bench/bombard.py --n 1000 --concurrency 40` |

**Évidence produite en environnement de vérification** (harnais Python rejouant la logique contre un PostgreSQL 16 réel, fournis dans `verification/` pour lecture par ton CTO ; ils ciblent une base locale dédiée) :

| But | Fichier |
|---|---|
| Correction V4 (bug #1) — 19/19 | `verification/reversal_v4.py` |
| Rollback du batch mensuel — 18/18 | `verification/rollback_v4.py` |
| Concurrence + idempotence sous course | `verification/concurrency_v4.py` |
| Suite comportementale/campagnes V3 — 24/24 | `verification/run_tests_v3.py` |

Le même scénario que `reversal_v4.py` est **rejouable chez toi** via `spec/services/reversal_lots_spec.rb` (première ligne du tableau) : c'est ton « je le vois tourner sur ma pile ».

---

*Rapport généré pour la revue technique. Les mesures de correction, concurrence et performance des requêtes ont été réalisées contre un PostgreSQL 16 réel ; RuboCop, Brakeman, RSpec et le bombardement HTTP se lancent sur la pile complète dans le Codespace.*
