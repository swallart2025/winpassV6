# frozen_string_literal: true

# Barème d'adhésion VERSIONNÉ. `tranches` = [[from, to, rate], ...]. Une seule
# version "en vigueur". Le batch mensuel applique `rate` au potentiel selon le
# score d'adhésion du membre.
class AdherenceScaleConfig < ApplicationRecord
  validates :version_label, presence: true, uniqueness: true

  scope :current, -> { where(effective_to: nil).order(effective_from: :desc) }

  def self.current!
    current.first || raise(ActiveRecord::RecordNotFound, "Aucun barème d'adhésion en vigueur")
  end

  # Taux débloqué (%) pour un score donné.
  def rate_for(score)
    tranche = tranches.find { |from, to, _rate| score >= from.to_i && score <= to.to_i }
    tranche ? tranche[2].to_i : 0
  end
end
