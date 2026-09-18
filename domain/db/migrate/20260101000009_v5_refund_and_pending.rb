# frozen_string_literal: true

# V5 — Remboursement (R1–R6) & solde en attente (pending). Migration ADDITIVE.
#
#   * wallet_lots.repris : montant repris par remboursement (distinct du consommé
#     par burn) -> affichage R6 « Initial · Consommé · Repris · Restant ».
#   * lot status 'pending' + available_from : le solde en attente n'est consommable
#     qu'après le délai de rétractation.
#   * reward_configs.sponsor_refund_mode : paramètre GLOBAL R4 (buyer_covers|clawback).
#   * refunds : trace du règlement (déductions, montant net carte, mode, payload webhook).
#   * merchant_webhooks : URL + secret HMAC par marchand (R5).
class V5RefundAndPending < ActiveRecord::Migration[7.2]
  def up
    add_column :wallet_lots, :repris, :decimal, precision: 18, scale: 6, null: false, default: 0
    add_column :wallet_lots, :available_from, :datetime
    add_check_constraint :wallet_lots, "repris >= 0", name: "lot_repris_non_negative"

    remove_check_constraint :wallet_lots, name: "lot_status_check"
    add_check_constraint :wallet_lots,
                         "status IN ('active','consumed','expired','reversed','pending')",
                         name: "lot_status_check"

    add_column :reward_configs, :sponsor_refund_mode, :string, null: false, default: "buyer_covers"
    add_check_constraint :reward_configs,
                         "sponsor_refund_mode IN ('buyer_covers','clawback')",
                         name: "sponsor_refund_mode_check"

    create_table :refunds do |t|
      t.bigint   :order_id, null: false
      t.decimal  :ratio, precision: 6, scale: 5, null: false, default: "1.0"
      t.string   :sponsor_mode, null: false
      t.decimal  :repris_total,            precision: 18, scale: 6, null: false, default: 0
      t.decimal  :card_deduction,          precision: 18, scale: 6, null: false, default: 0
      t.decimal  :card_deduction_buyer,    precision: 18, scale: 6, null: false, default: 0
      t.decimal  :card_deduction_sponsors, precision: 18, scale: 6, null: false, default: 0
      t.decimal  :card_refund,             precision: 18, scale: 6, null: false, default: 0
      t.jsonb    :webhook_payload
      t.string   :webhook_status, null: false, default: "pending"
      t.timestamps
    end
    add_index :refunds, :order_id

    create_table :merchant_webhooks do |t|
      t.string  :merchant_id, null: false
      t.string  :url, null: false
      t.string  :secret, null: false
      t.boolean :active, null: false, default: true
      t.timestamps
    end
    add_index :merchant_webhooks, :merchant_id, unique: true
  end

  def down
    drop_table :merchant_webhooks
    drop_table :refunds
    remove_check_constraint :reward_configs, name: "sponsor_refund_mode_check"
    remove_column :reward_configs, :sponsor_refund_mode
    remove_check_constraint :wallet_lots, name: "lot_status_check"
    add_check_constraint :wallet_lots,
                         "status IN ('active','consumed','expired','reversed')", name: "lot_status_check"
    remove_check_constraint :wallet_lots, name: "lot_repris_non_negative"
    remove_column :wallet_lots, :available_from
    remove_column :wallet_lots, :repris
  end
end
