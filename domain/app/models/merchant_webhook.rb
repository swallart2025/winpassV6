# frozen_string_literal: true

# Configuration du webhook sortant d'un marchand (R5) : URL + secret HMAC.
class MerchantWebhook < ApplicationRecord
  validates :merchant_id, presence: true, uniqueness: true
  validates :url, :secret, presence: true
end
