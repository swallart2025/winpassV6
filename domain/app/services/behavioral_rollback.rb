# frozen_string_literal: true

require "bigdecimal"

# PURGE du batch mensuel comportemental — « point barre » (V5.1).
#
# Rôle unique : REMETTRE LA PÉRIODE À ZÉRO pour pouvoir la rejouer au banc d'essai.
# Elle ne « rejoue » rien. Pour chaque récompense mensuelle de la période :
#   * on reverse le crédit encore présent (au plus le solde restant du lot -> jamais
#     de solde négatif ; la contrainte base l'interdit de toute façon), le lot passe
#     « reversed » ;
#   * on annule la contribution CIC du mois ;
#   * on supprime la photo mensuelle (et les photos de catégories).
# Après une purge, le mois est VIERGE : le batch peut être relancé.
#
# Immuabilité préservée : on n'efface aucun journal comptable (earn/relevé/CIC) ;
# on ajoute des écritures compensatoires. Seules les PROJECTIONS mensuelles (photos)
# sont supprimées.
class BehavioralRollback
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :rolled_back, :kept, :cic_after, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
  end

  def call
    unless MemberMonthlyReward.where(period: @period).exists?
      return Result.new(status: :nothing_to_purge, period: @period,
                        rolled_back: [], kept: [], cic_after: CicLedger.balance)
    end

    ActiveRecord::Base.transaction do
      reset = []
      MemberMonthlyReward.where(period: @period).order(:member_id).each do |mr|
        reverse_member!(mr)
        reset << mr.member_id
      end
      # Remise à zéro TOTALE des projections de la période.
      MemberMonthlyReward.where(period: @period).delete_all
      MemberMonthlyCategoryScore.where(period: @period).delete_all
      Result.new(status: :processed, period: @period, rolled_back: reset, kept: [],
                 cic_after: CicLedger.balance)
    end
  end

  private

  def reward_lot(member_id)
    earn = EarnLedger.where(member_id: member_id, earn_type: "comportemental",
                            merchant_id: "Comportemental #{@period}").order(id: :desc).first
    earn && WalletLot.find_by(earn_id: earn.id)
  end

  def reverse_member!(mr)
    lot = reward_lot(mr.member_id)
    if lot && lot.status == "active" && lot.remaining.positive?
      apply_movement!(member_id: mr.member_id, amount: -lot.remaining, kind: "reversal_earn",
                      label: "Purge comportemental #{@period}", order_id: nil,
                      merchant_id: "Comportemental #{@period}", counter: :personal_counter)
      lot.update!(remaining: 0, status: "reversed")
    end
    return unless mr.cic_contribution.positive?

    CicLedger.move!(kind: "monthly_contribution", amount: -mr.cic_contribution,
                    reference: { purge: @period, member_id: mr.member_id })
  end
end
