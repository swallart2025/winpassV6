# frozen_string_literal: true

# Paramètres versionnés de la Prime de Statut. `p` n'est PAS ici : il est déduit
# par équation à chaque exécution. Deux variables d'ajustement : `pas` et `plafond`.
class PrimeStatutConfig < ApplicationRecord
  validates :version_label, presence: true, uniqueness: true

  scope :current, -> { where(effective_to: nil).order(effective_from: :desc) }

  def self.current!
    current.first || raise(ActiveRecord::RecordNotFound, "Aucune configuration Prime de Statut active")
  end
end
