# frozen_string_literal: true

# Annulation d'une commande (journal immuable). Une seule annulation par
# commande (index unique en base). Porte le type de ce qui a été annulé.
class Reversal < ApplicationRecord
  include Immutable

  TYPES = %w[earn burn earn+burn].freeze

  validates :order_id, presence: true, uniqueness: true
  validates :reversal_type, inclusion: { in: TYPES }
end
