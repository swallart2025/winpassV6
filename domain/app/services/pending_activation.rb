# frozen_string_literal: true

require "bigdecimal"

# Active les lots EN ATTENTE dont le délai de rétractation est écoulé : le lot
# passe `pending` -> `active` et son montant devient consommable (crédité au solde
# disponible à l'activation, pas à la création). Un membre par transaction, verrouillé.
class PendingActivation
  include LoyaltyLedger

  Result = Struct.new(:status, :activated, keyword_init: true)

  def self.call(now: Time.current)
    new(now).call
  end

  def initialize(now)
    @now = now
  end

  def call
    activated = 0
    WalletLot.pending_due(@now).order(:member_id, :id).pluck(:member_id).uniq.each do |member_id|
      ActiveRecord::Base.transaction do
        Wallet.find_by!(member_id: member_id).lock!
        WalletLot.where(member_id: member_id, status: "pending")
                 .where("available_from <= ?", @now).lock("FOR UPDATE").each do |lot|
          lot.update!(status: "active")
          apply_movement!(member_id: member_id, amount: lot.remaining, kind: "personal_earn",
                          label: "Solde confirmé (fin du délai)", order_id: nil,
                          counter: :personal_counter)
          activated += 1
        end
      end
    end
    Result.new(status: :processed, activated: activated)
  end
end
