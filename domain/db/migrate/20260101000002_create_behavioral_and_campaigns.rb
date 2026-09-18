# frozen_string_literal: true

# V3 — Moteur comportemental (catégories & barème versionnés, batch mensuel, CIC)
# et campagnes temps réel. Migration ADDITIVE (le cœur Earn/Burn/Annulation reste
# dans la migration 20260101000001). Schéma validé contre un PostgreSQL réel.
class CreateBehavioralAndCampaigns < ActiveRecord::Migration[7.2]
  def change
    # --- Marchand -> catégorie (une catégorie unique par enseigne) -----------
    create_table :merchant_categories do |t|
      t.string :merchant_id, null: false
      t.string :category,    null: false
      t.timestamps
    end
    add_index :merchant_categories, :merchant_id, unique: true

    # --- Catégories de fidélité (VERSIONNÉ, payload jsonb) --------------------
    # categories = [{ name, max, validity_months, qualifying_min }, ...]
    create_table :loyalty_category_configs do |t|
      t.string   :version_label, null: false
      t.jsonb    :categories, null: false, default: []
      t.datetime :effective_from, null: false
      t.datetime :effective_to
      t.timestamps
    end
    add_index :loyalty_category_configs, :version_label, unique: true
    execute <<~SQL
      CREATE UNIQUE INDEX idx_loyalty_cat_current
        ON loyalty_category_configs ((effective_to IS NULL)) WHERE effective_to IS NULL;
    SQL

    # --- Barème d'adhésion (VERSIONNÉ) : tranches = [[from, to, rate], ...] ---
    create_table :adherence_scale_configs do |t|
      t.string   :version_label, null: false
      t.jsonb    :tranches, null: false, default: []
      t.datetime :effective_from, null: false
      t.datetime :effective_to
      t.timestamps
    end
    add_index :adherence_scale_configs, :version_label, unique: true
    execute <<~SQL
      CREATE UNIQUE INDEX idx_adherence_current
        ON adherence_scale_configs ((effective_to IS NULL)) WHERE effective_to IS NULL;
    SQL

    # --- Campagnes (financées par la CIC, temps réel) ------------------------
    create_table :campaigns do |t|
      t.string   :category, null: false
      t.integer  :eligibility_score_max, null: false
      t.string   :reward_type, null: false                 # 'value' | 'percent'
      t.decimal  :reward_value,    precision: 18, scale: 6, null: false
      t.decimal  :budget_reserved, precision: 18, scale: 6, null: false
      t.decimal  :budget_spent,    precision: 18, scale: 6, null: false, default: 0
      t.decimal  :reliquat,        precision: 18, scale: 6
      t.date     :end_date
      t.string   :status, null: false, default: "active"   # 'active' | 'closed'
      t.string   :closed_reason
      t.timestamps
    end
    add_index :campaigns, %i[category status]
    add_check_constraint :campaigns, "reward_type IN ('value','percent')", name: "campaign_reward_type_check"
    add_check_constraint :campaigns, "status IN ('active','closed')", name: "campaign_status_check"
    add_check_constraint :campaigns, "budget_spent >= 0 AND budget_spent <= budget_reserved", name: "campaign_budget_check"
    add_check_constraint :campaigns, "reward_value > 0", name: "campaign_value_check"

    # --- Bonus campagne attribués (temps réel) -------------------------------
    create_table :campaign_rewards do |t|
      t.references :campaign, null: false, foreign_key: true
      t.bigint  :member_id, null: false
      t.bigint  :order_id
      t.decimal :amount, precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_check_constraint :campaign_rewards, "amount > 0", name: "campaign_reward_amount_check"

    # --- Journal de la CIC (cagnotte d'incitation comportementale) -----------
    create_table :cic_ledgers do |t|
      t.string   :kind, null: false      # monthly_contribution | campaign_reserve | campaign_release
      t.decimal  :amount,        precision: 18, scale: 6, null: false   # signé
      t.decimal  :balance_after, precision: 18, scale: 6, null: false
      t.jsonb    :reference
      t.timestamps
    end
    add_check_constraint :cic_ledgers,
                         "kind IN ('monthly_contribution','campaign_reserve','campaign_release')",
                         name: "cic_kind_check"

    # --- Photos mensuelles (immuables) ---------------------------------------
    create_table :member_monthly_rewards do |t|
      t.bigint   :member_id, null: false
      t.string   :period, null: false            # 'YYYY-MM'
      t.decimal  :potential,        precision: 18, scale: 6, null: false
      t.integer  :score, null: false
      t.integer  :unlocked_rate, null: false
      t.decimal  :reward,           precision: 18, scale: 6, null: false
      t.decimal  :cic_contribution, precision: 18, scale: 6, null: false
      t.references :reward_config, foreign_key: true
      t.timestamps
    end
    add_index :member_monthly_rewards, %i[member_id period], unique: true

    create_table :member_monthly_category_scores do |t|
      t.bigint   :member_id, null: false
      t.string   :period, null: false
      t.string   :category, null: false
      t.decimal  :cumulative_amount, precision: 18, scale: 6, null: false, default: 0
      t.decimal  :contribution,      precision: 18, scale: 6, null: false, default: 0
      t.datetime :last_recharge_at
      t.timestamps
    end
    add_index :member_monthly_category_scores, %i[member_id period]

    # --- Ajustements sur le cœur Earn/Burn -----------------------------------
    # Statut explicite du lot (pour distinguer consommé vs expiré dans les vues).
    add_column :wallet_lots, :status, :string, null: false, default: "active"
    add_check_constraint :wallet_lots, "status IN ('active','consumed','expired')", name: "lot_status_check"

    # Nouveaux types de mouvement au relevé : expiration et cashback de campagne.
    remove_check_constraint :wallet_statements, name: "statement_kind_check"
    add_check_constraint :wallet_statements,
                         "kind IN ('personal_earn','sponsorship_earn','burn','reversal_earn'," \
                         "'reversal_burn','expiration','campaign_cashback')",
                         name: "statement_kind_check"
  end
end
