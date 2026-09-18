# frozen_string_literal: true

# Trace fine d'un paiement : quelle part a été prélevée sur quel lot FEFO.
# Indispensable pour restituer EXACTEMENT les bons lots lors d'une annulation.
class PaymentAllocation < ApplicationRecord
  belongs_to :payment
  belongs_to :wallet_lot

  validates :amount, numericality: { greater_than: 0 }
end
