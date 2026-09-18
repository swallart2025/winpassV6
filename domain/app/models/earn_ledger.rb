# frozen_string_literal: true

# Journal immuable des attributions de récompenses. Chaque ligne = un droit
# définitivement acquis. Montant toujours exprimé en euros (valeur brute).
class EarnLedger < ApplicationRecord
  include Immutable

  EARN_TYPES = %w[personal sponsorship comportemental adjustment].freeze

  belongs_to :member_sponsorship, optional: true
  belongs_to :reward_config, optional: true
  has_one :wallet_lot, foreign_key: :earn_id, inverse_of: :earn, dependent: :restrict_with_exception

  validates :member_id, :delivered_at, presence: true
  validates :earn_type, inclusion: { in: EARN_TYPES }
  validates :amount, numericality: { greater_than: 0 }
  validates :generation, numericality: { only_integer: true, greater_than_or_equal_to: 0 }
end
