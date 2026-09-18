# frozen_string_literal: true

# V6 — Défi OTP par e-mail (authentification à l'enrôlement / connexion membre).
# Un code à usage unique, avec expiration et compteur de tentatives.
class OtpChallenge < ApplicationRecord
  MAX_ATTEMPTS = 5

  validates :email, :code, :purpose, :expires_at, presence: true

  scope :active, -> { where(consumed_at: nil).where("expires_at > ?", Time.current) }

  def expired?
    expires_at <= Time.current
  end

  def consumed?
    consumed_at.present?
  end

  def locked?
    attempts >= MAX_ATTEMPTS
  end
end
