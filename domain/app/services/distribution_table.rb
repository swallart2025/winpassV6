# frozen_string_literal: true

# Répartit un pool de parrainage entre les générations présentes, selon la table
# renormalisée de la configuration. La règle d'arrondi est CONSERVATIVE : les
# générations 2..d sont arrondies à 6 décimales, et la génération 1 reçoit le
# reliquat, de sorte que la somme des parts égale EXACTEMENT le pool.
class DistributionTable
  SCALE = 6

  def initialize(reward_config)
    @config = reward_config
  end

  # @param pool [BigDecimal] montant total à répartir
  # @param depth [Integer] nombre de parrains actifs réellement présents (1..5)
  # @return [Hash{Integer=>BigDecimal}] génération => montant
  def distribute(pool, depth)
    return {} if depth.zero?

    weights = @config.distribution_for(depth)
    parts = {}
    (2..depth).each { |g| parts[g] = round6(pool * weights.fetch(g)) }
    parts[1] = round6(pool - parts.values.sum(BigDecimal(0)))
    parts
  end

  private

  def round6(value)
    value.round(SCALE, BigDecimal::ROUND_HALF_UP)
  end
end
