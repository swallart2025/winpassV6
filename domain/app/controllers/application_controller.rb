# frozen_string_literal: true

class ApplicationController < ActionController::API
  # Erreurs métier -> réponses HTTP claires (format proche de problem+json).
  rescue_from ActiveRecord::RecordInvalid do |e|
    render json: { code: "validation_error", detail: e.message }, status: :unprocessable_entity
  end

  rescue_from ActiveRecord::RecordNotFound do |e|
    render json: { code: "not_found", detail: e.message }, status: :not_found
  end

  private

  # En-tête Idempotency-Key, obligatoire sur les écritures.
  def idempotency_key!
    key = request.headers["Idempotency-Key"].presence
    return key if key

    render json: { code: "missing_idempotency_key", detail: "En-tête Idempotency-Key requis" },
           status: :bad_request
    nil
  end
end
