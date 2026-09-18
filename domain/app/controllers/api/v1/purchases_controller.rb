# frozen_string_literal: true

module Api
  module V1
    # POST /v1/purchases
    # Corps : { order_id, member_id, order_amount, commission_rate, merchant_id,
    #           points_redeemed?, delivered_at? }
    # Un achat génère l'earn ; si points_redeemed > 0, il génère aussi le burn.
    class PurchasesController < ApplicationController
      def create
        key = idempotency_key!
        return if performed?

        result = PurchaseEngine.call(order: order_params, event_key: key)

        case result.status
        when :duplicate
          render json: { status: "duplicate", detail: "Événement déjà traité" }, status: :ok
        when :insufficient_balance
          render json: { code: "insufficient_balance", detail: "Solde insuffisant pour ce paiement en points",
                         available_balance: fmt(result.balance), needed: fmt(result.burn[:needed]) },
                 status: :conflict
        else
          render json: serialize(result), status: :created
        end
      end

      private

      def order_params
        p = params.permit(:order_id, :member_id, :order_amount, :commission_rate,
                          :merchant_id, :points_redeemed, :delivered_at)
        {
          id: p[:order_id], member_id: p[:member_id], order_amount: p[:order_amount],
          commission_rate: p[:commission_rate], merchant_id: p[:merchant_id],
          points_redeemed: p[:points_redeemed], delivered_at: p[:delivered_at]
        }
      end

      def serialize(result)
        body = {
          status: "processed",
          budget_commission: fmt(result.base),
          earns: [{ type: "personal", generation: 0, amount: fmt(result.personal) }] +
                 result.sponsorship.map { |mid, amt| { type: "sponsorship", member_id: mid.to_i, amount: fmt(amt) } },
          reserves: result.reserves.transform_values { |v| fmt(v) },
          comportemental: fmt(result.comportemental),
          wallet: { available_balance: fmt(result.balance) }
        }
        if result.burn
          body[:burn] = { amount_redeemed: fmt(result.burn[:amount]), payment_id: result.burn[:payment_id] }
        end
        body
      end

      def fmt(value)
        format("%.6f", value)
      end
    end
  end
end
