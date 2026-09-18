# frozen_string_literal: true

require "bigdecimal"

# Calcul du score d'adhésion comportemental d'un membre à une date donnée.
# Partagé par le batch mensuel ET par l'éligibilité des campagnes (temps réel).
#
# Règle (validée) :
#   * une catégorie « se recharge » à son max quand le CUMUL d'achats du membre
#     dans la catégorie (SUM sur earn_ledgers via merchant_categories) atteint son
#     « montant minimum qualificatif » ; le cumul repart alors de zéro ;
#   * depuis le dernier rechargement, la contribution DÉCROÎT linéairement sur la
#     durée de validité : `Contribution = Max × (1 − écoulé/durée)`, bornée à 0 ;
#   * pas d'échelon : décroissance MENSUELLE en général, BI-HEBDOMADAIRE (pas de
#     15 jours, −50 % à 15 jours) pour les catégories à validité 1 mois.
class BehavioralScore
  ROUND = BigDecimal::ROUND_HALF_UP

  def initialize(config = LoyaltyCategoryConfig.current!)
    @categories = config.entries.index_by { |c| c[:name] }
  end

  # @return [Hash] { cumulative:, last_recharge_at:, contribution: }
  def category_contribution(member_id, category, at)
    meta = @categories[category]
    return blank if meta.nil?

    cumulative = BigDecimal(0)
    last_recharge = nil
    personal_purchases(member_id, category, at).each do |order_amount, delivered_at|
      cumulative += BigDecimal(order_amount.to_s)
      if cumulative >= meta[:qualifying_min]
        last_recharge = delivered_at
        cumulative = BigDecimal(0)
      end
    end
    return { cumulative: cumulative, last_recharge_at: nil, contribution: BigDecimal(0) } if last_recharge.nil?

    { cumulative: cumulative, last_recharge_at: last_recharge,
      contribution: decayed_contribution(meta, last_recharge, at) }
  end

  # Score global (0..100), somme des contributions plafonnée.
  # V5 (B8) : arrondi AU SUPÉRIEUR (ceil) et non au plancher — 6,67 -> 7.
  def score(member_id, at)
    total = @categories.keys.sum { |c| category_contribution(member_id, c, at)[:contribution] }
    [100, total.ceil].min
  end

  # Score du membre DANS une catégorie (pour l'éligibilité campagne).
  def score_in_category(member_id, category, at)
    category_contribution(member_id, category, at)[:contribution].floor
  end

  def categories
    @categories.keys
  end

  # Métadonnées d'une catégorie (max, validity_months, qualifying_min) — pour le
  # détail du score et l'émulation temporelle.
  def meta_for(category)
    @categories[category]
  end

  private

  def blank
    { cumulative: BigDecimal(0), last_recharge_at: nil, contribution: BigDecimal(0) }
  end

  def decayed_contribution(meta, last_recharge, at)
    days   = (at.to_date - last_recharge.to_date).to_i
    step   = meta[:validity_months] == 1 ? 15 : 30           # bi-hebdo pour la validité mensuelle
    steps  = days / step
    elapsed_months = BigDecimal(steps) * step / 30
    factor = [BigDecimal(0), 1 - elapsed_months / meta[:validity_months]].max
    (BigDecimal(meta[:max]) * factor).round(6, ROUND)
  end

  # Achats personnels du membre dans la catégorie, à la date `at`, chronologiques.
  def personal_purchases(member_id, category, at)
    EarnLedger
      .where(member_id: member_id, earn_type: "personal")
      .where("earn_ledgers.delivered_at <= ?", at)
      .where("earn_ledgers.order_amount IS NOT NULL")
      .joins("JOIN merchant_categories mc ON mc.merchant_id = earn_ledgers.merchant_id")
      .where("mc.category = ?", category)
      .order(:delivered_at, :id)
      .pluck(:order_amount, :delivered_at)
  end
end
