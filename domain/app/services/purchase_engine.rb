# frozen_string_literal: true

require "bigdecimal"

# Moteur d'ACHAT — transforme la livraison d'une commande en écritures de
# fidélité. Un achat génère TOUJOURS de l'earn (Personnel + remontée Parrainage) ;
# s'il est réglé en partie en points (`points_redeemed` > 0), il génère AUSSI un
# burn (consommation FEFO des lots), pour la fraction payée en points.
#
# Garanties (identiques au cœur Earn) :
#   * Idempotence : clé d'événement insérée dans `processed_events`, unicité EN
#     BASE. Rejeu ou double appel concurrent -> un seul traitement, l'autre
#     renvoie :duplicate (ActiveRecord::RecordNotUnique).
#   * Sérialisation : verrou de ligne sur chaque portefeuille touché (`lock!`).
#     Deux opérations différentes sur le même portefeuille s'exécutent l'une
#     derrière l'autre, sans perte de mise à jour.
#   * Atomicité : tout se joue dans UNE transaction ; en cas d'erreur, rien n'est
#     écrit (y compris le burn si l'earn échoue, et inversement).
class PurchaseEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :base, :personal, :sponsorship, :reserves,
                      :comportemental, :burn, :cashback, :balance, keyword_init: true)

  # Levée si le solde est insuffisant pour le burn demandé. Portée par le Result.
  class InsufficientBalance < StandardError
    attr_reader :balance, :needed
    def initialize(balance, needed)
      @balance = balance
      @needed = needed
      super("Solde insuffisant : #{balance} disponible, #{needed} demandé")
    end
  end

  def self.call(order:, event_key:)
    new(order, event_key).call
  end

  def initialize(order, event_key)
    @order       = order.symbolize_keys
    @event_key   = event_key
    @config      = RewardConfig.current!
    @distributor = DistributionTable.new(@config)
    @tree        = SponsorshipTree.new(@config)
  end

  def call
    buyer  = @order.fetch(:member_id).to_i
    points = money(@order[:points_redeemed] || 0)

    # --- Préparation (hors transaction) --------------------------------------
    ensure_membership!(buyer)
    upline = @tree.active_upline(buyer, delivered_at)
    upline.each { |link| ensure_membership!(link.sponsor_member_id) }

    base     = money(@order.fetch(:order_amount)) * money(@order.fetch(:commission_rate))
    personal = round6(base * @config.personal_rate)
    pool     = round6(base * @config.sponsorship_rate)
    reserves = {
      "fonctionnement" => round6(base * @config.fonctionnement_rate),
      "grands_leaders" => round6(base * @config.grands_leaders_rate),
      "comportemental" => round6(base * @config.comportemental_rate),
      # V5 : poche Prime de Statut (5 %), collectée à l'achat, distribuée
      # mensuellement par niveau (moteur Prime de Statut). 0 sous config V4.
      "prime_statut"   => round6(base * (@config.prime_statut_rate || 0))
    }
    parts = @distributor.distribute(pool, upline.size)

    # --- Exécution transactionnelle ------------------------------------------
    ActiveRecord::Base.transaction do
      claim_idempotency_key!             # 1re écriture : verrou d'idempotence en base
      Wallet.find_by!(member_id: buyer).lock! # verrou acheteur (sérialisation)

      # Éligibilité campagne évaluée AVANT que la commande ne compte dans le score.
      campaign = CampaignEngine.eligible_campaign(member_id: buyer, merchant_id: @order[:merchant_id],
                                                  at: delivered_at)

      # 1) BURN d'abord (si des points sont dépensés). On ne peut payer qu'avec
      #    des unités DÉJÀ acquises : le burn consomme le solde existant.
      burn = points.positive? ? burn!(buyer, points) : nil

      # 2) EARN sur la commande.
      create_earn!(member_id: buyer, earn_type: "personal", generation: 0,
                   amount: personal, applied_rate: @config.personal_rate)

      sponsorship = {}
      upline.each_with_index do |link, idx|
        generation = idx + 1
        create_earn!(member_id: link.sponsor_member_id, earn_type: "sponsorship",
                     generation: generation, amount: parts.fetch(generation),
                     applied_rate: @config.distribution_for(upline.size).fetch(generation),
                     member_sponsorship_id: link.member_sponsorship_id, counterparty: buyer)
        sponsorship[link.sponsor_member_id] = parts.fetch(generation)
      end

      reserves.each do |pool_type, amount|
        next unless amount.positive?

        PoolContribution.create!(pool_type: pool_type, order_id: @order[:id],
                                 source_member_id: buyer, amount: amount,
                                 occurred_at: delivered_at) # B4 : date métier (date d'achat)
      end

      # 3) CASHBACK campagne (temps réel), si le membre était éligible.
      cashback = nil
      if campaign
        cashback = CampaignEngine.award!(
          campaign: campaign, member_id: buyer, order_id: @order[:id],
          order_amount: money(@order.fetch(:order_amount)),
          credit: lambda do |member_id, amount|
            apply_movement!(member_id: member_id, amount: amount, kind: "campaign_cashback",
                            label: "Cashback campagne ##{campaign.id}", order_id: @order[:id],
                            counter: :personal_counter)
          end
        )
      end

      # V6 (Phase 1) — overlay CASHBACK : le socle 40 % alimente le cashback
      # dépensable du membre (conversion au seuil), les autres poches et le
      # parrainage reçu alimentent les compteurs globaux. Ne touche pas au cœur
      # Earn/Burn ci-dessus ; s'exécute dans la MÊME transaction (donc idempotent).
      touch_first_purchase!(buyer)
      CashbackEngine.record!(buyer: buyer, personal: personal, reserves: reserves,
                             sponsorship: sponsorship, at: delivered_at)

      mark_succeeded!
      Result.new(status: :processed, base: base, personal: personal, sponsorship: sponsorship,
                 reserves: reserves.slice("fonctionnement", "grands_leaders"),
                 comportemental: reserves["comportemental"], burn: burn, cashback: cashback,
                 balance: Wallet.find_by!(member_id: buyer).available_balance)
    end
  rescue ActiveRecord::RecordNotUnique
    Result.new(status: :duplicate)
  rescue InsufficientBalance => e
    Result.new(status: :insufficient_balance, balance: e.balance, burn: { needed: e.needed })
  end

  private

  # Consomme `amount` unités en FEFO (lots les plus tôt expirés d'abord), sous
  # verrou, et journalise le paiement + ses allocations.
  def burn!(member_id, amount)
    wallet = Wallet.find_by!(member_id: member_id) # déjà verrouillé (acheteur)
    raise InsufficientBalance.new(wallet.available_balance, amount) if wallet.available_balance < amount

    payment   = Payment.create!(member_id: member_id, order_id: @order[:id],
                                merchant_id: @order[:merchant_id], amount: amount, status: "settled")
    remaining = amount
    WalletLot.fefo_for_update(member_id).each do |lot|
      break if remaining <= 0

      take = [remaining, lot.remaining].min
      new_remaining = round6(lot.remaining - take)
      lot.update!(remaining: new_remaining, status: new_remaining <= 0 ? "consumed" : lot.status)
      PaymentAllocation.create!(payment: payment, wallet_lot: lot, amount: take)
      remaining = round6(remaining - take)
    end

    apply_movement!(member_id: member_id, amount: -amount, kind: "burn",
                    label: "Paiement en points", order_id: @order[:id], merchant_id: @order[:merchant_id])
    { payment_id: payment.id, amount: amount }
  end

  # Crée l'Earn (journal immuable) + le lot FEFO + crédite le portefeuille + relevé.
  def create_earn!(member_id:, earn_type:, generation:, amount:, applied_rate:,
                   member_sponsorship_id: nil, counterparty: nil)
    earn = EarnLedger.create!(
      member_id: member_id, member_sponsorship_id: member_sponsorship_id, reward_config_id: @config.id,
      order_id: @order[:id], merchant_id: @order[:merchant_id], order_amount: @order[:order_amount],
      commission_rate: @order[:commission_rate], earn_type: earn_type, generation: generation,
      amount: amount, applied_rate: applied_rate, delivered_at: delivered_at,
      expires_at: delivered_at + @config.expiration_months.months
    )
    WalletLot.create!(earn: earn, member_id: member_id, unit: "EUR",
                      initial_amount: amount, remaining: amount,
                      earned_at: delivered_at, expires_at: earn.expires_at)

    if earn_type == "personal"
      apply_movement!(member_id: member_id, amount: amount, kind: "personal_earn",
                      label: "Earn personnel", order_id: @order[:id], merchant_id: @order[:merchant_id],
                      counter: :personal_counter)
    else
      apply_movement!(member_id: member_id, amount: amount, kind: "sponsorship_earn",
                      label: "Gain parrainage · G#{generation}", generation: generation,
                      order_id: @order[:id], merchant_id: @order[:merchant_id],
                      counterparty_member_id: counterparty, counter: :sponsorship_counter)
    end
  end

  # V6 — mémorise la date du 1er achat du membre (base de l'éligibilité « 15 j »
  # à l'enrôlement). On ne recule jamais cette date une fois posée.
  def touch_first_purchase!(member_id)
    m = Membership.find_by(member_id: member_id)
    return if m.nil? || m.first_purchase_at.present?

    m.update_columns(first_purchase_at: delivered_at, updated_at: Time.current)
  end

  def claim_idempotency_key!
    ProcessedEvent.create!(event_key: @event_key, event_type: "OrderDelivered", status: "processing")
  end

  def mark_succeeded!
    ProcessedEvent.where(event_key: @event_key).update_all(status: "succeeded", updated_at: Time.current)
  end

  def delivered_at
    @delivered_at ||=
      if @order[:delivered_at].is_a?(String) && @order[:delivered_at].present?
        Time.zone.parse(@order[:delivered_at])
      elsif @order[:delivered_at].present?
        @order[:delivered_at]
      else
        Time.current
      end
  end
end
