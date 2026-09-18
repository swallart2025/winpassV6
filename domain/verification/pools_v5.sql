-- Preuve V5 sur PostgreSQL réel : correctifs cagnottes B2 / B4 / B6.
-- Reproduit le schéma V5 (occurred_at + montants signés) et la logique du code
-- corrigé (monthly_potential sur occurred_at ; reversal = compensations négatives,
-- comportemental épargné si déjà consommé par le batch).

DROP TABLE IF EXISTS pool_contributions;
DROP TABLE IF EXISTS member_monthly_rewards;

CREATE TABLE pool_contributions (
  id bigserial PRIMARY KEY,
  pool_type text NOT NULL CHECK (pool_type IN ('fonctionnement','grands_leaders','comportemental')),
  order_id bigint,
  source_member_id bigint,
  amount numeric(18,6) NOT NULL CHECK (amount <> 0),   -- V5 : signé
  occurred_at timestamp NOT NULL,                       -- V5 : date métier
  created_at timestamp NOT NULL DEFAULT now()
);
CREATE TABLE member_monthly_rewards (
  member_id bigint, period text, UNIQUE(member_id, period)
);

-- Membre 500. On simule le 23/08 (created_at = aujourd'hui) des achats ANTIDATÉS en JUILLET.
-- Commande O1 = 400 € (base 8 €) -> fonct 1.00, leaders 0.60, compo 1.20  (occurred_at 2026-07-30)
-- Commande O2 = 200 € (base 4 €) -> compo 0.60                            (occurred_at 2026-07-15)
INSERT INTO pool_contributions (pool_type, order_id, source_member_id, amount, occurred_at, created_at) VALUES
 ('fonctionnement', 1, 500, 1.00, '2026-07-30 10:00', '2026-08-23 09:00'),
 ('grands_leaders', 1, 500, 0.60, '2026-07-30 10:00', '2026-08-23 09:00'),
 ('comportemental', 1, 500, 1.20, '2026-07-30 10:00', '2026-08-23 09:00'),
 ('comportemental', 2, 500, 0.60, '2026-07-15 10:00', '2026-08-23 09:00');

\echo '=== B4 : le potentiel de JUILLET se lit sur occurred_at, pas sur created_at ==='
SELECT
  (SELECT COALESCE(SUM(amount),0) FROM pool_contributions
     WHERE pool_type='comportemental' AND source_member_id=500
       AND to_char(occurred_at,'YYYY-MM')='2026-07') AS juillet_sur_occurred_at,
  (SELECT COALESCE(SUM(amount),0) FROM pool_contributions
     WHERE pool_type='comportemental' AND source_member_id=500
       AND to_char(created_at,'YYYY-MM')='2026-07') AS juillet_sur_created_at_bug;
\echo 'Attendu : occurred_at = 1.80 (fix)  |  created_at = 0.00 (ancien bug)'

\echo ''
\echo '=== ANNULATION de O1 : compensations negatives (comportemental NON encore consomme) ==='
-- Reproduit reversal_engine.compensate_pools! : negatif pour chaque pool positif de la commande,
-- comportemental epargne seulement si une photo mensuelle existe (ici : aucune -> on reprend).
INSERT INTO pool_contributions (pool_type, order_id, source_member_id, amount, occurred_at, created_at)
SELECT pool_type, order_id, source_member_id, -amount, occurred_at, '2026-08-23 12:00'
FROM pool_contributions orig
WHERE orig.order_id = 1 AND orig.amount > 0
  AND NOT (orig.pool_type='comportemental'
           AND EXISTS (SELECT 1 FROM member_monthly_rewards m
                       WHERE m.member_id=orig.source_member_id
                         AND m.period=to_char(orig.occurred_at,'YYYY-MM')));

\echo 'B2 : cagnottes plateforme de O1 revenues a zero (fonct/leaders/compo) :'
SELECT pool_type, SUM(amount) AS solde_pool
FROM pool_contributions WHERE order_id=1 GROUP BY pool_type ORDER BY pool_type;
\echo 'Attendu : comportemental 0.000000 | fonctionnement 0.000000 | grands_leaders 0.000000'

\echo ''
\echo '=== B6 : potentiel comportemental JUILLET du membre = O2 seul (O1 annulee exclue) ==='
SELECT COALESCE(SUM(amount),0) AS potentiel_juillet
FROM pool_contributions
WHERE pool_type='comportemental' AND source_member_id=500
  AND to_char(occurred_at,'YYYY-MM')='2026-07';
\echo 'Attendu : 0.600000 (1.20 de O1 annulee - 1.20 compensation + 0.60 de O2)'

\echo ''
\echo '=== Regle ACQUIS : si le batch de juillet a DEJA paye, la compo de O1 n est PAS reprise ==='
-- On repart proprement et on marque le batch juillet comme execute.
DELETE FROM pool_contributions;
INSERT INTO pool_contributions (pool_type, order_id, source_member_id, amount, occurred_at, created_at) VALUES
 ('comportemental', 1, 500, 1.20, '2026-07-30 10:00', '2026-08-23 09:00');
INSERT INTO member_monthly_rewards (member_id, period) VALUES (500, '2026-07');
-- Annulation de O1 : la compo est epargnee (photo existante) -> pas de negatif insere.
INSERT INTO pool_contributions (pool_type, order_id, source_member_id, amount, occurred_at, created_at)
SELECT pool_type, order_id, source_member_id, -amount, occurred_at, '2026-08-23 12:00'
FROM pool_contributions orig
WHERE orig.order_id = 1 AND orig.amount > 0
  AND NOT (orig.pool_type='comportemental'
           AND EXISTS (SELECT 1 FROM member_monthly_rewards m
                       WHERE m.member_id=orig.source_member_id
                         AND m.period=to_char(orig.occurred_at,'YYYY-MM')));
SELECT COALESCE(SUM(amount),0) AS compo_juillet_apres_annulation
FROM pool_contributions WHERE pool_type='comportemental' AND source_member_id=500;
\echo 'Attendu : 1.200000 (recompense deja versee = ACQUISE, non reprise)'
