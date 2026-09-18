# frozen_string_literal: true

require "bigdecimal"

module Api
  module V1
    # POST /v1/cic/credit  { amount, label? }
    # Abondement manuel de la CIC (banc d'essai) : crédite la cagnotte d'un montant
    # pour pouvoir financer des campagnes au-delà des fonds issus du batch mensuel.
    class CicController < ApplicationController
      def credit
        amount = BigDecimal(params.require(:amount).to_s)
        if amount <= 0
          return render(json: { code: "montant_invalide", detail: "Le montant doit être positif" },
                        status: :unprocessable_entity)
        end

        after = CicLedger.move!(kind: "manual_credit", amount: amount,
                                reference: { source: "abondement manuel", label: params[:label].presence })
        render json: { status: "credited", montant: fmt(amount), cic_apres: fmt(after) }, status: :ok
      rescue ArgumentError
        render json: { code: "montant_invalide", detail: "Montant illisible" }, status: :unprocessable_entity
      end

      private

      def fmt(v) = format("%.6f", v)
    end
  end
end
