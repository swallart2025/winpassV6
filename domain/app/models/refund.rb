# frozen_string_literal: true

# Trace immuable d'un règlement de remboursement (R1–R5) : déductions, montant net
# rendu sur carte, mode parrains, payload webhook.
class Refund < ApplicationRecord
  include Immutable
end
