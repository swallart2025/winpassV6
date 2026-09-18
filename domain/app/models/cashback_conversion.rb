# frozen_string_literal: true

# V6 — Une conversion émise : le passage d'un montant de « en attente » vers
# « Crédit Winpass ». `trigger` dit pourquoi elle a eu lieu :
#   * 'threshold' : le solde en attente a atteint le seuil (20 €) ;
#   * 'cadence'   : la cadence hebdo est échue (même sous le seuil) ;
#   * 'manual'    : conversion déclenchée à la main (BO / membre).
class CashbackConversion < ApplicationRecord
  TRIGGERS = %w[threshold cadence manual].freeze

  validates :member_id, :amount, :converted_at, presence: true
  validates :trigger, inclusion: { in: TRIGGERS }
end
