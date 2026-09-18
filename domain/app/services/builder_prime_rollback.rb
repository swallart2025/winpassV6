# frozen_string_literal: true

require "bigdecimal"

# PURGE de la distribution trimestrielle des primes de rang — « point barre » (V5.1).
# Remet le trimestre à zéro : reverse les primes encore présentes (au plus le solde
# restant du lot), RETIRE du pot RFA la poche et le distribué de CE trimestre (via le
# marqueur `builder_prime_runs`), supprime les récompenses et le marqueur. Après purge,
# le trimestre peut être redistribué sans double compte ni pot qui gonfle.
class BuilderPrimeRollback
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :reset_count, :rfa, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    run = BuilderPrimeRun.find_by(period: @period)
    unless run || BuilderPrimeReward.where(period: @period).exists?
      return Result.new(status: :nothing_to_purge, period: @period, reset_count: 0, rfa: BigDecimal(0))
    end

    ActiveRecord::Base.transaction do
      n = 0
      BuilderPrimeReward.where(period: @period).order(:member_id).each do |r|
        reverse!(r.member_id)
        n += 1
      end

      rfa = BigDecimal(0)
      if run
        res = BuilderReserve.find_by(year: run.year)
        if res
          np = [res.pocket_total - run.pocket_added, BigDecimal(0)].max
          nd = [res.distributed_total - run.distributed, BigDecimal(0)].max
          res.update!(pocket_total: np, distributed_total: nd, rfa_total: np - nd)
          rfa = res.rfa_total
        end
        run.destroy!
      end
      BuilderPrimeReward.where(period: @period).delete_all
      Result.new(status: :processed, period: @period, reset_count: n, rfa: rfa)
    end
  end

  private

  def prime_lot(member_id)
    earn = EarnLedger.where(member_id: member_id, earn_type: "prime_rang",
                            merchant_id: "Prime de rang #{@period}").order(id: :desc).first
    earn && WalletLot.find_by(earn_id: earn.id)
  end

  def reverse!(member_id)
    lot = prime_lot(member_id)
    return unless lot && lot.status == "active" && lot.remaining.positive?

    apply_movement!(member_id: member_id, amount: -lot.remaining, kind: "reversal_earn",
                    label: "Purge prime de rang #{@period}", order_id: nil,
                    merchant_id: "Prime de rang #{@period}", counter: :sponsorship_counter)
    lot.update!(remaining: 0, status: "reversed")
  end
end
