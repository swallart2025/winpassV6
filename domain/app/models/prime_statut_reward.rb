# frozen_string_literal: true

# Photo immuable de la prime de statut d'un membre pour une période.
class PrimeStatutReward < ApplicationRecord
  include Immutable
end
