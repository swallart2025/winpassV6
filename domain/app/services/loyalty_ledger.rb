# frozen_string_literal: true

require "bigdecimal"

# Briques comptables partagées par les moteurs (Purchase, Reversal) :
#   * arithmétique monétaire en BigDecimal, arrondi conservatif à 6 décimales ;
#   * application d'un mouvement SIGNÉ sur un portefeuille : verrou de ligne
#     (SELECT ... FOR UPDATE) -> mise à jour du solde -> écriture d'une ligne de
#     relevé immuable. C'est le seul chemin par lequel un solde bouge.
module LoyaltyLedger
  SCALE = 6

  private

  def money(value)
    BigDecimal(value.to_s)
  end

  def round6(value)
    value.round(SCALE, BigDecimal::ROUND_HALF_UP)
  end

  # Applique un montant signé (crédit > 0, débit < 0) et journalise.
  # @return [BigDecimal] le nouveau solde après mouvement.
  def apply_movement!(member_id:, amount:, kind:, label:, order_id:, merchant_id: nil,
                      generation: nil, counterparty_member_id: nil, counter: nil)
    wallet = Wallet.find_by!(member_id: member_id).lock! # sérialise les écritures du membre
    before = wallet.available_balance
    after  = round6(before + amount)
    attrs  = { available_balance: after, updated_at: Time.current }
    attrs[counter] = round6(wallet.public_send(counter) + amount) if counter
    wallet.update!(attrs)

    WalletStatement.create!(
      member_id: member_id, kind: kind, label: label, generation: generation,
      order_id: order_id, merchant_id: merchant_id,
      counterparty_member_id: counterparty_member_id,
      amount: round6(amount), balance_after: after
    )
    after
  end

  # Enrôlement implicite, résistant aux courses : un doublon concurrent lève
  # RecordNotUnique -> on relit.
  def ensure_membership!(member_id)
    Membership.find_or_create_by!(member_id: member_id)
    Wallet.find_or_create_by!(member_id: member_id)
  rescue ActiveRecord::RecordNotUnique
    retry
  end
end
