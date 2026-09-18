# frozen_string_literal: true

module Api
  module V1
    # GET /v1/loyalty-categories  -> version en vigueur + historique
    # PUT /v1/loyalty-categories  { version_label, categories: [{name,max,validity_months,qualifying_min}] }
    class LoyaltyCategoriesController < ApplicationController
      def show
        render json: {
          current: cfg_json(LoyaltyCategoryConfig.current!),
          history: LoyaltyCategoryConfig.order(effective_from: :desc).map { |c| hist_json(c) }
        }
      end

      def update
        cats = params.permit(:version_label, categories: %i[name max validity_months qualifying_min])
        label = cats[:version_label].presence || "CAT-#{Time.current.to_i}"
        ActiveRecord::Base.transaction do
          LoyaltyCategoryConfig.where(effective_to: nil).update_all(effective_to: Time.current)
          LoyaltyCategoryConfig.create!(version_label: label, categories: cats[:categories] || [], effective_from: Time.current)
        end
        render json: { version: label, statut: "en vigueur", effective_from: Time.current }, status: :created
      end

      private

      def cfg_json(c) = { version_label: c.version_label, effective_from: c.effective_from, categories: c.categories }
      def hist_json(c) = { version_label: c.version_label, effective_from: c.effective_from, effective_to: c.effective_to, statut: c.effective_to.nil? ? "en vigueur" : "clôturée" }
    end
  end
end
