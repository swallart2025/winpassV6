# frozen_string_literal: true

module Api
  module V1
    # GET /v1/adherence-scales  -> version en vigueur + historique
    # PUT /v1/adherence-scales  { version_label, tranches: [[from,to,rate], ...] }
    class AdherenceScalesController < ApplicationController
      def show
        render json: {
          current: { version_label: AdherenceScaleConfig.current!.version_label, tranches: AdherenceScaleConfig.current!.tranches },
          history: AdherenceScaleConfig.order(effective_from: :desc).map { |c|
            { version_label: c.version_label, effective_from: c.effective_from, effective_to: c.effective_to,
              statut: c.effective_to.nil? ? "en vigueur" : "clôturée" }
          }
        }
      end

      def update
        label = params[:version_label].presence || "BAR-#{Time.current.to_i}"
        # tranches = tableau de tableaux [[from, to, rate], ...] : on le lit hors strong-params
        tranches = Array(params[:tranches]).map { |t| Array(t).map(&:to_i) }
        ActiveRecord::Base.transaction do
          AdherenceScaleConfig.where(effective_to: nil).update_all(effective_to: Time.current)
          AdherenceScaleConfig.create!(version_label: label, tranches: tranches, effective_from: Time.current)
        end
        render json: { version: label, statut: "en vigueur", effective_from: Time.current }, status: :created
      end
    end
  end
end
