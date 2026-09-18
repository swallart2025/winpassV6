# frozen_string_literal: true

# Configuration VERSIONNÉE des catégories comportementales. Une seule version
# "en vigueur" (effective_to NULL). `categories` = tableau de hachages :
# { "name", "max", "validity_months", "qualifying_min" }.
class LoyaltyCategoryConfig < ApplicationRecord
  validates :version_label, presence: true, uniqueness: true

  scope :current, -> { where(effective_to: nil).order(effective_from: :desc) }

  def self.current!
    current.first || raise(ActiveRecord::RecordNotFound, "Aucune version de catégories en vigueur")
  end

  # @return [Array<Hash>] catégories avec clés symbolisées et décimaux normalisés
  def entries
    categories.map do |c|
      { name: c["name"], max: c["max"].to_i, validity_months: c["validity_months"].to_i,
        qualifying_min: BigDecimal(c["qualifying_min"].to_s) }
    end
  end
end
