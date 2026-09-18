# frozen_string_literal: true

# Portefeuille d'un membre (projection du solde). Sérialise les opérations d'un
# même membre : chaque traitement Earn/Burn commence par `lock!` sur cette ligne
# (SELECT ... FOR UPDATE), ce qui met en file les écritures concurrentes.
class Wallet < ApplicationRecord
  validates :member_id, presence: true, uniqueness: true
  validates :available_balance, numericality: { greater_than_or_equal_to: 0 }
end
