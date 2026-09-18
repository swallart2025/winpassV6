# frozen_string_literal: true

require "bigdecimal"

# PURGE de la Prime de Statut d'une période — « point barre » (V5.1).
# Remet la période à zéro : reverse les primes encore présentes (au plus le solde
# restant du lot -> jamais de négatif), supprime les photos (récompenses) et la
# ligne de réserve de la période. Après purge, le mois est vierge et rejouable.
class PrimeStatutRollback
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :reset_count, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    unless PrimeStatutReward.where(period: @period).exists? ||
           PrimeStatutReserve.where(period: @period).exists?
      return Result.new(status: :nothing_to_purge, period: @period, reset_count: 0)
    end

    ActiveRecord::Base.transaction do
      n = 0
      PrimeStatutReward.where(period: @period).order(:member_id).each do |r|
        reverse!(r.member_id)
        n += 1
      end
      PrimeStatutReward.where(period: @period).delete_all
      PrimeStatutReserve.where(period: @period).delete_all
      Result.new(status: :processed, period: @period, reset_count: n)
    end
  end

  private

  def prime_lot(member_id)
    earn = EarnLedger.where(member_id: member_id, earn_type: "prime_statut",
                            merchant_id: "Prime de Statut #{@period}").order(id: :desc).first
    earn && WalletLot.find_by(earn_id: earn.id)
  end

  def reverse!(member_id)
    lot = prime_lot(member_id)
    return unless lot && lot.status == "active" && lot.remaining.positive?

    apply_movement!(member_id: member_id, amount: -lot.remaining, kind: "reversal_earn",
                    label: "Purge Prime de Statut #{@period}", order_id: nil,
                    merchant_id: "Prime de Statut #{@period}", counter: :personal_counter)
    lot.update!(remaining: 0, status: "reversed")
  end
end
