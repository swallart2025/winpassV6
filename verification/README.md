# Harnais de vérification (évidence)

Ces scripts rejouent la **logique métier** contre un **PostgreSQL réel**, avec des
scénarios à résultat connu. Ils ont servi à valider la V4 **avant livraison** et
sont fournis pour lecture/audit par le CTO.

> Ils ciblent une base PostgreSQL **locale dédiée** (par défaut
> `dbname=winpass_test user=winpass password=winpass host=localhost`), et non la
> base Docker du service (créds différentes). Pour les rejouer, adapte la constante
> `DSN` en tête de fichier à ta base, charge un schéma équivalent, puis lance-les.
>
> Dans le Codespace, la preuve **sur la pile Rails+Postgres** est la suite RSpec —
> en particulier `domain/spec/services/reversal_lots_spec.rb` pour le bug #1.

| Fichier | Ce qu'il prouve |
|---|---|
| `reversal_v4.py` | Bug #1 : l'annulation invalide les lots (clamp au reliquat, statut `reversed`, invariant solde==Σlots, jamais de solde négatif, exclusion FEFO). 19/19. |
| `rollback_v4.py` | Purge/rollback du batch mensuel : intact→réinitialisé, (partiellement) utilisé→conservé, rejeu sans double versement, CIC & invariants cohérents. 18/18. |
| `concurrency_v4.py` | Sérialisation par verrou de ligne (aucune mise à jour perdue sous contention) + idempotence sous course. |
| `run_tests_v3.py` + `engine_v3.py` | Moteur comportemental & campagnes (décroissance, seuil, batch mensuel, tout-ou-rien, CIC). 24/24. |
| `schema_v2_reference.sql` | Schéma de référence (cœur earn/burn) utilisé par les harnais. |

Exécution (une fois la base locale et le schéma en place) :

```bash
python3 verification/reversal_v4.py
python3 verification/concurrency_v4.py
python3 verification/run_tests_v3.py
```
