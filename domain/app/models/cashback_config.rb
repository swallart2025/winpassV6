# frozen_string_literal: true

# V6 — Paramètres versionnés du programme de cashback.
#   * threshold_cents : seuil de conversion automatique (défaut 20,00 €).
#   * cadence_days    : conversion périodique même sous le seuil (défaut hebdo).
# Les deux sont réglables au BO ; le moteur lit toujours la version courante.
class CashbackConfig < ApplicationRecord
  validates :version_label, presence: true, uniqueness: true
  validates :threshold_cents, :cadence_days, presence: true,
            numericality: { greater_than_or_equal_to: 0 }

  scope :current, -> { where(effective_to: nil).order(effective_from: :desc) }

  def self.current!
    current.first || raise(ActiveRecord::RecordNotFound, "Aucune configuration de cashback active")
  end

  # Seuil exprimé en euros (BigDecimal) pour comparaison directe aux montants.
  def threshold_amount
    BigDecimal(threshold_cents.to_s) / 100
  end
end
