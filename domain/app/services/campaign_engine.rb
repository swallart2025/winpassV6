# frozen_string_literal: true

require "bigdecimal"

# Campagnes d'incitation, financées par la CIC, en TEMPS RÉEL.
#
#   * `eligible_campaign` : à l'instant de la commande, renvoie la campagne active
#     sur la catégorie de l'enseigne pour laquelle le membre est éligible
#     (score DANS la catégorie <= seuil), ou nil. Évaluée AVANT que la commande
#     ne compte (l'appelant l'invoque avant d'écrire l'earn de la commande).
#   * `award!` : verse le cashback (TOUT-OU-RIEN : si le budget restant ne couvre
#     pas le bonus entier, la campagne s'arrête sans verser), décompte le budget,
#     journalise le CampaignReward, et clôture la campagne si le budget est épuisé.
#   * Clôture aussi si la date de fin est dépassée ; le reliquat repart à la CIC.
class CampaignEngine
  ROUND = BigDecimal::ROUND_HALF_UP

  def self.eligible_campaign(member_id:, merchant_id:, at:, scorer: BehavioralScore.new)
    category = MerchantCategory.category_for(merchant_id)
    return nil if category.nil?

    campaign = Campaign.active.find_by(category: category)
    return nil if campaign.nil?

    if campaign.expired?(at)
      close!(campaign, reason: "end_date")
      return nil
    end
    scorer.score_in_category(member_id, category, at) <= campaign.eligibility_score_max ? campaign : nil
  end

  # Verse le cashback dans la transaction courante. `credit` reçoit (member_id, amount).
  # @return [Hash, nil] { campaign_id:, amount: } si versé, nil sinon.
  def self.award!(campaign:, member_id:, order_id:, order_amount:, credit:)
    campaign.lock!
    return nil unless campaign.status == "active"

    bonus = campaign.bonus_for(order_amount)
    if campaign.remaining_budget < bonus
      close!(campaign, reason: "budget") # budget insuffisant pour le bonus entier -> arrêt
      return nil
    end

    campaign.update!(budget_spent: (campaign.budget_spent + bonus).round(6, ROUND))
    CampaignReward.create!(campaign: campaign, member_id: member_id, order_id: order_id, amount: bonus)
    credit.call(member_id, bonus)
    close!(campaign, reason: "budget") if campaign.remaining_budget <= 0
    { campaign_id: campaign.id, amount: bonus }
  end

  # Clôture : fige le statut et rend le reliquat à la CIC.
  def self.close!(campaign, reason:)
    return if campaign.status == "closed"

    reliquat = campaign.remaining_budget
    campaign.update!(status: "closed", closed_reason: reason, reliquat: reliquat)
    CicLedger.move!(kind: "campaign_release", amount: reliquat,
                    reference: { campaign_id: campaign.id, reliquat: reliquat.to_s }) if reliquat.positive?
  end
end
