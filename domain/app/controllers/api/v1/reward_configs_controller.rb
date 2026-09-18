# frozen_string_literal: true

module Api
  module V1
    # GET /v1/reward-configs  -> version courante + historique
    # PUT /v1/reward-configs  { version_label, rates: {personal, sponsorship, fonctionnement, comportemental, grands_leaders} }
    class RewardConfigsController < ApplicationController
      RATE_KEYS = %w[personal sponsorship fonctionnement comportemental grands_leaders].freeze

      def show
        render json: {
          current: cfg_json(RewardConfig.current!),
          history: RewardConfig.order(effective_from: :desc).map { |c| cfg_json(c).merge(
            effective_to: c.effective_to, statut: c.effective_to.nil? ? "courante" : "clôturée"
          ) }
        }
      end

      def update
        rates = params.require(:rates).permit(*RATE_KEYS)
        sum = RATE_KEYS.sum { |k| BigDecimal(rates[k].to_s) }
        unless (sum - 1).abs <= BigDecimal("0.0001")
          return render(json: { code: "somme_taux_invalide", total_pct: format("%.2f %%", sum * 100) }, status: :unprocessable_entity)
        end

        label = params[:version_label].presence || "V-#{Time.current.to_i}"
        base = RewardConfig.current!
        ActiveRecord::Base.transaction do
          RewardConfig.where(effective_to: nil).update_all(effective_to: Time.current)
          RewardConfig.create!(
            version_label: label,
            personal_rate: rates[:personal], sponsorship_rate: rates[:sponsorship],
            fonctionnement_rate: rates[:fonctionnement], comportemental_rate: rates[:comportemental],
            grands_leaders_rate: rates[:grands_leaders], sponsorship_ratio: base.sponsorship_ratio,
            sponsorship_max_generation: base.sponsorship_max_generation, distributions: base.distributions,
            inactivity_months: base.inactivity_months, expiration_months: base.expiration_months,
            effective_from: Time.current
          )
        end
        render json: { version: label, statut: "courante", effective_from: Time.current }, status: :created
      end

      private

      def cfg_json(c)
        { version_label: c.version_label, effective_from: c.effective_from,
          rates: { personal: c.personal_rate, sponsorship: c.sponsorship_rate,
                   fonctionnement: c.fonctionnement_rate, comportemental: c.comportemental_rate,
                   grands_leaders: c.grands_leaders_rate } }
      end
    end
  end
end
