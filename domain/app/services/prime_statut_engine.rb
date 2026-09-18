# frozen_string_literal: true

require "bigdecimal"

# Moteur Prime de performance collective de Statut — batch de période.
#
#   * Assiette d'un membre : B_i = (poche prime_statut nette du mois) ÷ poche_rate.
#     La poche prime_statut par achat = poche_rate × commission → B_i = commission
#     nette du membre sur la période. Les compensations d'annulation (B2, négatives)
#     et l'antidatage (occurred_at) sont donc déjà pris en compte.
#   * Assiette par niveau : B_l = Σ B_i des membres du niveau tenu.
#   * Calcul pur (p déduit, projection grille, plafond, réserve) : PrimeStatutMath.
#   * Prime individuelle : m_niveau × B_i, créditée au portefeuille (earn prime_statut).
#   * Reliquat → réserve, reportée à la période suivante.
#
# Idempotent PAR ÉTAT : si des photos existent pour la période, no-op (`already_run`).
class PrimeStatutEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :processed, :p, :poche, :distributed,
                      :reserve_closing, :lines, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period
    @cfg    = PrimeStatutConfig.current!
    @rcfg   = RewardConfig.current!
  end

  def call
    return already_run if PrimeStatutReward.where(period: @period).exists?

    poche_rate = @rcfg.prime_statut_rate.to_d
    sums = PoolContribution.where(pool_type: "prime_statut")
                           .where("to_char(occurred_at, 'YYYY-MM') = ?", @period)
                           .group(:source_member_id).sum(:amount)
    members = sums.filter_map { |mid, s| { member_id: mid, s: s } if s.positive? }
    return Result.new(status: :empty, period: @period, processed: 0) if members.empty?

    statuses = MemberStatus.where(member_id: members.map { |m| m[:member_id] })
                           .pluck(:member_id, :niveau_tenu).to_h
    n = @cfg.niveaux
    b_l = Array.new(n + 1, BigDecimal(0))
    members.each do |m|
      m[:niveau] = statuses[m[:member_id]] || 1
      m[:b_i]    = (m[:s] / poche_rate)
      b_l[m[:niveau]] += m[:b_i]
    end

    reserve_in = last_reserve_closing
    res = PrimeStatutMath.solve(b_l: b_l, poche_rate: poche_rate,
                                pas: @cfg.pas.to_d, plafond: @cfg.plafond.to_d, reserve_in: reserve_in)

    poche = (b_l.sum { |x| x } * poche_rate)
    lines = []
    ActiveRecord::Base.transaction do
      members.sort_by { |m| m[:member_id] }.each do |m|
        m_l   = res[:majorations][m[:niveau]]
        prime = (m_l * m[:b_i]).round(6, BigDecimal::ROUND_HALF_UP)
        credit_prime!(m[:member_id], prime) if prime.positive?
        PrimeStatutReward.create!(member_id: m[:member_id], period: @period, niveau: m[:niveau],
                                  assiette: m[:b_i], majoration_rate: m_l, prime: prime,
                                  prime_statut_config_id: @cfg.id)
        lines << { member_id: m[:member_id], niveau: m[:niveau], assiette: m[:b_i],
                   majoration: m_l, prime: prime }
      end
      distributed = lines.sum { |l| l[:prime] }
      closing     = (poche + reserve_in - distributed)
      PrimeStatutReserve.create!(period: @period, opening: reserve_in,
                                 distributed: distributed, closing: closing)
      @distributed = distributed
      @closing = closing
    end

    Result.new(status: :processed, period: @period, processed: lines.size, p: res[:p],
               poche: poche, distributed: @distributed, reserve_closing: @closing, lines: lines)
  rescue ActiveRecord::RecordNotUnique
    Result.new(status: :duplicate, period: @period)
  end

  private

  def already_run
    Result.new(status: :already_run, period: @period, processed: 0,
               poche: BigDecimal(0), distributed: BigDecimal(0),
               reserve_closing: last_reserve_closing, lines: [])
  end

  def last_reserve_closing
    PrimeStatutReserve.where("period < ?", @period).order(:period).last&.closing || BigDecimal(0)
  end

  def credit_prime!(member_id, amount)
    origin = "Prime de Statut #{@period}"
    at = end_of_period
    earn = EarnLedger.create!(member_id: member_id, earn_type: "prime_statut", generation: 0,
                              amount: amount, reward_config_id: @rcfg.id, merchant_id: origin,
                              delivered_at: at, expires_at: at + @rcfg.expiration_months.months)
    WalletLot.create!(earn: earn, member_id: member_id, unit: "EUR", initial_amount: amount,
                      remaining: amount, earned_at: at, expires_at: earn.expires_at)
    apply_movement!(member_id: member_id, amount: amount, kind: "prime_statut",
                    label: origin, order_id: nil, merchant_id: origin, counter: :personal_counter)
  end

  def end_of_period
    year, month = @period.split("-").map(&:to_i)
    Time.zone.local(year, month, 1).end_of_month
  end
end
