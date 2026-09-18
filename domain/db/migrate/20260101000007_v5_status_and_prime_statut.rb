# frozen_string_literal: true

# V5 — Statut acheteur (niveau tenu) et moteur Prime de performance collective de
# Statut. Migration ADDITIVE.
#
#   * member_statuses : le niveau (1..20) TENU par chaque membre (rempli par le
#     batch de statut) — entrée du moteur Prime de Statut.
#   * prime_statut_configs : paramètres versionnés (pas, plafond, poche_rate).
#     `p` n'est PAS stocké : il est déduit par équation à chaque exécution.
#   * prime_statut_rewards : photo par (membre, période) — assiette, majoration,
#     prime versée. Unicité (member_id, period) = idempotence par état.
#   * prime_statut_reserves : réserve reportée entre périodes (reliquat de grille).
class V5StatusAndPrimeStatut < ActiveRecord::Migration[7.2]
  def change
    create_table :member_statuses do |t|
      t.bigint   :member_id, null: false
      t.integer  :niveau_tenu,  null: false, default: 1   # 1..20
      t.integer  :grand_niveau, null: false, default: 1   # 1..5
      t.datetime :date_entree_gn
      t.integer  :compteur_repli, null: false, default: 0
      t.timestamps
    end
    add_index :member_statuses, :member_id, unique: true
    add_check_constraint :member_statuses, "niveau_tenu BETWEEN 1 AND 20", name: "status_niveau_range"
    add_check_constraint :member_statuses, "grand_niveau BETWEEN 1 AND 5", name: "status_gn_range"

    create_table :prime_statut_configs do |t|
      t.string   :version_label, null: false
      t.decimal  :poche_rate, precision: 6, scale: 5, null: false, default: "0.05"
      t.decimal  :pas,        precision: 6, scale: 5, null: false, default: "0.005"  # grille 0,5 %
      t.decimal  :plafond,    precision: 6, scale: 5, null: false, default: "0.60"   # +60 pts -> 100 %
      t.integer  :niveaux,    null: false, default: 20
      t.datetime :effective_from, null: false
      t.datetime :effective_to
      t.timestamps
    end
    add_index :prime_statut_configs, :version_label, unique: true
    execute <<~SQL
      CREATE UNIQUE INDEX idx_prime_statut_current
        ON prime_statut_configs ((effective_to IS NULL)) WHERE effective_to IS NULL;
    SQL

    create_table :prime_statut_rewards do |t|
      t.bigint   :member_id, null: false
      t.string   :period, null: false                 # 'YYYY-MM'
      t.integer  :niveau, null: false
      t.decimal  :assiette,        precision: 18, scale: 6, null: false  # B_i (commission du membre)
      t.decimal  :majoration_rate, precision: 12, scale: 9, null: false  # m_l (fraction)
      t.decimal  :prime,           precision: 18, scale: 6, null: false  # m_l * B_i
      t.references :prime_statut_config, foreign_key: true
      t.timestamps
    end
    add_index :prime_statut_rewards, %i[member_id period], unique: true

    create_table :prime_statut_reserves do |t|
      t.string   :period, null: false
      t.decimal  :opening,     precision: 18, scale: 6, null: false, default: 0
      t.decimal  :distributed, precision: 18, scale: 6, null: false, default: 0
      t.decimal  :closing,     precision: 18, scale: 6, null: false, default: 0
      t.timestamps
    end
    add_index :prime_statut_reserves, :period, unique: true

    # Nouveau type de mouvement au relevé : la prime de statut créditée.
    remove_check_constraint :wallet_statements, name: "statement_kind_check"
    add_check_constraint :wallet_statements,
                         "kind IN ('personal_earn','sponsorship_earn','burn','reversal_earn'," \
                         "'reversal_burn','expiration','campaign_cashback','prime_statut')",
                         name: "statement_kind_check"

    # La prime de statut est aussi un earn (lot dans le portefeuille).
    remove_check_constraint :earn_ledgers, name: "earn_type_check"
    add_check_constraint :earn_ledgers,
                         "earn_type IN ('personal','sponsorship','comportemental','adjustment','prime_statut')",
                         name: "earn_type_check"
  end
end
