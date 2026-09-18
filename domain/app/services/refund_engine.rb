# frozen_string_literal: true

require "bigdecimal"
require "openssl"
require "json"

# Moteur de REMBOURSEMENT R1–R6 (modèle de règlement, jamais de blocage).
#   * calcule le règlement (RefundMath) : récupérable, repris, montant à déduire,
#     montant net à rembourser sur carte ;
#   * reprend aux portefeuilles (acheteur ; parrains selon le mode global R4, au
#     prorata strict R4-bis) en traçant `repris` sur les lots (R6) ;
#   * reprend les cagnottes plateforme de la (fraction de) commande (lien B2) ;
#   * prépare le payload signé HMAC pour le webhook marchand (R5) ;
#   * total ou PARTIEL via `ratio` (R3).
# Idempotence : un remboursement par commande (index sur refunds.order_id géré au
# niveau applicatif ; total = ratio 1).
class RefundEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :order_id, :settlement, :refund, keyword_init: true)

  def self.call(order_id:, ratio: BigDecimal("1"), sponsor_mode: nil)
    new(order_id, ratio, sponsor_mode).call
  end

  def initialize(order_id, ratio, sponsor_mode)
    @order_id = order_id.to_i
    @ratio    = BigDecimal(ratio.to_s)
    @rcfg     = RewardConfig.current!
    @mode     = (sponsor_mode || @rcfg.sponsor_refund_mode).to_sym
  end

  def call
    earns = EarnLedger.where(order_id: @order_id).order(:id).to_a
    buyer_earn = earns.find { |e| e.earn_type == "personal" }
    return Result.new(status: :not_found) if buyer_earn.nil?

    sponsor_earns = earns.select { |e| e.earn_type == "sponsorship" }
    order_amount  = BigDecimal((buyer_earn.order_amount || 0).to_s)

    ActiveRecord::Base.transaction do
      buyer_lot = WalletLot.lock.find_by(earn_id: buyer_earn.id)
      buyer = { nominal: buyer_earn.amount, remaining: recoverable_remaining(buyer_lot) }
      sp = sponsor_earns.map { |e| [e, WalletLot.lock.find_by(earn_id: e.id)] }
      sponsors = sp.map { |_e, l| { nominal: _e.amount, remaining: recoverable_remaining(l) } }

      s = RefundMath.settle(order_amount: order_amount, buyer: buyer, sponsors: sponsors,
                            ratio: @ratio, sponsor_mode: @mode)

      apply_clawback!(buyer_earn, buyer_lot, s[:recoverable_buyer], sponsorship: false)
      if @mode == :clawback
        sp.each do |e, l|
          recov = [round6(e.amount * @ratio), recoverable_remaining(l)].min
          apply_clawback!(e, l, recov, sponsorship: true)
        end
      end

      compensate_pools!

      wh = MerchantWebhook.find_by(merchant_id: buyer_earn.merchant_id, active: true)
      payload = build_payload(order_amount, s)
      refund = Refund.create!(
        order_id: @order_id, ratio: @ratio, sponsor_mode: @mode.to_s,
        repris_total: s[:repris_total], card_deduction: s[:card_deduction],
        card_deduction_buyer: s[:card_deduction_buyer],
        card_deduction_sponsors: s[:card_deduction_sponsors], card_refund: s[:card_refund],
        webhook_payload: signed_payload(payload, wh),
        webhook_status: wh ? "ready" : "no_endpoint"
      )
      @settlement = s
      @refund = refund
    end

    Result.new(status: :processed, order_id: @order_id, settlement: @settlement, refund: @refund)
  end

  private

  # Un lot actif OU en attente peut être repris ; sinon rien de récupérable.
  def recoverable_remaining(lot)
    return BigDecimal(0) if lot.nil?

    %w[active pending].include?(lot.status) ? lot.remaining : BigDecimal(0)
  end

  def apply_clawback!(earn, lot, amount, sponsorship:)
    return if amount <= 0 || lot.nil?

    new_remaining = round6(lot.remaining - amount)
    fully = new_remaining <= 0 && lot.remaining == lot.initial_amount
    lot.update!(remaining: [new_remaining, BigDecimal(0)].max,
                repris: round6(lot.repris + amount),
                status: fully ? "reversed" : lot.status)
    apply_movement!(member_id: earn.member_id, amount: -amount, kind: "reversal_earn",
                    label: "Remboursement — repris #{format('%.2f', amount)} €",
                    order_id: @order_id, generation: sponsorship ? earn.generation : nil,
                    counter: sponsorship ? :sponsorship_counter : :personal_counter)
  end

  # Reprise des cagnottes plateforme au prorata du ratio (lien B2). Comportemental
  # épargné si le batch mensuel l'a déjà consommé.
  def compensate_pools!
    PoolContribution.where(order_id: @order_id).where("amount > 0").find_each do |orig|
      if orig.pool_type == "comportemental"
        period = orig.occurred_at.strftime("%Y-%m")
        next if MemberMonthlyReward.exists?(member_id: orig.source_member_id, period: period)
      end
      amount = round6(-orig.amount * @ratio)
      next if amount.zero?

      PoolContribution.create!(pool_type: orig.pool_type, order_id: @order_id,
                               source_member_id: orig.source_member_id,
                               amount: amount, occurred_at: orig.occurred_at)
    end
  end

  def build_payload(order_amount, s)
    { order_id: @order_id, order_amount: order_amount.to_s, ratio: @ratio.to_s,
      sponsor_mode: @mode.to_s, card_refund: s[:card_refund].to_s,
      deduction: { total: s[:card_deduction].to_s, buyer: s[:card_deduction_buyer].to_s,
                   sponsors: s[:card_deduction_sponsors].to_s } }
  end

  def signed_payload(payload, webhook)
    body = payload.to_json
    sig  = webhook ? OpenSSL::HMAC.hexdigest("SHA256", webhook.secret, body) : nil
    payload.merge(signature: sig)
  end
end
