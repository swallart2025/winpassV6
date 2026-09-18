# frozen_string_literal: true

# Campagne d'incitation financée par la CIC. Cible une catégorie et les membres
# dont le score DANS CETTE catégorie est <= `eligibility_score_max` (les
# non-adhérents). Bonus en valeur fixe ou en % du montant de la commande.
# Clôture dès que le budget est épuisé OU la date de fin dépassée.
class Campaign < ApplicationRecord
  REWARD_TYPES = %w[value percent].freeze
  STATUSES     = %w[active closed].freeze

  has_many :campaign_rewards, dependent: :restrict_with_exception

  validates :category, presence: true
  validates :eligibility_score_max, numericality: { only_integer: true }
  validates :reward_type, inclusion: { in: REWARD_TYPES }
  validates :status, inclusion: { in: STATUSES }
  validates :reward_value, :budget_reserved, numericality: { greater_than: 0 }

  scope :active, -> { where(status: "active") }

  def remaining_budget
    budget_reserved - budget_spent
  end

  # Bonus théorique pour une commande d'un certain montant.
  def bonus_for(order_amount)
    reward_type == "value" ? reward_value : (BigDecimal(order_amount.to_s) * reward_value / 100).round(6, BigDecimal::ROUND_HALF_UP)
  end

  def expired?(at = Time.current)
    end_date.present? && at.to_date > end_date
  end
end
