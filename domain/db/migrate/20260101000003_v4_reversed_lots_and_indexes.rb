# frozen_string_literal: true

# V4 — Correctifs & performance. Migration ADDITIVE (le cœur reste dans 0001/0002).
#
#   * Statut de lot « reversed » : un lot dont l'earn a été annulé est neutralisé
#     (remaining = 0) mais CONSERVÉ pour l'audit, et n'est plus consommable en FEFO.
#     C'est le correctif du bug #1 (les lots restaient actifs après annulation).
#   * Index ciblés sur les requêtes chaudes (score comportemental, potentiel
#     mensuel, soldes des cagnottes) — justifiés par EXPLAIN dans le rapport perf.
class V4ReversedLotsAndIndexes < ActiveRecord::Migration[7.2]
  def change
    # --- Bug #1 : statut « reversed » sur les lots -----------------------------
    remove_check_constraint :wallet_lots, name: "lot_status_check"
    add_check_constraint :wallet_lots,
                         "status IN ('active','consumed','expired','reversed')",
                         name: "lot_status_check"

    # --- Index pour le score comportemental ------------------------------------
    # BehavioralScore#personal_purchases : filtre (member_id, earn_type, delivered_at)
    # puis joint merchant_categories. Sans cet index, balayage séquentiel de earn_ledgers.
    add_index :earn_ledgers, %i[member_id earn_type delivered_at],
              name: "idx_earn_member_type_delivered"

    # --- Index pour le potentiel mensuel & les soldes de cagnottes -------------
    # BehavioralMonthlyEngine#monthly_potential et le panneau « Cagnottes » filtrent
    # pool_contributions par (source_member_id, pool_type) / (pool_type).
    add_index :pool_contributions, %i[pool_type source_member_id],
              name: "idx_pool_type_member"
  end
end
