# Winpass V5 — Installation & recette

> V5 construite **sur le socle V4** (aucune réécriture : 75/84 fichiers V4 inchangés, 9 édités, le reste ajouté). Migrations **additives** 0005→0009 empilées sur 0001→0004.

## Contenu V5
- **Correctifs** : B2 (annulation reprend les cagnottes plateforme), B3 (achat du jour compté), B4 (achat antidaté vu dans son mois), B5 (batch/purge idempotents par état, messages), B6 (annulé exclu de l'assiette comportementale), B8 (score arrondi au supérieur), B9 (score du jour autoritaire + émulation).
- **Bascule budget** : personnel **40 % socle** + poche **Prime de Statut 5 %** (config `V5-2026`).
- **Statut acheteur** : score → niveau (20) → freins (`status/*`, `member_statuses`).
- **Prime de Statut** : `p` déduit par équation, grille 0,5 %, plafond 100 %, réserve (`prime-statut/*`).
- **Bâtisseurs** : rangs (Score Forêt) + primes de rang 0→10 % + RFA (`builders/*`).
- **Remboursement R1–R6** + **solde en attente** (`refunds`, `pending/activate`, webhook R5).
- **Back-office** : onglet « ✨ V5 · Générosité », cagnottes enrichies (poche Prime de Statut), messages de résultat après chaque action.

## Installation (dans le Codespace)
```bash
docker compose up --build           # rebuild (nouvelles migrations + gems inchangées)
# les migrations 20260101000005..0009 s'appliquent ; les seeds créent V5-2026 + PS-V1-2026
```
Aucune donnée V4 perdue : les earns V4 restent rattachés à la config `V1-2026` (rejouabilité).

## Nouveaux endpoints
`POST /v1/status/run` · `GET /v1/status` · `POST /v1/prime-statut/run` · `GET /v1/prime-statut` ·
`POST /v1/builders/run` · `POST /v1/builders/primes/run` · `GET /v1/builders` ·
`POST /v1/refunds` · `POST /v1/pending/activate`.

## Recette (à rejouer avant toute livraison)
```bash
cd domain && bash verification/run_recette_v5.sh
```
Attendu : **8 OK / 0 FAIL — TOUT VERT**. Couvre : syntaxe Ruby de tous les fichiers ; preuves pures
(grille Prime de Statut reproduite, freins Sofia, Bâtisseurs, règlement remboursement) ; preuves
PostgreSQL (cagnottes B2/B4/B6, lot R6 + pending, intégration Prime de Statut).

## Paramètres d'ajustement (config)
- `reward_engine` : personal 0.40 · prime_statut 0.05 · sponsorship 0.20 · comportemental 0.15 · fonctionnement 0.125 · grands_leaders 0.075 · `sponsor_refund_mode` (buyer_covers|clawback).
- `prime_statut` : `pas` 0.005 · `plafond` 0.60 (`p` déduit, non configurable).
