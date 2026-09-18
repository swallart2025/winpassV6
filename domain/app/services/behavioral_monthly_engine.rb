# frozen_string_literal: true

require "bigdecimal"

# Batch mensuel comportemental. Pour chaque membre, sur la période :
#   * potentiel = 15 % du budget de commission cumulé sur le mois
#     (SUM des contributions `comportemental` de `pool_contributions`) ;
#   * score d'adhésion à la date d'arrêté (décroissance + rechargement) ;
#   * taux débloqué = barème d'adhésion en vigueur ;
#   * récompense = potentiel × taux ; créditée au portefeuille ;
#   * reliquat (potentiel − récompense) versé à la CIC.
# Écrit les photos mensuelles immuables. Idempotent (clé + unicité membre/période).
class BehavioralMonthlyEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :processed, :cic_after, :lines, keyword_init: true)

  def self.call(period:, as_of: nil)
    new(period, as_of).call
  end

  def initialize(period, as_of)
    @period    = period # 'YYYY-MM'
    # B3 : une date de calcul fournie est traitée comme la JOURNÉE ENTIÈRE.
    @as_of     = if as_of.blank? then end_of_period
                 elsif as_of.is_a?(String) then Time.zone.parse(as_of).end_of_day
                 else as_of
                 end
    @scorer = BehavioralScore.new
    @scale  = AdherenceScaleConfig.current!
    @config = RewardConfig.current!
  end

  def call
    # B5 : idempotence PAR ÉTAT. Si le mois a déjà des photos, on ne rejoue pas
    # (il faut purger d'abord). Pas de clé horodatée -> plus de multi-exécution.
    return Result.new(status: :already_run, period: @period, processed: 0,
                      cic_after: CicLedger.balance, lines: []) if MemberMonthlyReward.where(period: @period).exists?

    ActiveRecord::Base.transaction do
      lines = []
      Membership.order(:member_id).pluck(:member_id).each do |member_id|
        potential = monthly_potential(member_id)
        next if potential <= 0
        next if MemberMonthlyReward.exists?(member_id: member_id, period: @period)

        score  = @scorer.score(member_id, @as_of)
        rate   = @scale.rate_for(score)
        reward = (potential * rate / 100).round(6, BigDecimal::ROUND_HALF_UP)
        to_cic = (potential - reward).round(6, BigDecimal::ROUND_HALF_UP)

        credit_reward!(member_id, reward) if reward.positive?
        MemberMonthlyReward.create!(member_id: member_id, period: @period, potential: potential,
                                    score: score, unlocked_rate: rate, reward: reward,
                                    cic_contribution: to_cic, reward_config_id: @config.id)
        snapshot_categories!(member_id)
        CicLedger.move!(kind: "monthly_contribution", amount: to_cic,
                        reference: { member_id: member_id, period: @period }) if to_cic.positive?

        lines << { member_id: member_id, potential: potential, score: score,
                   unlocked_rate: rate, reward: reward, cic_contribution: to_cic }
      end
      Result.new(status: :processed, period: @period, processed: lines.size,
                 cic_after: CicLedger.balance, lines: lines)
    end
  rescue ActiveRecord::RecordNotUnique
    # Course concurrente : l'unicité (member_id, period) a bloqué le 2e passage.
    Result.new(status: :duplicate)
  end

  private

  # SUM des contributions comportementales du mois (15 % du budget par achat).
  # B4 : filtre sur la DATE D'ACHAT réelle (`occurred_at`), pas sur `created_at`
  # (= date d'insertion). Les contributions compensatoires négatives d'une commande
  # annulée (B2) portent le même `occurred_at` et se déduisent donc du bon mois (B6).
  def monthly_potential(member_id)
    PoolContribution.where(pool_type: "comportemental", source_member_id: member_id)
                    .where("to_char(occurred_at, 'YYYY-MM') = ?", @period)
                    .sum(:amount)
  end

  def credit_reward!(member_id, reward)
    # Origine synthétique lisible (bug #7) : `merchant_id` = "Comportemental YYYY-MM".
    # earn_type reste "comportemental" -> exclu du calcul du score (qui ne compte
    # que les achats "personal"), donc aucune pollution du moteur d'adhésion.
    origin = "Comportemental #{@period}"
    earn = EarnLedger.create!(member_id: member_id, earn_type: "comportemental", generation: 0,
                              amount: reward, reward_config_id: @config.id, merchant_id: origin,
                              delivered_at: @as_of, expires_at: @as_of + @config.expiration_months.months)
    WalletLot.create!(earn: earn, member_id: member_id, unit: "EUR", initial_amount: reward,
                      remaining: reward, earned_at: @as_of, expires_at: earn.expires_at)
    apply_movement!(member_id: member_id, amount: reward, kind: "personal_earn",
                    label: "Récompense comportementale #{@period}", order_id: nil,
                    merchant_id: origin, counter: :personal_counter)
  end

  def snapshot_categories!(member_id)
    @scorer.categories.each do |category|
      state = @scorer.category_contribution(member_id, category, @as_of)
      next if state[:contribution].zero? && state[:last_recharge_at].nil?

      MemberMonthlyCategoryScore.create!(member_id: member_id, period: @period, category: category,
                                         cumulative_amount: state[:cumulative], contribution: state[:contribution],
                                         last_recharge_at: state[:last_recharge_at])
    end
  end

  def end_of_period
    year, month = @period.split("-").map(&:to_i)
    Time.zone.local(year, month, 1).end_of_month
  end
end
