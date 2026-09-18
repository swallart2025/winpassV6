# frozen_string_literal: true

require "securerandom"

# V6 — Authentification par code à usage unique (OTP) envoyé par e-mail.
# Ici on GÉNÈRE et VÉRIFIE le code ; l'envoi effectif de l'e-mail est laissé à la
# couche notification (le code est renvoyé pour le développement/la recette).
class OtpService
  TTL_MINUTES = 10

  IssueResult  = Struct.new(:challenge, :code, keyword_init: true)
  VerifyResult = Struct.new(:status, keyword_init: true) # :ok | :invalid | :expired | :locked | :not_found

  # Émet un nouveau code pour (email, purpose). Invalide les défis actifs
  # précédents pour éviter l'accumulation.
  def self.issue!(email:, purpose: "enroll", at: Time.current)
    email = email.to_s.downcase.strip
    OtpChallenge.active.where(email: email, purpose: purpose)
                .update_all(consumed_at: at, updated_at: at)

    code = format("%06d", SecureRandom.random_number(1_000_000))
    challenge = OtpChallenge.create!(
      email: email, code: code, purpose: purpose,
      expires_at: at + TTL_MINUTES.minutes
    )
    IssueResult.new(challenge: challenge, code: code)
  end

  # Vérifie un code. Incrémente le compteur de tentatives ; consomme le défi si OK.
  def self.verify!(email:, code:, purpose: "enroll", at: Time.current)
    email = email.to_s.downcase.strip
    challenge = OtpChallenge.where(email: email, purpose: purpose, consumed_at: nil)
                            .order(created_at: :desc).first
    return VerifyResult.new(status: :not_found) if challenge.nil?
    return VerifyResult.new(status: :locked)    if challenge.locked?
    return VerifyResult.new(status: :expired)   if challenge.expired?

    challenge.increment!(:attempts)
    if ActiveSupport::SecurityUtils.secure_compare(challenge.code, code.to_s)
      challenge.update!(consumed_at: at)
      VerifyResult.new(status: :ok)
    else
      VerifyResult.new(status: :invalid)
    end
  end
end
