# frozen_string_literal: true

module Api
  module V1
    # POST /v1/expirations/run  { as_of }
    class ExpirationsController < ApplicationController
      def run
        key = idempotency_key!
        return if performed?

        result = ExpirationEngine.call(as_of: params[:as_of], event_key: key)
        return render(json: { status: "duplicate" }, status: :ok) if result.status == :duplicate

        render json: {
          status: "processed", as_of: result.as_of,
          lots_expires: result.expired_count, unites_retirees: fmt(result.units_removed),
          detail: result.lines.map { |l| l.merge(amount: fmt(l[:amount])) }
        }, status: :created
      end

      private

      def fmt(v) = format("%.6f", v)
    end
  end
end
