# frozen_string_literal: true

# V5 — Bascule du budget vers le modèle Prime de Statut.
#   * `prime_statut_rate` (défaut 0) sur reward_configs : la poche de 5 % collectée
#     à l'achat, distribuée mensuellement par niveau (moteur Prime de Statut).
#   * Nouveau pool_type 'prime_statut' sur pool_contributions.
# Le socle personnel passe de 45 % à 40 % via une NOUVELLE version de config
# (V5-2026), les earns V4 restant rattachés à V1-2026 (rejouabilité préservée).
class V5PrimeStatutRateAndPool < ActiveRecord::Migration[7.2]
  def up
    add_column :reward_configs, :prime_statut_rate, :decimal, precision: 6, scale: 5, null: false, default: 0

    remove_check_constraint :pool_contributions, name: "pool_type_check"
    add_check_constraint :pool_contributions,
                         "pool_type IN ('fonctionnement','grands_leaders','comportemental','prime_statut')",
                         name: "pool_type_check"
  end

  def down
    remove_check_constraint :pool_contributions, name: "pool_type_check"
    add_check_constraint :pool_contributions,
                         "pool_type IN ('fonctionnement','grands_leaders','comportemental')",
                         name: "pool_type_check"
    remove_column :reward_configs, :prime_statut_rate
  end
end
