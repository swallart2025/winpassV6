# frozen_string_literal: true

# Relevé chronologique enrichi (projection immuable). Chaque ligne porte un
# montant SIGNÉ et le solde résultant : la somme des montants d'un membre
# reconstitue exactement son solde (invariant vérifié en test). C'est la source
# du tableau de bord (toutes les transactions d'un membre).
class WalletStatement < ApplicationRecord
  include Immutable

  KINDS = %w[personal_earn sponsorship_earn burn reversal_earn reversal_burn expiration campaign_cashback].freeze

  validates :member_id, :label, :amount, :balance_after, presence: true
  validates :kind, inclusion: { in: KINDS }

  scope :chronological, -> { order(:id) }

  # Ligne rattachée à un gain de parrainage (gain OU son annulation).
  def sponsorship_related?
    kind == "sponsorship_earn" || (kind == "reversal_earn" && generation.present?)
  end
end
