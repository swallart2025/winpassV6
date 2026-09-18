# frozen_string_literal: true

require "bigdecimal"

# Calcul PUR des primes de rang Bâtisseurs pour un achat (spec §3.2-bis).
#
#   Majoration(g) = taux_rang(rang_g) × w_d(g) × B
#
# où w_d(g) est le poids géométrique renormalisé (même table que le parrainage,
# somme = 1) → le total est borné à taux_max × B (≤ 10 %·B). Le résidu entre la
# poche Grands leaders (7,5 %·B) et la somme distribuée alimente la RFA.
class PrimeRangMath
  # Barème des rangs : Graine..Canopée (index 0..6).
  BAREME = [BigDecimal("0"), BigDecimal("0.01"), BigDecimal("0.02"), BigDecimal("0.04"),
            BigDecimal("0.06"), BigDecimal("0.08"), BigDecimal("0.10")].freeze
  NOMS = %w[Graine Jeune-Plant Arbre Bosquet Bois Forêt Canopée].freeze

  def self.taux(rang) = BAREME[rang]
  def self.nom(rang)  = NOMS[rang]

  # @param upline [Array<Hash>] { generation:, rang: } du plus proche au plus loin
  # @param weights [Hash{Integer=>BigDecimal}] génération => poids renormalisé
  # @param base [BigDecimal] B = commission de l'achat
  # @return [Hash] { majorations: {gen=>montant}, distributed:, }
  def self.majorations(upline:, weights:, base:)
    maj = {}
    upline.each do |link|
      g = link[:generation]
      maj[g] = (BAREME[link[:rang]] * weights.fetch(g) * base).round(6, BigDecimal::ROUND_HALF_UP)
    end
    { majorations: maj, distributed: maj.values.sum(BigDecimal(0)) }
  end

  # Résidu qui alimente la RFA = poche Grands leaders − distribué (peut être
  # négatif localement sur une commande « hauts rangs » ; mutualisé globalement).
  def self.rfa_residual(base:, distributed:, pocket_rate:)
    (base * pocket_rate - distributed).round(6, BigDecimal::ROUND_HALF_UP)
  end
end
