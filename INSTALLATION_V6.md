# Winpass V6 — Phase 1 : installation & recette

**Périmètre livré :** programme de **cashback** (deux soldes + conversion au seuil et sur cadence), **enrôlement** (OTP e-mail, invitation, CGU/CGV, import de masse, éligibilité « 15 jours »), **fraude** (blocage du parrain), et **espace parrain** confidentiel. Bâti sur la base V5.1, sans toucher au cœur Earn/Burn/Annulation.

---

## 1. Pré-requis

Identiques à la V5.1 : Docker + Docker Compose (ou GitHub Codespaces). Rien de neuf à installer.

## 2. Mise en place

Depuis la racine `winpass-loyalty/` :

```bash
docker compose build
docker compose up -d
```

Puis, dans le conteneur applicatif :

```bash
docker compose exec app bundle exec rails db:migrate   # crée les 7 tables V6 + colonnes memberships
docker compose exec app bundle exec rails db:seed       # ajoute la config cashback (seuil 20 €, cadence hebdo)
```

> La migration V6 est `db/migrate/20260201000001_v6_phase1_cashback_enrollment.rb`. Elle est **additive** : elle ne modifie aucune table existante autrement qu'en **ajoutant** des colonnes à `memberships`.

## 3. Ce que la migration crée

| Table | Rôle |
|---|---|
| `cashback_configs` | seuil de conversion (défaut 20,00 €) + cadence (défaut 7 j), versionnés |
| `cashback_accounts` | deux soldes par membre : **en attente** / **Crédit Winpass** + cumul à vie |
| `cashback_conversions` | journal des conversions (`threshold` / `cadence` / `manual`) |
| `member_poche_counters` | compteur global des **autres** poches (informationnel) |
| `otp_challenges` | codes OTP e-mail (usage unique, expiration, tentatives) |
| `enrollment_invitations` | invitations (jeton, CGU/CGV, `app` / `mass_import`) |
| `fraud_cases` | dossiers de fraude + blocage du parrain |

Colonnes ajoutées à `memberships` : `email`, `first_purchase_at`, `blocked`, `blocked_reason`, `cgu_accepted_at`, `cgv_accepted_at`.

## 4. Écrans

- **`/moi.html`** — application membre : Crédit Winpass, cashback en attente (barre vers le seuil), bouton *Convertir maintenant*, compteur des autres poches, réseau de parrainage (filleuls directs nommés, niveaux suivants anonymisés).
- **`/enroll.html?token=…`** — landing d'acceptation : vérification e-mail (OTP), CGU + CGV obligatoires, création de l'adhésion.
- **`/v6.html`** — back-office : consultation/conversion cashback, batch cadence, éligibilité parrain, invitation, import de masse, gestion des dossiers de fraude.
- **`/index.html`** — tableau de bord V5.1 (inchangé).

## 5. API V6 (préfixe `/v1`)

```
GET  /v1/cashback?member_id=            soldes du membre
POST /v1/cashback/convert               conversion manuelle
POST /v1/cashback/cadence/run           batch hebdo (à planifier)

POST /v1/enrollments/otp                émet un OTP e-mail
POST /v1/enrollments/otp/verify         vérifie l'OTP
GET  /v1/enrollments/eligibility        le membre peut-il enrôler ?
POST /v1/enrollments/invite             un parrain invite un filleul
POST /v1/enrollments/accept             acceptation CGU/CGV -> adhésion
POST /v1/enrollments/import             import de masse (email;parrain)

GET  /v1/fraud                          liste des dossiers
POST /v1/fraud/open                     signale un filleul -> bloque le parrain
POST /v1/fraud/:id/confirm              fraude avérée
POST /v1/fraud/:id/clear                blanchi -> lève le blocage

GET  /v1/parrain?member_id=             espace parrain (confidentiel)
```

## 6. Recette automatique (30 contrôles)

```bash
docker compose exec app bundle exec rails runner verification/recette_v6.rb
```

Elle joue les scénarios sur des membres de test dédiés (ids 9100+, e-mails `@recette.winpass`), affiche `[PASS]/[FAIL]` **avec les vrais chiffres**, et **se nettoie** au départ comme à la fin (rejouable à l'infini). Elle prouve notamment :

- le socle 40 % alimente le solde « en attente » ; conversion **au seuil** (20 €), **sur cadence** (hebdo) et **manuelle** ;
- le compteur des autres poches et le « parrainage reçu » sont bien alimentés ;
- **le cœur Earn n'est pas altéré** (le portefeuille est crédité comme en V5.1) ;
- la date du 1er achat pilote l'**éligibilité « 15 jours »** ; OTP, invitation, CGU/CGV obligatoires, création d'adhésion, import de masse ;
- la **fraude** bloque le parrain (et le rend inéligible), la levée retire le blocage ;
- la **vue parrain ne divulgue jamais la commission**.

Sortie attendue : `RÉSULTAT V6 : 30 PASS / 0 FAIL — TOUT VERT`.

## 7. Planification de la cadence

Le batch de conversion hebdomadaire s'appelle par `POST /v1/cashback/cadence/run` (ou `ConversionEngine.run_cadence!` en `rails runner`). À brancher sur le planificateur (cron / scheduler) selon `cadence_days`.
