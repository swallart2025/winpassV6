# frozen_string_literal: true

# V5 — Correctifs cagnottes (B2/B4/B6). Migration ADDITIVE.
#
#   * `occurred_at` (date métier = date d'achat) sur pool_contributions : le batch
#     mensuel doit regrouper sur cette date, pas sur `created_at` (date d'insertion,
#     = aujourd'hui pour un achat antidaté). Corrige B4.
#   * Montants SIGNÉS : l'annulation crée des contributions compensatoires NÉGATIVES
#     (immuabilité préservée) pour reprendre la part plateforme d'une commande
#     annulée. Corrige B2 (et B6, via le net du potentiel comportemental).
class V5PoolSignedAndBusinessDate < ActiveRecord::Migration[7.2]
  def up
    add_column :pool_contributions, :occurred_at, :datetime

    # Backfill : date métier des lignes existantes = date de livraison de leur
    # commande (earn_ledgers), à défaut la date d'insertion.
    execute <<~SQL
      UPDATE pool_contributions pc
      SET occurred_at = COALESCE(
        (SELECT MIN(el.delivered_at) FROM earn_ledgers el WHERE el.order_id = pc.order_id),
        pc.created_at)
      WHERE pc.occurred_at IS NULL;
    SQL
    change_column_null :pool_contributions, :occurred_at, false

    # Autoriser les montants négatifs (compensations d'annulation).
    remove_check_constraint :pool_contributions, name: "pool_amount_positive"
    add_check_constraint :pool_contributions, "amount <> 0", name: "pool_amount_nonzero"

    add_index :pool_contributions, %i[pool_type source_member_id occurred_at],
              name: "idx_pool_type_member_occurred"
  end

  def down
    remove_index :pool_contributions, name: "idx_pool_type_member_occurred"
    remove_check_constraint :pool_contributions, name: "pool_amount_nonzero"
    add_check_constraint :pool_contributions, "amount > 0", name: "pool_amount_positive"
    remove_column :pool_contributions, :occurred_at
  end
end
