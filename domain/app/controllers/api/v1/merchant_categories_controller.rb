# frozen_string_literal: true

module Api
  module V1
    # GET /v1/merchant-categories
    # PUT /v1/merchant-categories  { entries: [{merchant_id, category}] }  (remplace l'ensemble)
    class MerchantCategoriesController < ApplicationController
      def index
        render json: MerchantCategory.order(:merchant_id).map { |m| { merchant_id: m.merchant_id, category: m.category } }
      end

      def update
        entries = params.permit(entries: %i[merchant_id category])[:entries] || []
        ActiveRecord::Base.transaction do
          MerchantCategory.delete_all
          entries.each { |e| MerchantCategory.create!(merchant_id: e[:merchant_id].to_s.upcase, category: e[:category]) }
        end
        render json: { count: MerchantCategory.count }, status: :ok
      end
    end
  end
end
