# frozen_string_literal: true

module Api
  module V1
    class RefundsController < ApplicationController
      # POST /v1/refunds  { order_id, ratio?, sponsor_mode? }
      # Règlement de remboursement R1–R6 (total ou partiel). Winpass calcule et
      # informe (payload webhook) ; le marchand exécute le remboursement carte.
      def create
        r = RefundEngine.call(order_id: params.require(:order_id),
                              ratio: params[:ratio] || 1,
                              sponsor_mode: params[:sponsor_mode])
        return render(json: { code: "not_found", detail: "Commande sans earn." }, status: :not_found) if r.status == :not_found

        s = r.settlement
        render json: {
          status: "settled", order_id: r.order_id, sponsor_mode: r.refund.sponsor_mode,
          repris_total: fmt(s[:repris_total]),
          deduction: { total: fmt(s[:card_deduction]), buyer: fmt(s[:card_deduction_buyer]),
                       sponsors: fmt(s[:card_deduction_sponsors]) },
          card_refund: fmt(s[:card_refund]),
          webhook: { status: r.refund.webhook_status, payload: r.refund.webhook_payload },
          message: "Remboursement commande #{r.order_id} : repris #{fmt(s[:repris_total])} €, " \
                   "déduit #{fmt(s[:card_deduction])} €, à rembourser sur carte #{fmt(s[:card_refund])} €."
        }, status: :created
      end

      # POST /v1/pending/activate  — active les soldes en attente arrivés à échéance.
      def activate_pending
        r = PendingActivation.call
        render json: { status: "processed", actives: r.activated,
                       message: "#{r.activated} lot(s) en attente activé(s)." }, status: :ok
      end

      def fmt(v) = format("%.6f", v)
    end
  end
end
