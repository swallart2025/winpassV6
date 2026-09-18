-- ====================================================================
-- Winpass — schéma complet (Earn + Burn + Annulation + Parrainage)
-- Reproduit fidèlement ce que produira la migration ActiveRecord.
-- Les colonnes datetime = timestamp SANS fuseau (comme Rails), d'où tsrange.
-- ====================================================================
DROP SCHEMA public CASCADE; CREATE SCHEMA public;
CREATE EXTENSION IF NOT EXISTS btree_gist;

-- --- Adhésion ---------------------------------------------------------
CREATE TABLE memberships (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  display_name varchar,
  status varchar NOT NULL DEFAULT 'active',
  enrolled_at timestamp NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT memberships_status_check CHECK (status IN ('active','suspended','closed'))
);
CREATE UNIQUE INDEX idx_memberships_member ON memberships(member_id);

-- --- Configuration versionnée ----------------------------------------
CREATE TABLE reward_configs (
  id bigserial PRIMARY KEY,
  version_label varchar NOT NULL,
  personal_rate numeric(6,5) NOT NULL,
  sponsorship_rate numeric(6,5) NOT NULL,
  fonctionnement_rate numeric(6,5) NOT NULL,
  comportemental_rate numeric(6,5) NOT NULL,
  grands_leaders_rate numeric(6,5) NOT NULL,
  sponsorship_ratio numeric(6,5) NOT NULL,
  sponsorship_max_generation int NOT NULL DEFAULT 5,
  distributions jsonb NOT NULL DEFAULT '{}',
  inactivity_months int NOT NULL DEFAULT 4,
  expiration_months int NOT NULL DEFAULT 24,
  effective_from timestamp NOT NULL,
  effective_to timestamp,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_reward_configs_version ON reward_configs(version_label);
CREATE UNIQUE INDEX idx_reward_configs_current ON reward_configs ((effective_to IS NULL)) WHERE effective_to IS NULL;

-- --- Parrainage historisé --------------------------------------------
CREATE TABLE member_sponsorships (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  sponsor_member_id bigint NOT NULL,
  effective_from timestamp NOT NULL,
  effective_to timestamp,
  reason varchar NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT no_self_sponsor CHECK (member_id <> sponsor_member_id)
);
CREATE INDEX idx_spon_member_to ON member_sponsorships(member_id, effective_to);
CREATE INDEX idx_spon_member_from ON member_sponsorships(member_id, effective_from);
CREATE INDEX idx_spon_sponsor ON member_sponsorships(sponsor_member_id);
CREATE UNIQUE INDEX idx_sponsorship_active ON member_sponsorships(member_id) WHERE effective_to IS NULL;
ALTER TABLE member_sponsorships ADD CONSTRAINT no_overlap
  EXCLUDE USING gist (member_id WITH =, tsrange(effective_from, COALESCE(effective_to,'infinity')) WITH &&);

-- --- Portefeuille (projection solde) ---------------------------------
CREATE TABLE wallets (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  unit varchar NOT NULL DEFAULT 'EUR',
  available_balance numeric(18,6) NOT NULL DEFAULT 0,
  personal_counter numeric(18,6) NOT NULL DEFAULT 0,
  sponsorship_counter numeric(18,6) NOT NULL DEFAULT 0,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT wallet_balance_non_negative CHECK (available_balance >= 0)
);
CREATE UNIQUE INDEX idx_wallets_member ON wallets(member_id);

-- --- Journal des attributions (immuable) -----------------------------
CREATE TABLE earn_ledgers (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  member_sponsorship_id bigint,
  reward_config_id bigint,
  order_id bigint,
  merchant_id varchar,
  order_amount numeric(18,6),
  commission_rate numeric(6,4),
  earn_type varchar NOT NULL,
  generation smallint NOT NULL,
  amount numeric(18,6) NOT NULL,
  applied_rate numeric(12,9),
  delivered_at timestamp NOT NULL,
  expires_at timestamp,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT earn_amount_positive CHECK (amount > 0),
  CONSTRAINT earn_type_check CHECK (earn_type IN ('personal','sponsorship','comportemental','adjustment'))
);
CREATE INDEX idx_earn_member_created ON earn_ledgers(member_id, created_at);
CREATE INDEX idx_earn_order ON earn_ledgers(order_id);

-- --- Lots FEFO -------------------------------------------------------
CREATE TABLE wallet_lots (
  id bigserial PRIMARY KEY,
  earn_id bigint NOT NULL,
  member_id bigint NOT NULL,
  unit varchar NOT NULL DEFAULT 'EUR',
  initial_amount numeric(18,6) NOT NULL,
  remaining numeric(18,6) NOT NULL,
  earned_at timestamp NOT NULL,
  expires_at timestamp NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT lot_remaining_non_negative CHECK (remaining >= 0),
  CONSTRAINT lot_remaining_le_initial CHECK (remaining <= initial_amount),
  CONSTRAINT lot_initial_positive CHECK (initial_amount > 0)
);
CREATE UNIQUE INDEX idx_lots_earn ON wallet_lots(earn_id);
CREATE INDEX idx_lots_fefo ON wallet_lots(member_id, expires_at, earned_at, id);

-- --- Paiements en points (Burn) --------------------------------------
CREATE TABLE payments (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  order_id bigint,
  merchant_id varchar,
  amount numeric(18,6) NOT NULL,
  unit varchar NOT NULL DEFAULT 'EUR',
  status varchar NOT NULL DEFAULT 'settled',
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT payment_amount_positive CHECK (amount > 0),
  CONSTRAINT payment_status_check CHECK (status IN ('settled','reversed'))
);
CREATE INDEX idx_payments_member ON payments(member_id, created_at);
CREATE INDEX idx_payments_order ON payments(order_id);

-- --- Allocation FEFO d'un paiement sur les lots ----------------------
CREATE TABLE payment_allocations (
  id bigserial PRIMARY KEY,
  payment_id bigint NOT NULL REFERENCES payments(id),
  wallet_lot_id bigint NOT NULL REFERENCES wallet_lots(id),
  amount numeric(18,6) NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT alloc_amount_positive CHECK (amount > 0)
);
CREATE INDEX idx_alloc_payment ON payment_allocations(payment_id);

-- --- Annulations (par commande) --------------------------------------
CREATE TABLE reversals (
  id bigserial PRIMARY KEY,
  order_id bigint NOT NULL,
  reversal_type varchar NOT NULL,               -- 'earn' | 'burn' | 'earn+burn'
  earn_clawback_total numeric(18,6) NOT NULL DEFAULT 0,
  burn_restored_total numeric(18,6) NOT NULL DEFAULT 0,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT reversal_type_check CHECK (reversal_type IN ('earn','burn','earn+burn'))
);
CREATE UNIQUE INDEX idx_reversals_order ON reversals(order_id);

-- --- Relevé chronologique enrichi (source du tableau de bord) --------
CREATE TABLE wallet_statements (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  kind varchar NOT NULL,   -- personal_earn|sponsorship_earn|burn|reversal_earn|reversal_burn
  label varchar NOT NULL,
  generation smallint,
  order_id bigint,
  merchant_id varchar,
  counterparty_member_id bigint,
  amount numeric(18,6) NOT NULL,           -- signé
  balance_after numeric(18,6) NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT statement_kind_check CHECK (kind IN
    ('personal_earn','sponsorship_earn','burn','reversal_earn','reversal_burn'))
);
CREATE INDEX idx_statements_member ON wallet_statements(member_id, id);

-- --- Réserves (journal) ----------------------------------------------
CREATE TABLE pool_contributions (
  id bigserial PRIMARY KEY,
  pool_type varchar NOT NULL,
  order_id bigint,
  source_member_id bigint,
  amount numeric(18,6) NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT pool_amount_positive CHECK (amount > 0),
  CONSTRAINT pool_type_check CHECK (pool_type IN ('fonctionnement','grands_leaders','comportemental'))
);

-- --- Idempotence -----------------------------------------------------
CREATE TABLE processed_events (
  id bigserial PRIMARY KEY,
  event_key varchar NOT NULL,
  event_type varchar NOT NULL,
  status varchar NOT NULL DEFAULT 'processing',
  result_ref jsonb,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_processed_events_key ON processed_events(event_key);

-- ============================ V3 — Comportemental & campagnes ============================

-- Marchand -> catégorie (une catégorie unique par enseigne)
CREATE TABLE merchant_categories (
  id bigserial PRIMARY KEY,
  merchant_id varchar NOT NULL,
  category varchar NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_merchant_categories_merchant ON merchant_categories(merchant_id);

-- Catégories de fidélité (VERSIONNÉ, payload jsonb comme reward_configs)
-- categories = [{"name","max","validity_months","qualifying_min"}...]
CREATE TABLE loyalty_category_configs (
  id bigserial PRIMARY KEY,
  version_label varchar NOT NULL,
  categories jsonb NOT NULL DEFAULT '[]',
  effective_from timestamp NOT NULL,
  effective_to timestamp,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_loyalty_cat_version ON loyalty_category_configs(version_label);
CREATE UNIQUE INDEX idx_loyalty_cat_current ON loyalty_category_configs((effective_to IS NULL)) WHERE effective_to IS NULL;

-- Barème d'adhésion (VERSIONNÉ) : tranches = [[from,to,rate]...]
CREATE TABLE adherence_scale_configs (
  id bigserial PRIMARY KEY,
  version_label varchar NOT NULL,
  tranches jsonb NOT NULL DEFAULT '[]',
  effective_from timestamp NOT NULL,
  effective_to timestamp,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_adherence_version ON adherence_scale_configs(version_label);
CREATE UNIQUE INDEX idx_adherence_current ON adherence_scale_configs((effective_to IS NULL)) WHERE effective_to IS NULL;

-- Campagnes (financées par la CIC, temps réel)
CREATE TABLE campaigns (
  id bigserial PRIMARY KEY,
  category varchar NOT NULL,
  eligibility_score_max int NOT NULL,
  reward_type varchar NOT NULL,             -- 'value' | 'percent'
  reward_value numeric(18,6) NOT NULL,
  budget_reserved numeric(18,6) NOT NULL,
  budget_spent numeric(18,6) NOT NULL DEFAULT 0,
  reliquat numeric(18,6),
  end_date date,
  status varchar NOT NULL DEFAULT 'active',  -- 'active' | 'closed'
  closed_reason varchar,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT campaign_reward_type_check CHECK (reward_type IN ('value','percent')),
  CONSTRAINT campaign_status_check CHECK (status IN ('active','closed')),
  CONSTRAINT campaign_budget_check CHECK (budget_spent >= 0 AND budget_spent <= budget_reserved),
  CONSTRAINT campaign_value_check CHECK (reward_value > 0)
);
CREATE INDEX idx_campaigns_cat_status ON campaigns(category, status);

-- Bonus campagne attribués (temps réel)
CREATE TABLE campaign_rewards (
  id bigserial PRIMARY KEY,
  campaign_id bigint NOT NULL REFERENCES campaigns(id),
  member_id bigint NOT NULL,
  order_id bigint,
  amount numeric(18,6) NOT NULL,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT campaign_reward_amount_check CHECK (amount > 0)
);
CREATE INDEX idx_campaign_rewards_campaign ON campaign_rewards(campaign_id);

-- Journal de la CIC (cagnotte d'incitation comportementale)
CREATE TABLE cic_ledger (
  id bigserial PRIMARY KEY,
  kind varchar NOT NULL,   -- monthly_contribution | campaign_reserve | campaign_release
  amount numeric(18,6) NOT NULL,          -- signé (+ crédit, - débit)
  balance_after numeric(18,6) NOT NULL,
  reference jsonb,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now(),
  CONSTRAINT cic_kind_check CHECK (kind IN ('monthly_contribution','campaign_reserve','campaign_release'))
);
CREATE INDEX idx_cic_ledger_created ON cic_ledger(id);

-- Photos mensuelles (immuables)
CREATE TABLE member_monthly_rewards (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  period varchar NOT NULL,                 -- 'YYYY-MM'
  potential numeric(18,6) NOT NULL,
  score int NOT NULL,
  unlocked_rate int NOT NULL,
  reward numeric(18,6) NOT NULL,
  cic_contribution numeric(18,6) NOT NULL,
  reward_config_id bigint,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE UNIQUE INDEX idx_monthly_rewards_member_period ON member_monthly_rewards(member_id, period);

CREATE TABLE member_monthly_category_scores (
  id bigserial PRIMARY KEY,
  member_id bigint NOT NULL,
  period varchar NOT NULL,
  category varchar NOT NULL,
  cumulative_amount numeric(18,6) NOT NULL DEFAULT 0,
  contribution numeric(18,6) NOT NULL DEFAULT 0,
  last_recharge_at timestamp,
  created_at timestamp NOT NULL DEFAULT now(),
  updated_at timestamp NOT NULL DEFAULT now()
);
CREATE INDEX idx_monthly_cat_scores ON member_monthly_category_scores(member_id, period);
