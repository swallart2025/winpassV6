# frozen_string_literal: true

require "bigdecimal"

# Distribution TRIMESTRIELLE des primes de rang Bâtisseurs + accumulation RFA.
#
# Pour chaque achat du trimestre : B = commission ; remontée des parrains actifs
# (SponsorshipTree, réutilisé) ; poids géométriques renormalisés (DistributionTable,
# réutilisé) ; prime de chaque leader = taux_rang × w_d(g) × B (PrimeRangMath).
# On cumule par leader (assiette géométrique + prime), on crédite en fin de
# trimestre, et le résidu (poche 7,5 % − distribué) alimente le pot RFA de l'année.
#
# V5.1 — GARDE-FOU RÉEL : le trimestre est marqué traité par une ligne UNIQUE
# `builder_prime_runs` (qu'une prime soit versée ou non). Un reclic renvoie donc
# `already_run` et NE ré-ajoute PLUS la poche au pot RFA. Fin du « pot infini ».
class BuilderPrimeEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :period, :processed, :pocket, :distributed, :rfa,
                      :lines, keyword_init: true)

  def self.call(period:)
    new(period).call
  end

  def initialize(period)
    @period = period # 'YYYY-Qn'
    @rcfg   = RewardConfig.current!
    @dist   = DistributionTable.new(@rcfg)
    @tree   = SponsorshipTree.new(@rcfg)
  end

  def call
    # V5.1 : idempotence par MARQUEUR de trimestre, indépendante de tout versement.
    return already_run if BuilderPrimeRun.exists?(period: @period)

    from, to, year = quarter_range(@period)
    pocket_rate = @rcfg.grands_leaders_rate.to_d
    acc = Hash.new { |h, k| h[k] = { assiette: BigDecimal(0), prime: BigDecimal(0), rang: 0 } }
    pocket_total = BigDecimal(0)

    EarnLedger.where(earn_type: "personal")
              .where("delivered_at >= ? AND delivered_at <= ?", from, to)
              .where("order_amount IS NOT NULL").find_each do |earn|
      base = (BigDecimal(earn.order_amount.to_s) * BigDecimal(earn.commission_rate.to_s))
      pocket_total += (base * pocket_rate)
      upline = @tree.active_upline(earn.member_id, earn.delivered_at)
      next if upline.empty?

      weights = @rcfg.distribution_for(upline.size)
      links = upline.each_with_index.map do |lnk, i|
        { generation: i + 1, rang: rang_of(lnk.sponsor_member_id), member_id: lnk.sponsor_member_id }
      end
      res = PrimeRangMath.majorations(
        upline: links.map { |l| { generation: l[:generation], rang: l[:rang] } },
        weights: weights, base: base
      )
      links.each do |l|
        acc[l[:member_id]][:assiette] += (weights.fetch(l[:generation]) * base)
        acc[l[:member_id]][:prime]    += res[:majorations][l[:generation]]
        acc[l[:member_id]][:rang]      = l[:rang]
      end
    end

    distributed = BigDecimal(0)
    lines = []
    ActiveRecord::Base.transaction do
      acc.sort_by { |mid, _| mid }.each do |mid, d|
        next if d[:prime] <= 0

        credit!(mid, d[:prime], "Prime de rang #{@period}")
        BuilderPrimeReward.create!(member_id: mid, period: @period, rang: d[:rang],
                                   assiette: d[:assiette], prime: d[:prime])
        distributed += d[:prime]
        lines << { member_id: mid, rang: d[:rang], rang_nom: PrimeRangMath.nom(d[:rang]),
                   assiette: d[:assiette], prime: d[:prime] }
      end

      # Poche du trimestre ajoutée au pot annuel EXACTEMENT UNE FOIS (marqueur).
      BuilderPrimeRun.create!(period: @period, year: year,
                              pocket_added: pocket_total, distributed: distributed)
      res = BuilderReserve.find_or_create_by!(year: year)
      new_pocket = res.pocket_total + pocket_total
      new_distr  = res.distributed_total + distributed
      res.update!(pocket_total: new_pocket, distributed_total: new_distr,
                  rfa_total: new_pocket - new_distr)
      @pocket = pocket_total
      @distributed = distributed
      @rfa = res.rfa_total
    end

    Result.new(status: :processed, period: @period, processed: lines.size,
               pocket: @pocket, distributed: @distributed, rfa: @rfa, lines: lines)
  rescue ActiveRecord::RecordNotUnique
    Result.new(status: :duplicate, period: @period)
  end

  private

  def rang_of(mid) = BuilderStatus.where(member_id: mid).pick(:rang) || 0

  def already_run
    res = BuilderReserve.order(:year).last
    Result.new(status: :already_run, period: @period, processed: 0,
               pocket: BigDecimal(0), distributed: BigDecimal(0),
               rfa: res&.rfa_total || BigDecimal(0), lines: [])
  end

  def credit!(member_id, amount, label)
    at = Time.current
    earn = EarnLedger.create!(member_id: member_id, earn_type: "prime_rang", generation: 0,
                              amount: amount, reward_config_id: @rcfg.id, merchant_id: label,
                              delivered_at: at, expires_at: at + @rcfg.expiration_months.months)
    WalletLot.create!(earn: earn, member_id: member_id, unit: "EUR", initial_amount: amount,
                      remaining: amount, earned_at: at, expires_at: earn.expires_at)
    apply_movement!(member_id: member_id, amount: amount, kind: "prime_rang",
                    label: label, order_id: nil, merchant_id: label, counter: :sponsorship_counter)
  end

  def quarter_range(period)
    y, q = period.split("-Q").map(&:to_i)
    m0 = ((q - 1) * 3) + 1
    from = Time.zone.local(y, m0, 1)
    to   = Time.zone.local(y, m0 + 2, 1).end_of_month
    [from, to, y]
  end
end
