# frozen_string_literal: true

# Schéma du moteur de fidélité — Earn (Personnel + Parrainage), Burn (paiement en
# points, FEFO) et Annulation (par commande, en cascade).
#
# Les contraintes fortes sont posées AU NIVEAU DE LA BASE (et non seulement dans
# le code Ruby) : unicité de la clé d'idempotence, unicité d'une relation de
# parrainage active, exclusion des périodes qui se chevauchent, contrôles
# d'intégrité sur les montants et les lots. C'est ce qui garantit la justesse
# même en cas d'appels concurrents. Ce schéma a été validé contre un PostgreSQL
# réel avant portage.
class CreateLoyaltyCore < ActiveRecord::Migration[7.2]
  def change
    enable_extension "btree_gist" # requis pour la contrainte d'exclusion sur les périodes

    # --- Registre d'adhésion (le membre "au sens fidélité") ------------------
    create_table :memberships do |t|
      t.bigint   :member_id, null: false          # référence externe (cœur de système)
      t.string   :display_name                     # confort d'affichage (démo/tableau de bord)
      t.string   :status, null: false, default: "active"
      t.datetime :enrolled_at, null: false
      t.timestamps
    end
    add_index :memberships, :member_id, unique: true
    add_check_constraint :memberships, "status IN ('active','suspended','closed')", name: "memberships_status_check"

    # --- Configuration versionnée du calcul ----------------------------------
    create_table :reward_configs do |t|
      t.string   :version_label, null: false
      t.decimal  :personal_rate,       precision: 6, scale: 5, null: false
      t.decimal  :sponsorship_rate,    precision: 6, scale: 5, null: false
      t.decimal  :fonctionnement_rate, precision: 6, scale: 5, null: false
      t.decimal  :comportemental_rate, precision: 6, scale: 5, null: false
      t.decimal  :grands_leaders_rate, precision: 6, scale: 5, null: false
      t.decimal  :sponsorship_ratio,   precision: 6, scale: 5, null: false
      t.integer  :sponsorship_max_generation, null: false, default: 5
      t.jsonb    :distributions, null: false, default: {}
      t.integer  :inactivity_months, null: false, default: 4
      t.integer  :expiration_months, null: false, default: 24
      t.datetime :effective_from, null: false
      t.datetime :effective_to
      t.timestamps
    end
    add_index :reward_configs, :version_label, unique: true
    execute <<~SQL
      CREATE UNIQUE INDEX idx_reward_configs_current
        ON reward_configs ((effective_to IS NULL)) WHERE effective_to IS NULL;
    SQL

    # --- Journal du parrainage (historisé) -----------------------------------
    create_table :member_sponsorships do |t|
      t.bigint   :member_id,         null: false
      t.bigint   :sponsor_member_id, null: false
      t.datetime :effective_from,    null: false
      t.datetime :effective_to
      t.string   :reason,            null: false
      t.timestamps
    end
    add_index :member_sponsorships, %i[member_id effective_to]
    add_index :member_sponsorships, %i[member_id effective_from]
    add_index :member_sponsorships, :sponsor_member_id
    add_check_constraint :member_sponsorships, "member_id <> sponsor_member_id", name: "no_self_sponsor"
    execute <<~SQL
      CREATE UNIQUE INDEX idx_sponsorship_active
        ON member_sponsorships (member_id) WHERE effective_to IS NULL;
    SQL
    # Aucune période qui se chevauche pour un même membre.
    # NB : `datetime` Rails = `timestamp` (sans fuseau) -> on utilise `tsrange`
    # (et non `tstzrange`) pour que l'expression de l'index soit IMMUTABLE.
    execute <<~SQL
      ALTER TABLE member_sponsorships ADD CONSTRAINT no_overlap
        EXCLUDE USING gist (
          member_id WITH =,
          tsrange(effective_from, COALESCE(effective_to, 'infinity')) WITH &&
        );
    SQL

    # --- Portefeuille (projection du solde) ----------------------------------
    create_table :wallets do |t|
      t.bigint  :member_id, null: false
      t.string  :unit, null: false, default: "EUR"
      t.decimal :available_balance,   precision: 18, scale: 6, null: false, default: 0
      t.decimal :personal_counter,    precision: 18, scale: 6, null: false, default: 0
      t.decimal :sponsorship_counter, precision: 18, scale: 6, null: false, default: 0
      t.timestamps
    end
    add_index :wallets, :member_id, unique: true
    add_check_constraint :wallets, "available_balance >= 0", name: "wallet_balance_non_negative"

    # --- Journal des attributions (immuable) ---------------------------------
    create_table :earn_ledgers do |t|
      t.bigint   :member_id, null: false
      t.references :member_sponsorship, foreign_key: true
      t.references :reward_config, foreign_key: true
      t.bigint   :order_id
      t.string   :merchant_id
      t.decimal  :order_amount,    precision: 18, scale: 6
      t.decimal  :commission_rate, precision: 6,  scale: 4
      t.string   :earn_type, null: false
      t.integer  :generation, null: false, limit: 2
      t.decimal  :amount,       precision: 18, scale: 6, null: false
      t.decimal  :applied_rate, precision: 12, scale: 9
      t.datetime :delivered_at, null: false
      t.datetime :expires_at
      t.timestamps
    end
    add_index :earn_ledgers, %i[member_id created_at]
    add_index :earn_ledgers, :order_id
    add_check_constraint :earn_ledgers, "amount > 0", name: "earn_amount_positive"
    add_check_constraint :earn_ledgers,
                         "earn_type IN ('personal','sponsorship','comportemental','adjustment')",
                         name: "earn_type_check"

    # --- Lots (projection FEFO) ----------------------------------------------
    create_table :wallet_lots do |t|
      t.references :earn, null: false, foreign_key: { to_table: :earn_ledgers }, index: { unique: true }
      t.bigint   :member_id, null: false
      t.string   :unit, null: false, default: "EUR"
      t.decimal  :initial_amount, precision: 18, scale: 6, null: false
      t.decimal  :remaining,      precision: 18, scale: 6, null: false
      t.datetime :earned_at,  null: false
      t.datetime :expires_at, null: false
      t.timestamps
    end
    add_index :wallet_lots, %i[member_id expires_at earned_at id], name: "idx_lots_fefo"
    add_check_constraint :wallet_lots, "remaining >= 0", name: "lot_remaining_non_negative"
    add_check_constraint :wallet_lots, "remaining <= initial_amount", name: "lot_remaining_le_initial"
    add_check_constraint :wallet_lots, "initial_amount > 0", name: "lot_initial_positive"

    # --- Paiements en points (Burn) ------------------------------------------
    create_table :payments do |t|
      t.bigint  :member_id, null: false
      t.bigint  :order_id
      t.string  :merchant_id
      t.decimal :amount, precision: 18, scale: 6, null: false
      t.string  :unit, null: false, default: "EUR"
      t.string  :status, null: false, default: "settled"
      t.timestamps
    end
    add_index :payments, %i[member_id created_at]
    add_index :payments, :order_id
    add_check_constraint :payments, "amount > 0", name: "payment_amount_positive"
    add_check_constraint :payments, "status IN ('settled','reversed')", name: "payment_status_check"

    # --- Allocation FEFO d'un paiement sur les lots consommés ----------------
    create_table :payment_allocations do |t|
      t.references :payment,     null: false, foreign_key: true
      t.references :wallet_lot,  null: false, foreign_key: true
      t.decimal :amount, precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_check_constraint :payment_allocations, "amount > 0", name: "alloc_amount_positive"

    # --- Annulations (une par commande) --------------------------------------
    create_table :reversals do |t|
      t.bigint  :order_id, null: false
      t.string  :reversal_type, null: false               # 'earn' | 'burn' | 'earn+burn'
      t.decimal :earn_clawback_total, precision: 18, scale: 6, null: false, default: 0
      t.decimal :burn_restored_total, precision: 18, scale: 6, null: false, default: 0
      t.timestamps
    end
    add_index :reversals, :order_id, unique: true
    add_check_constraint :reversals,
                         "reversal_type IN ('earn','burn','earn+burn')",
                         name: "reversal_type_check"

    # --- Relevé chronologique enrichi (source du tableau de bord) ------------
    create_table :wallet_statements do |t|
      t.bigint   :member_id, null: false
      t.string   :kind,  null: false   # personal_earn|sponsorship_earn|burn|reversal_earn|reversal_burn
      t.string   :label, null: false
      t.integer  :generation, limit: 2
      t.bigint   :order_id
      t.string   :merchant_id
      t.bigint   :counterparty_member_id
      t.decimal  :amount,        precision: 18, scale: 6, null: false   # signé
      t.decimal  :balance_after, precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_index :wallet_statements, %i[member_id id]
    add_check_constraint :wallet_statements,
                         "kind IN ('personal_earn','sponsorship_earn','burn','reversal_earn','reversal_burn')",
                         name: "statement_kind_check"

    # --- Réserves (journal) --------------------------------------------------
    create_table :pool_contributions do |t|
      t.string  :pool_type, null: false
      t.bigint  :order_id
      t.bigint  :source_member_id
      t.decimal :amount, precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_check_constraint :pool_contributions, "amount > 0", name: "pool_amount_positive"
    add_check_constraint :pool_contributions,
                         "pool_type IN ('fonctionnement','grands_leaders','comportemental')",
                         name: "pool_type_check"

    # --- Idempotence (technique) ---------------------------------------------
    create_table :processed_events do |t|
      t.string :event_key,  null: false
      t.string :event_type, null: false
      t.string :status,     null: false, default: "processing"
      t.jsonb  :result_ref
      t.timestamps
    end
    add_index :processed_events, :event_key, unique: true
  end
end
