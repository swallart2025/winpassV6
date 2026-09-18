# frozen_string_literal: true

module Api
  module V1
    # V6 — Fraude : ouverture d'un dossier (bloque le parrain), confirmation
    # (fraude avérée) ou levée (blanchi).
    #   GET  /v1/fraud                 -> dossiers (filtre ?status=open)
    #   POST /v1/fraud/open            -> signale un filleul -> bloque son parrain
    #   POST /v1/fraud/:id/confirm     -> fraude avérée
    #   POST /v1/fraud/:id/clear       -> blanchi (lève le blocage)
    class FraudController < ApplicationController
      def index
        scope = FraudCase.all
        scope = scope.where(status: params[:status]) if params[:status].present?
        render json: scope.order(opened_at: :desc).map { |fc| serialize(fc) }, status: :ok
      end

      def open
        r = FraudService.open!(reported_member_id: params.require(:reported_member_id),
                               reason: params[:reason])
        if r.status == :opened
          render json: { status: "opened", sponsor_member_id: r.sponsor_member_id,
                         fraud_case: serialize(r.fraud_case) }, status: :created
        else
          render json: { code: "no_sponsor", detail: "Aucun parrain à bloquer" }, status: :unprocessable_entity
        end
      end

      def confirm
        r = FraudService.confirm!(fraud_case_id: params.require(:id))
        respond_close(r)
      end

      def clear
        r = FraudService.clear!(fraud_case_id: params.require(:id))
        respond_close(r)
      end

      private

      def respond_close(r)
        return render(json: { code: "not_found" }, status: :not_found) if r.status == :not_found

        render json: { status: r.status, fraud_case: serialize(r.fraud_case) }, status: :ok
      end

      def serialize(fc)
        { id: fc.id, member_id: fc.member_id, reported_member_id: fc.reported_member_id,
          status: fc.status, reason: fc.reason, opened_at: fc.opened_at, closed_at: fc.closed_at }
      end
    end
  end
end
