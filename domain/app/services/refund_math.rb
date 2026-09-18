# frozen_string_literal: true

require "bigdecimal"

# Calcul PUR du RÈGLEMENT de remboursement (gouvernance R1–R4). Aucun blocage :
# on reprend ce qui est récupérable, on déduit le reste de la carte.
#
#   R1  récupérable d'un lot = min(earn effectif, remaining)   (lot par lot)
#   R2  non récupérable (déjà consommé) -> déduit du remboursement carte
#   R3  partiel : earn effectif = earn nominal × ratio
#   R4  parrains :
#        - mode :buyer_covers (défaut) -> on NE reprend PAS aux parrains ; leur
#          valeur effective est déduite de la carte de l'acheteur (parrains intacts)
#        - mode :clawback -> on reprend à CHAQUE parrain min(effectif, son remaining)
#          (R4-bis : prorata strict, aucune solidarité) ; le consommé d'un parrain
#          est perdu pour lui, NON déduit de la carte de l'acheteur
class RefundMath
  # @param order_amount [BigDecimal]
  # @param buyer  [Hash] { nominal:, remaining: }
  # @param sponsors [Array<Hash>] [{ nominal:, remaining: }, ...]  (prorata strict)
  # @param ratio [BigDecimal] 1 = total ; <1 = partiel
  # @param sponsor_mode [Symbol] :buyer_covers | :clawback
  def self.settle(order_amount:, buyer:, sponsors: [], ratio: BigDecimal("1"), sponsor_mode: :buyer_covers)
    eff_buyer   = r6(buyer[:nominal] * ratio)
    recov_buyer = [eff_buyer, buyer[:remaining]].min
    non_recov_buyer = r6(eff_buyer - recov_buyer)      # consommé -> carte

    sp = sponsors.map do |s|
      eff = r6(s[:nominal] * ratio)
      recov = [eff, s[:remaining]].min
      { eff: eff, recov: recov, non_recov: r6(eff - recov) }
    end

    if sponsor_mode == :clawback
      repris_sponsors = sp.sum(BigDecimal(0)) { |s| s[:recov] } # repris aux parrains
      card_sponsors   = BigDecimal(0)                            # rien sur la carte pour les parrains
    else # :buyer_covers
      repris_sponsors = BigDecimal(0)                            # parrains intacts
      card_sponsors   = sp.sum(BigDecimal(0)) { |s| s[:eff] }    # valeur parrains -> carte acheteur
    end

    card_deduction = r6(non_recov_buyer + card_sponsors)
    card_refund    = r6(order_amount * ratio - card_deduction)

    {
      recoverable_buyer: recov_buyer, repris_sponsors: repris_sponsors,
      repris_total: r6(recov_buyer + repris_sponsors),
      card_deduction: card_deduction, card_deduction_buyer: non_recov_buyer,
      card_deduction_sponsors: card_sponsors, card_refund: card_refund
    }
  end

  def self.r6(v) = v.round(6, BigDecimal::ROUND_HALF_UP)
end
