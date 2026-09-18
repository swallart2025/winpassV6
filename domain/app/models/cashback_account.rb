# frozen_string_literal: true

# V6 — Deux soldes de cashback par membre :
#   * pending_amount        : cashback gagné, EN ATTENTE de conversion ;
#   * credit_winpass_amount : solde CONVERTI (Crédit Winpass, dépensable) ;
#   * lifetime_cashback     : cumul historique (informationnel).
# La conversion (pending -> credit) est faite par ConversionEngine.
class CashbackAccount < ApplicationRecord
  validates :member_id, presence: true, uniqueness: true
end
