# frozen_string_literal: true

# Journal immuable de la CIC (Cagnotte d'Incitation Comportementale). Chaque
# ligne porte un montant SIGNÉ (+ crédit, - débit) et le solde résultant. Le
# solde courant = balance_after de la dernière ligne.
class CicLedger < ApplicationRecord
  include Immutable

  KINDS = %w[monthly_contribution campaign_reserve campaign_release manual_credit].freeze

  validates :kind, inclusion: { in: KINDS }
  validates :amount, :balance_after, presence: true

  def self.balance
    order(:id).last&.balance_after || BigDecimal(0)
  end

  # Applique un mouvement signé et renvoie le nouveau solde.
  def self.move!(kind:, amount:, reference: {})
    after = (balance + amount).round(6, BigDecimal::ROUND_HALF_UP)
    create!(kind: kind, amount: amount, balance_after: after, reference: reference)
    after
  end
end
