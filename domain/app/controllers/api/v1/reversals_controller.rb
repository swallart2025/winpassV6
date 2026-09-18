# frozen_string_literal: true

module Api
  module V1
    # POST /v1/reversals  { order_id }
    # Annule une commande : clawback earn (acheteur + parrains) et/ou restitution burn.
    class ReversalsController < ApplicationController
      def create
        key = idempotency_key!
        return if performed?

        order_id = params.require(:order_id)
        result = ReversalEngine.call(order_id: order_id, event_key: key)

        case result.status
        when :duplicate
          render json: { status: "duplicate", detail: "Annulation déjà traitée" }, status: :ok
        when :not_found
          render json: { code: "not_found", detail: "Aucune commande ##{order_id} à annuler" }, status: :not_found
        else
          render json: serialize(result), status: :created
        end
      end

      private

      def serialize(result)
        {
          status: "processed",
          reversal_type: result.reversal_type,
          earn_clawback: result.earn_lines.any? ? {
            total: fmt(result.clawback),
            lines: result.earn_lines.map do |l|
              { member_id: l[:member_id], generation: l[:generation], amount: fmt(l[:amount]) }
            end
          } : nil,
          burn_restored: result.burn_line && {
            member_id: result.burn_line[:member_id], amount: fmt(result.burn_line[:amount])
          }
        }
      end

      def fmt(value)
        format("%.6f", value)
      end
    end
  end
end
