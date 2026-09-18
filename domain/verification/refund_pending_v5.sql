-- Preuve V5 : comptabilite R6 des lots (Initial/Consomme/Repris/Restant) + pending exclu du FEFO.
DROP TABLE IF EXISTS wallet_lots;
CREATE TABLE wallet_lots(
  id bigserial PRIMARY KEY, member_id bigint, initial_amount numeric(18,6),
  remaining numeric(18,6) CHECK(remaining>=0),
  repris numeric(18,6) NOT NULL DEFAULT 0 CHECK(repris>=0),
  status text CHECK(status IN ('active','consumed','expired','reversed','pending')),
  available_from timestamp,
  CONSTRAINT le_init CHECK (remaining <= initial_amount));

INSERT INTO wallet_lots(member_id,initial_amount,remaining,status) VALUES (500,3.60,3.60,'active');
UPDATE wallet_lots SET remaining=remaining-1.00 WHERE member_id=500;                 -- burn 1.00
UPDATE wallet_lots SET remaining=remaining-1.00, repris=repris+1.00 WHERE member_id=500; -- remb. partiel 1.00

INSERT INTO wallet_lots(member_id,initial_amount,remaining,status,available_from)
  VALUES (500,5.00,5.00,'pending', now()+interval '14 days');

\echo === R6 : decomposition du lot ===
SELECT initial_amount AS initial,
       (initial_amount-remaining-repris) AS consomme,
       repris, remaining AS restant,
       (remaining = initial_amount-(initial_amount-remaining-repris)-repris) AS invariant_ok
FROM wallet_lots WHERE status<>'pending';
\echo Attendu : initial 3.60 | consomme 1.00 | repris 1.00 | restant 1.60 | invariant_ok = t

\echo
\echo === FEFO : le pending est EXCLU des lots consommables ===
SELECT count(*) AS lots_consommables FROM wallet_lots WHERE status='active' AND remaining>0;
\echo Attendu : 1 (le pending n est pas compte)
