# frozen_string_literal: true

# Configuration de récompense "courante" (V1). Utilisée par l'application ET par
# la suite de tests. Tables de distribution pré-calculées (série géométrique de
# raison 0,70, renormalisée par profondeur).
RewardConfig.find_or_create_by!(version_label: "V1-2026") do |c|
  c.personal_rate       = BigDecimal("0.45")
  c.sponsorship_rate    = BigDecimal("0.20")
  c.fonctionnement_rate = BigDecimal("0.125")
  c.comportemental_rate = BigDecimal("0.15")
  c.grands_leaders_rate = BigDecimal("0.075")
  c.sponsorship_ratio   = BigDecimal("0.70")
  c.sponsorship_max_generation = 5
  c.inactivity_months = 4
  c.expiration_months = 24
  c.effective_from = Time.zone.local(2026, 1, 1)
  c.distributions = {
    "1" => { "1" => "1.000000" },
    "2" => { "1" => "0.588235", "2" => "0.411765" },
    "3" => { "1" => "0.456621", "2" => "0.319635", "3" => "0.223744" },
    "4" => { "1" => "0.394789", "2" => "0.276352", "3" => "0.193447", "4" => "0.135413" },
    "5" => { "1" => "0.360607", "2" => "0.252425", "3" => "0.176698", "4" => "0.123688", "5" => "0.086582" }
  }
end

# --- V5 : bascule socle 40 % + poche Prime de Statut 5 % ---------------------
# Nouvelle version courante ; V1-2026 est close (les earns V4 y restent rattachés
# pour la rejouabilité). Somme des taux = 100 % : 40 + 5 + 20 + 15 + 12,5 + 7,5.
unless RewardConfig.exists?(version_label: "V5-2026")
  base_dist = RewardConfig.find_by(version_label: "V1-2026")&.distributions
  RewardConfig.where(effective_to: nil).update_all(effective_to: Time.zone.local(2026, 7, 1))
  RewardConfig.create!(
    version_label: "V5-2026",
    personal_rate: BigDecimal("0.40"), prime_statut_rate: BigDecimal("0.05"),
    sponsorship_rate: BigDecimal("0.20"), fonctionnement_rate: BigDecimal("0.125"),
    comportemental_rate: BigDecimal("0.15"), grands_leaders_rate: BigDecimal("0.075"),
    sponsorship_ratio: BigDecimal("0.70"), sponsorship_max_generation: 5,
    inactivity_months: 4, expiration_months: 24,
    effective_from: Time.zone.local(2026, 7, 1),
    distributions: base_dist || {
      "1" => { "1" => "1.000000" },
      "2" => { "1" => "0.588235", "2" => "0.411765" },
      "3" => { "1" => "0.456621", "2" => "0.319635", "3" => "0.223744" },
      "4" => { "1" => "0.394789", "2" => "0.276352", "3" => "0.193447", "4" => "0.135413" },
      "5" => { "1" => "0.360607", "2" => "0.252425", "3" => "0.176698", "4" => "0.123688", "5" => "0.086582" }
    }
  )
end

# --- V5 : configuration Prime de Statut (pas 0,5 % ; plafond +60 ; poche 5 %) --
unless PrimeStatutConfig.exists?
  PrimeStatutConfig.create!(
    version_label: "PS-V1-2026", effective_from: Time.zone.local(2026, 7, 1),
    poche_rate: BigDecimal("0.05"), pas: BigDecimal("0.005"),
    plafond: BigDecimal("0.60"), niveaux: 20
  )
end

# --- V3 : configuration comportementale (partagée app + tests) ---------------
{
  "CARREFOUR" => "Alimentaire", "BIO" => "Alimentaire",
  "FNAC" => "Culture & Loisirs", "DECATHLON" => "Culture & Loisirs",
  "SEPHORA" => "Beauté", "LEROY" => "Bricolage"
}.each do |merchant_id, category|
  MerchantCategory.find_or_create_by!(merchant_id: merchant_id) { |m| m.category = category }
end

unless LoyaltyCategoryConfig.exists?
  LoyaltyCategoryConfig.create!(
    version_label: "CAT-V1-2026", effective_from: Time.zone.local(2026, 1, 1),
    categories: [
      { name: "Alimentaire", max: 35, validity_months: 1, qualifying_min: "50" },
      { name: "Restaurants", max: 10, validity_months: 1, qualifying_min: "30" },
      { name: "Culture & Loisirs", max: 10, validity_months: 3, qualifying_min: "40" },
      { name: "Mode", max: 8, validity_months: 3, qualifying_min: "60" },
      { name: "Beauté", max: 5, validity_months: 3, qualifying_min: "30" },
      { name: "Voyage", max: 8, validity_months: 6, qualifying_min: "200" },
      { name: "Bricolage", max: 6, validity_months: 6, qualifying_min: "50" },
      { name: "Jardin/Animaux", max: 5, validity_months: 6, qualifying_min: "40" },
      { name: "Équipement maison", max: 13, validity_months: 12, qualifying_min: "150" }
    ]
  )
end

unless AdherenceScaleConfig.exists?
  AdherenceScaleConfig.create!(
    version_label: "BAR-V1-2026", effective_from: Time.zone.local(2026, 1, 1),
    tranches: [[0, 19, 0], [20, 39, 25], [40, 59, 50], [60, 79, 75], [80, 100, 100]]
  )
end

# --- V6 (Phase 1) : configuration du cashback (seuil 20 € ; cadence hebdo) -----
# Deux paramètres réglables au BO : seuil de conversion automatique et cadence.
unless defined?(CashbackConfig) && CashbackConfig.exists?
  CashbackConfig.create!(
    version_label: "CB-V6-2026", effective_from: Time.zone.local(2026, 7, 1),
    threshold_cents: 2000, cadence_days: 7
  ) if defined?(CashbackConfig)
end
