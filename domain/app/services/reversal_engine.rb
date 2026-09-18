# frozen_string_literal: true

require "bigdecimal"

# Moteur d'ANNULATION — annule TOUT ce qu'une commande a produit :
#   * clawback de l'earn : on reprend le gain Personnel de l'acheteur ET, en
#     cascade, chaque gain de Parrainage remonté aux parrains ;
#   * restitution du burn : si l'achat était réglé en partie en points, on rend
#     les unités consommées (les lots FEFO retrouvent leur reliquat) et le
#     paiement passe à `reversed`.
#
# Le `reversal_type` renvoyé vaut 'earn', 'burn' ou 'earn+burn' selon ce que la
# commande contenait. Idempotent (clé `rev-<order>`), atomique, verrouillé.
class ReversalEngine
  include LoyaltyLedger

  Result = Struct.new(:status, :reversal_type, :buyer, :clawback, :restored,
                      :earn_lines, :burn_line, keyword_init: true)

  def self.call(order_id:, event_key:)
    new(order_id, event_key).call
  end

  def initialize(order_id, event_key)
    @order_id  = order_id.to_i
    @event_key = event_key
  end

  def call
    earns    = EarnLedger.where(order_id: @order_id).order(:id).to_a
    payments = Payment.where(order_id: @order_id, status: "settled").to_a
    return Result.new(status: :not_found) if earns.empty? && payments.empty?

    ActiveRecord::Base.transaction do
      claim_idempotency_key!

      buyer     = nil
      clawback  = BigDecimal(0)
      restored  = BigDecimal(0)
      earn_lines = []

      # 1) Clawback de l'earn (acheteur + parrains).
      #    Le montant repris est CLAMPÉ au reliquat réel du lot d'origine :
      #      * lot encore actif  -> on reprend son `remaining` (≤ montant earn) et
      #        on neutralise le lot (status « reversed », remaining 0) pour qu'il
      #        ne soit plus consommable en FEFO (correctif bug #1) ;
      #      * lot déjà consommé / expiré -> rien à reprendre (recoverable = 0),
      #        les unités étaient légitimement sorties ; le solde ne devient JAMAIS
      #        négatif puisqu'on ne retire que ce qui reste dans le lot.
      earns.each do |earn|
        lot         = WalletLot.lock.find_by(earn_id: earn.id)
        recoverable = lot&.status == "active" ? [earn.amount, lot.remaining].min : BigDecimal(0)

        if earn.earn_type == "personal"
          buyer = earn.member_id
          apply_movement!(member_id: earn.member_id, amount: -recoverable, kind: "reversal_earn",
                          label: reversal_label("Annulation earn personnel", earn.amount, recoverable),
                          order_id: @order_id, counter: :personal_counter)
        else
          apply_movement!(member_id: earn.member_id, amount: -recoverable, kind: "reversal_earn",
                          label: reversal_label("Annulation gain parrainage · G#{earn.generation}", earn.amount, recoverable),
                          generation: earn.generation, order_id: @order_id,
                          counterparty_member_id: buyer, counter: :sponsorship_counter)
        end

        lot.update!(remaining: 0, status: "reversed") if lot&.status == "active"
        clawback += recoverable
        earn_lines << { member_id: earn.member_id, generation: earn.generation,
                        amount: earn.amount, recovered: recoverable }
      end

      # 2) Restitution du burn (les lots retrouvent leur reliquat).
      burn_line = nil
      payments.each do |payment|
        buyer ||= payment.member_id
        payment.payment_allocations.each do |alloc|
          lot = WalletLot.lock.find(alloc.wallet_lot_id)
          restored = round6(lot.remaining + alloc.amount)
          lot.update!(remaining: restored, status: restored.positive? ? "active" : lot.status)
        end
        payment.update!(status: "reversed")
        apply_movement!(member_id: payment.member_id, amount: payment.amount, kind: "reversal_burn",
                        label: "Annulation paiement — points restitués", order_id: @order_id)
        restored += payment.amount
        burn_line = { member_id: payment.member_id, amount: payment.amount }
      end

      # 3) Reprise des CAGNOTTES plateforme de la commande (B2).
      #    L'annulation ne doit pas laisser en cagnotte la part plateforme d'une
      #    commande annulée. On ajoute des contributions compensatoires NÉGATIVES
      #    (immuabilité préservée), à la même date métier que l'origine.
      compensate_pools!(buyer)

      reversal_type =
        if earns.any? && payments.any? then "earn+burn"
        elsif payments.any? then "burn"
        else "earn"
        end

      Reversal.create!(order_id: @order_id, reversal_type: reversal_type,
                       earn_clawback_total: clawback, burn_restored_total: restored)
      mark_succeeded!

      Result.new(status: :processed, reversal_type: reversal_type, buyer: buyer,
                 clawback: clawback, restored: restored, earn_lines: earn_lines, burn_line: burn_line)
    end
  rescue ActiveRecord::RecordNotUnique
    Result.new(status: :duplicate)
  end

  private

  # B2 — Compense les contributions plateforme de la commande annulée.
  #   * Fonctionnement & Grands leaders : repris EN TOTALITÉ (part purement
  #     plateforme, jamais distribuée à un membre).
  #   * Comportemental : repris seulement si le batch mensuel ne l'a PAS encore
  #     consommé. Si la récompense du mois a déjà été versée (photo mensuelle
  #     existante), la part est ACQUISE -> on ne la reprend pas (règle B6).
  # Les compensations portent le même `occurred_at` que l'origine, pour se déduire
  # du bon mois dans le potentiel comportemental.
  def compensate_pools!(_buyer)
    PoolContribution.where(order_id: @order_id).where("amount > 0").find_each do |orig|
      if orig.pool_type == "comportemental"
        period = orig.occurred_at.strftime("%Y-%m")
        next if MemberMonthlyReward.exists?(member_id: orig.source_member_id, period: period)
      end
      PoolContribution.create!(pool_type: orig.pool_type, order_id: @order_id,
                               source_member_id: orig.source_member_id,
                               amount: -orig.amount, occurred_at: orig.occurred_at)
    end
  end

  # Libellé de relevé : mentionne explicitement quand le clawback est partiel
  # (une part du gain avait déjà été dépensée et ne peut être reprise).
  def reversal_label(base, nominal, recovered)
    return base if recovered >= nominal

    "#{base} — repris #{format('%.2f', recovered)} € / #{format('%.2f', nominal)} € (solde déjà dépensé)"
  end

  def claim_idempotency_key!
    ProcessedEvent.create!(event_key: @event_key, event_type: "OrderReversed", status: "processing")
  end

  def mark_succeeded!
    ProcessedEvent.where(event_key: @event_key).update_all(status: "succeeded", updated_at: Time.current)
  end
end
