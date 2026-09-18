# frozen_string_literal: true

module Api
  module V1
    # V6 — Espace parrain côté membre : filleuls directs nommés, niveaux suivants
    # anonymisés (comptes seulement), cashback et compteurs. Ne divulgue jamais la
    # commission d'apport ni les achats des filleuls.
    #   GET /v1/parrain?member_id=
    class ParrainController < ApplicationController
      def show
        render json: ParrainView.build(member_id: params.require(:member_id)), status: :ok
      end
    end
  end
end
