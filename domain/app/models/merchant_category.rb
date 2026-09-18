# frozen_string_literal: true

# Rattache une enseigne (merchant_id) à UNE catégorie de consommation. Sert au
# calcul comportemental (SUM par catégorie via merchant_id) et à l'éligibilité
# des campagnes.
class MerchantCategory < ApplicationRecord
  validates :merchant_id, presence: true, uniqueness: true
  validates :category, presence: true

  def self.category_for(merchant_id)
    find_by(merchant_id: merchant_id)&.category
  end
end
