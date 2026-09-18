# frozen_string_literal: true

# Configuration versionnée du calcul des récompenses. Chaque Earn référence la
# version qui l'a produit, ce qui rend tout calcul rejouable même après une
# évolution des taux. Une seule version "courante" (effective_to NULL) existe.
class RewardConfig < ApplicationRecord
  validates :version_label, presence: true, uniqueness: true
  validates :personal_rate, :sponsorship_rate, :fonctionnement_rate,
            :comportemental_rate, :grands_leaders_rate, :sponsorship_ratio,
            presence: true

  scope :current, -> { where(effective_to: nil).order(effective_from: :desc) }

  def self.current!
    current.first || raise(ActiveRecord::RecordNotFound, "Aucune configuration de récompense active")
  end

  # Table de répartition renormalisée pour une profondeur donnée (1..5).
  # Les clés JSON sont des chaînes ("1","2"...) ; on renvoie un Hash{Integer=>BigDecimal}.
  def distribution_for(depth)
    distributions.fetch(depth.to_s).transform_keys(&:to_i)
                 .transform_values { |v| BigDecimal(v.to_s) }
  end
end
