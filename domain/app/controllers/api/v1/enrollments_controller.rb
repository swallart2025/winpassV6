# frozen_string_literal: true

module Api
  module V1
    # V6 — Enrôlement : OTP mail, invitation par un parrain, acceptation CGU/CGV
    # sur la landing, import de masse, contrôle d'éligibilité.
    #   POST /v1/enrollments/otp        -> émet un OTP par e-mail
    #   POST /v1/enrollments/otp/verify -> vérifie l'OTP
    #   GET  /v1/enrollments/eligibility?member_id= -> le membre peut-il enrôler ?
    #   POST /v1/enrollments/invite     -> un parrain invite un e-mail
    #   POST /v1/enrollments/accept     -> acceptation CGU/CGV (crée l'adhésion)
    #   POST /v1/enrollments/import     -> import de masse (lignes email/parrain)
    class EnrollmentsController < ApplicationController
      def otp
        r = OtpService.issue!(email: params.require(:email), purpose: params[:purpose] || "enroll")
        # `code` renvoyé pour le dev / la recette ; en prod il part par e-mail.
        render json: { status: "sent", expires_at: r.challenge.expires_at, code: r.code }, status: :created
      end

      def otp_verify
        r = OtpService.verify!(email: params.require(:email), code: params.require(:code),
                               purpose: params[:purpose] || "enroll")
        status = r.status == :ok ? :ok : :unprocessable_entity
        render json: { status: r.status }, status: status
      end

      def eligibility
        r = EnrollmentEligibility.check(member_id: params.require(:member_id))
        render json: { eligible: r.eligible, reason: r.reason, days_remaining: r.days_remaining }, status: :ok
      end

      def invite
        r = EnrollmentService.invite!(sponsor_member_id: params.require(:sponsor_member_id),
                                      email: params.require(:email), source: params[:source] || "app")
        if r.status == :sent
          render json: { status: "sent", token: r.invitation.token,
                         landing: "/enroll.html?token=#{r.invitation.token}" }, status: :created
        else
          render json: { code: "ineligible", detail: r.reason }, status: :forbidden
        end
      end

      def accept
        r = EnrollmentService.accept!(token: params.require(:token),
                                      display_name: params[:display_name],
                                      cgu: params[:cgu], cgv: params[:cgv])
        case r.status
        when :accepted
          render json: { status: "accepted", member_id: r.membership.member_id }, status: :created
        when :cgu_cgv_required
          render json: { code: "cgu_cgv_required", detail: "Acceptation CGU et CGV obligatoire" },
                 status: :unprocessable_entity
        when :already
          render json: { status: "already_accepted", member_id: r.invitation.member_id }, status: :ok
        else
          render json: { code: "not_found", detail: "Invitation inconnue" }, status: :not_found
        end
      end

      def import
        rows = params[:rows] || params.dig(:enrollment, :rows) || []
        rows = rows.map { |h| h.permit(:email, :sponsor_member_id).to_h } if rows.respond_to?(:map)
        created = EnrollmentService.import_mass!(rows: rows)
        render json: { status: "imported", created: created }, status: :created
      end
    end
  end
end
