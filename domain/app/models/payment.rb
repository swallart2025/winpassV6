# frozen_string_literal: true

# Paiement en points (Burn). Consomme des unités du portefeuille en FEFO.
# Peut passer à `reversed` lors d'une annulation de commande (d'où l'absence
# d'immuabilité : c'est un état, pas un journal comptable pur).
class Payment < ApplicationRecord
  STATUSES = %w[settled reversed].freeze

  has_many :payment_allocations, dependent: :restrict_with_exception

  validates :member_id, presence: true
  validates :amount, numericality: { greater_than: 0 }
  validates :status, inclusion: { in: STATUSES }
end
