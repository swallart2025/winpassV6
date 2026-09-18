# frozen_string_literal: true

Rails.application.routes.draw do
  get "/up", to: proc { [200, {}, ["ok"]] }        # sonde de vie
  root to: redirect("/index.html")                  # le tableau de bord (public/index.html)

  scope path: "v1", module: "api/v1", defaults: { format: :json } do
    # --- Cœur Earn / Burn / Annulation ---
    resources :members,   only: %i[index show], param: :id
    resources :purchases, only: %i[create]          # POST /v1/purchases (earn + burn + cashback campagne)
    resources :reversals, only: %i[create]          # POST /v1/reversals (annulation totale, V4)
    post "refunds", to: "refunds#create"             # POST /v1/refunds — règlement R1–R6 (total/partiel)
    post "pending/activate", to: "refunds#activate_pending" # active les soldes en attente échus
    get "orders", to: "orders#index"                 # vue lisible des commandes (#8)
    match "sponsorships", to: "sponsorships#update", via: %i[put patch post]

    # --- Lots & expiration ---
    resources :lots, only: %i[index update]          # GET /v1/lots ; PATCH /v1/lots/:id (fin de validité)
    post "expirations/run", to: "expirations#run"    # batch d'expiration

    # --- Comportemental & campagnes ---
    post "behavioral/run",   to: "behavioral#run"    # batch mensuel
    post "behavioral/purge", to: "behavioral#purge"  # purge/rollback du batch (rejeu banc d'essai)
    get  "behavioral/score", to: "behavioral#score"  # détail du score par catégorie + émulation (#9)
    get  "behavioral",       to: "behavioral#show"   # CIC, cagnottes, campagnes, photos mensuelles
    resources :campaigns, only: %i[index create]
    post "cic/credit", to: "cic#credit"               # abondement manuel de la CIC

    # --- Statut acheteur (V5) ---
    post "status/run", to: "status#run"               # batch mensuel du statut
    get  "status",     to: "status#show"              # niveaux tenus

    # --- Prime de performance collective de Statut (V5) ---
    post "prime-statut/run",   to: "prime_statut#run"   # batch de période
    post "prime-statut/purge", to: "prime_statut#purge" # purge « point barre » (rejeu)
    get  "prime-statut",       to: "prime_statut#show"  # photos + réserve

    # --- Bâtisseurs (statut parrains + primes de rang) (V5) ---
    post "builders/run",          to: "builders#run"         # batch mensuel du rang
    post "builders/primes/run",   to: "builders#primes"      # distribution trimestrielle + RFA
    post "builders/primes/purge", to: "builders#purge_primes" # purge « point barre » du trimestre
    get  "builders",              to: "builders#show"        # rangs + pot RFA

    # --- V6 (Phase 1) : cashback + conversions ---
    get  "cashback",            to: "cashback#show"        # soldes du membre
    post "cashback/convert",    to: "cashback#convert"     # conversion manuelle
    post "cashback/cadence/run", to: "cashback#run_cadence" # batch hebdo

    # --- V6 (Phase 1) : enrôlement (OTP, invitation, CGU/CGV, import) ---
    post "enrollments/otp",        to: "enrollments#otp"
    post "enrollments/otp/verify", to: "enrollments#otp_verify"
    get  "enrollments/eligibility", to: "enrollments#eligibility"
    post "enrollments/invite",     to: "enrollments#invite"
    post "enrollments/accept",     to: "enrollments#accept"
    post "enrollments/import",     to: "enrollments#import"

    # --- V6 (Phase 1) : fraude (blocage parrain) ---
    get  "fraud",            to: "fraud#index"
    post "fraud/open",       to: "fraud#open"
    post "fraud/:id/confirm", to: "fraud#confirm"
    post "fraud/:id/clear",  to: "fraud#clear"

    # --- V6 (Phase 1) : espace parrain (confidentiel) ---
    get "parrain", to: "parrain#show"

    # --- Paramétrage versionné ---
    get   "reward-configs",      to: "reward_configs#show"
    match "reward-configs",      to: "reward_configs#update", via: %i[put patch]
    get   "loyalty-categories",  to: "loyalty_categories#show"
    match "loyalty-categories",  to: "loyalty_categories#update", via: %i[put patch]
    get   "adherence-scales",    to: "adherence_scales#show"
    match "adherence-scales",    to: "adherence_scales#update", via: %i[put patch]
    get   "merchant-categories", to: "merchant_categories#index"
    match "merchant-categories", to: "merchant_categories#update", via: %i[put patch]
  end
end
