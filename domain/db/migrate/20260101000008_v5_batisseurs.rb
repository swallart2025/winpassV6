# frozen_string_literal: true

# V5 — Bâtisseurs (statut des parrains). Migration ADDITIVE.
#
#   * builder_statuses : rang (0..6 = Graine..Canopée) et Score Forêt tenu.
#   * builder_prime_rewards : primes de rang versées (par période/trimestre),
#     photo immuable par (member_id, period).
#   * builder_rfa_rewards : versements RFA (février), photo immuable par
#     (member_id, year).
#   * builder_reserves : pot RFA accumulé par année (résidu non distribué).
class V5Batisseurs < ActiveRecord::Migration[7.2]
  def change
    create_table :builder_statuses do |t|
      t.bigint   :member_id, null: false
      t.integer  :rang, null: false, default: 0        # 0 Graine .. 6 Canopée
      t.decimal  :score_foret, precision: 12, scale: 4, null: false, default: 0
      t.integer  :compteur_repli, null: false, default: 0
      t.timestamps
    end
    add_index :builder_statuses, :member_id, unique: true
    add_check_constraint :builder_statuses, "rang BETWEEN 0 AND 6", name: "builder_rang_range"

    create_table :builder_prime_rewards do |t|
      t.bigint   :member_id, null: false
      t.string   :period, null: false                  # trimestre 'YYYY-Qn' ou 'YYYY-MM'
      t.integer  :rang, null: false
      t.decimal  :assiette,  precision: 18, scale: 6, null: false   # assiette géométrique cumulée
      t.decimal  :prime,     precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_index :builder_prime_rewards, %i[member_id period], unique: true

    create_table :builder_rfa_rewards do |t|
      t.bigint   :member_id, null: false
      t.integer  :year, null: false
      t.decimal  :share,  precision: 18, scale: 9, null: false      # part au prorata
      t.decimal  :amount, precision: 18, scale: 6, null: false
      t.timestamps
    end
    add_index :builder_rfa_rewards, %i[member_id year], unique: true

    create_table :builder_reserves do |t|
      t.integer  :year, null: false
      t.decimal  :pocket_total,      precision: 18, scale: 6, null: false, default: 0
      t.decimal  :distributed_total, precision: 18, scale: 6, null: false, default: 0
      t.decimal  :rfa_total,         precision: 18, scale: 6, null: false, default: 0
      t.timestamps
    end
    add_index :builder_reserves, :year, unique: true

    # Primes de rang & RFA = earns créditant le portefeuille.
    remove_check_constraint :earn_ledgers, name: "earn_type_check"
    add_check_constraint :earn_ledgers,
                         "earn_type IN ('personal','sponsorship','comportemental','adjustment'," \
                         "'prime_statut','prime_rang','rfa')",
                         name: "earn_type_check"
    remove_check_constraint :wallet_statements, name: "statement_kind_check"
    add_check_constraint :wallet_statements,
                         "kind IN ('personal_earn','sponsorship_earn','burn','reversal_earn'," \
                         "'reversal_burn','expiration','campaign_cashback','prime_statut'," \
                         "'prime_rang','rfa')",
                         name: "statement_kind_check"
  end
end
