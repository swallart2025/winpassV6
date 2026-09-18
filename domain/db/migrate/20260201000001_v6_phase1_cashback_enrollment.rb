# frozen_string_literal: true

# V6 — Phase 1 : programme de cashback + enrôlement.
#   * Cashback : deux soldes (en attente de conversion / Crédit Winpass) +
#     conversion automatique (seuil 20 € et/ou cadence hebdo, paramétrables) +
#     compteur global des autres poches (informationnel, côté membre).
#   * Enrôlement : OTP mail, invitations (CGU/CGV), éligibilité « 15 jours
#     d'achat », import de masse, dossiers de fraude (blocage parrain).
class V6Phase1CashbackEnrollment < ActiveRecord::Migration[7.2]
  def change
    # --- Cashback : configuration versionnée ---------------------------------
    create_table :cashback_configs do |t|
      t.string   :version_label,   null: false
      t.integer  :threshold_cents, null: false, default: 2000 # 20,00 € (paramétrable BO)
      t.integer  :cadence_days,    null: false, default: 7     # conversion hebdo (paramétrable BO)
      t.datetime :effective_from,  null: false
      t.datetime :effective_to
      t.timestamps
    end
    add_index :cashback_configs, :version_label, unique: true

    # --- Cashback : deux soldes par membre -----------------------------------
    create_table :cashback_accounts do |t|
      t.bigint   :member_id, null: false
      t.decimal  :pending_amount,        precision: 18, scale: 6, null: false, default: 0 # en attente de conversion
      t.decimal  :credit_winpass_amount, precision: 18, scale: 6, null: false, default: 0 # solde Crédit Winpass (converti)
      t.decimal  :lifetime_cashback,     precision: 18, scale: 6, null: false, default: 0
      t.datetime :last_conversion_at
      t.timestamps
    end
    add_index :cashback_accounts, :member_id, unique: true

    # --- Cashback : conversions émises (= cartes multi-choix / Crédit Winpass)
    create_table :cashback_conversions do |t|
      t.bigint   :member_id, null: false
      t.decimal  :amount, precision: 18, scale: 6, null: false
      t.string   :trigger, null: false # 'threshold' | 'cadence' | 'manual'
      t.datetime :converted_at, null: false
      t.timestamps
    end
    add_index :cashback_conversions, %i[member_id converted_at]
    add_check_constraint :cashback_conversions, "trigger IN ('threshold','cadence','manual')",
                         name: "cashback_conversions_trigger_check"

    # --- Compteur global des autres poches (informationnel) ------------------
    create_table :member_poche_counters do |t|
      t.bigint  :member_id, null: false
      t.decimal :prime_statut,   precision: 18, scale: 6, null: false, default: 0 # Podium (5 %)
      t.decimal :comportemental, precision: 18, scale: 6, null: false, default: 0 # Grande Galerie (15 %)
      t.decimal :grands_leaders, precision: 18, scale: 6, null: false, default: 0 # Bâtisseurs (7,5 %)
      t.decimal :fonctionnement, precision: 18, scale: 6, null: false, default: 0 # plateforme (12,5 %)
      t.decimal :parrainage_recu, precision: 18, scale: 6, null: false, default: 0 # reçu en tant que parrain
      t.timestamps
    end
    add_index :member_poche_counters, :member_id, unique: true

    # --- Enrôlement : OTP mail -----------------------------------------------
    create_table :otp_challenges do |t|
      t.string   :email, null: false
      t.string   :code, null: false
      t.string   :purpose, null: false, default: "enroll"
      t.datetime :expires_at, null: false
      t.datetime :consumed_at
      t.integer  :attempts, null: false, default: 0
      t.timestamps
    end
    add_index :otp_challenges, %i[email purpose created_at]

    # --- Enrôlement : invitations (CGU/CGV) ----------------------------------
    create_table :enrollment_invitations do |t|
      t.string   :email, null: false
      t.bigint   :sponsor_member_id, null: false
      t.string   :token, null: false
      t.string   :status, null: false, default: "sent" # sent | accepted | expired
      t.bigint   :member_id                             # rempli à l'acceptation
      t.string   :display_name
      t.datetime :cgu_accepted_at
      t.datetime :cgv_accepted_at
      t.string   :source, null: false, default: "app"  # app | mass_import
      t.timestamps
    end
    add_index :enrollment_invitations, :token, unique: true
    add_index :enrollment_invitations, :email

    # --- Fraude : dossiers + blocage parrain ---------------------------------
    create_table :fraud_cases do |t|
      t.bigint   :member_id, null: false            # le parrain bloqué
      t.bigint   :reported_member_id                # le filleul fraudeur (origine)
      t.string   :status, null: false, default: "open" # open | confirmed | cleared
      t.string   :reason
      t.datetime :opened_at, null: false
      t.datetime :closed_at
      t.timestamps
    end
    add_index :fraud_cases, %i[member_id status]

    # --- Colonnes ajoutées aux memberships (Phase 1) -------------------------
    add_column :memberships, :email, :string
    add_column :memberships, :first_purchase_at, :datetime
    add_column :memberships, :blocked, :boolean, null: false, default: false
    add_column :memberships, :blocked_reason, :string
    add_column :memberships, :cgu_accepted_at, :datetime
    add_column :memberships, :cgv_accepted_at, :datetime
  end
end
