# frozen_string_literal: true

# Jeu de DÉMONSTRATION COHÉRENT V5.1 — de quoi voir les 3 modules distribuer.
#
# Il ajoute un « éventail » : un leader Léa (#900) avec 8 filleuls directs (#901..#908),
# dont les NIVEAUX acheteur sont pré-posés (démo) pour ouvrir le gate des 7 filleuls
# qualifiés côté Bâtisseurs et donner une assiette à la Prime de Statut. Puis des
# ACHATS réels (via le vrai PurchaseEngine, config V5-2026) qui alimentent les 3 poches
# (Prime de Statut 5 %, Comportemental 15 %, Grands leaders 7,5 %).
#
# ⚠️ Démo : les niveaux acheteur sont pré-posés ici pour rendre les modules visibles.
# En production, ils viennent du batch de statut acheteur (status/run). Ne pas lancer
# status/run sur cette démo, sinon les niveaux seront recalculés depuis les scores réels.
#
# Idempotent : membres/sponsorships/niveaux via find_or_create ; achats via event_key
# unique (un rejeu du seed ne double rien).

DEMO_PERIOD  = "2026-09"
DEMO_QUARTER = "2026-Q3"
DEMO_AT      = Time.zone.local(2026, 9, 10, 10, 0, 0)

DEMO_LEADER   = { 900 => "Léa (leader démo)" }.freeze
DEMO_FILLEULS = { 901 => "Filleul F1", 902 => "Filleul F2", 903 => "Filleul F3", 904 => "Filleul F4",
                  905 => "Filleul F5", 906 => "Filleul F6", 907 => "Filleul F7", 908 => "Filleul F8" }.freeze
# Niveaux acheteur pré-posés (démo) : filleuls qualifiés (≥ Ruisseau=5). 4 Rivière(9) + 4 Delta(13).
DEMO_LEVELS = { 900 => 9, 901 => 9, 902 => 9, 903 => 9, 904 => 9,
                905 => 13, 906 => 13, 907 => 13, 908 => 13 }.freeze

# 1) Membres + portefeuilles.
DEMO_LEADER.merge(DEMO_FILLEULS).each do |mid, name|
  m = Membership.find_or_create_by!(member_id: mid) { |x| x.display_name = name; x.status = "active" }
  m.update_columns(display_name: name) if m.display_name != name
  Wallet.find_or_create_by!(member_id: mid)
end

# 2) Éventail : chaque filleul est parrainé DIRECTEMENT par Léa (#900).
DEMO_FILLEULS.each_key do |mid|
  next if MemberSponsorship.where(member_id: mid).where(effective_to: nil).exists?

  MemberSponsorship.create!(member_id: mid, sponsor_member_id: 900,
                            effective_from: Time.zone.local(2026, 1, 1), reason: "signup_demo")
end

# 3) Niveaux acheteur pré-posés (démo) — ouvrent le gate + donnent l'assiette Prime de Statut.
DEMO_LEVELS.each do |mid, niveau|
  grand = ((niveau - 1) / 4) + 1
  st = MemberStatus.find_or_initialize_by(member_id: mid)
  st.niveau_tenu = niveau
  st.grand_niveau = grand
  st.compteur_repli ||= 0
  st.date_entree_gn ||= DEMO_AT
  st.save!
end

# 4) Achats réels (PurchaseEngine, V5-2026) sur la période de démo : Léa 300 €,
#    chaque filleul 100 € — commission 2 %. Alimente les 3 poches + remontée parrainage.
def demo_purchase!(order_id, member_id, amount, merchant)
  PurchaseEngine.call(
    order: { id: order_id, member_id: member_id, order_amount: amount.to_s,
             commission_rate: "0.02", merchant_id: merchant, points_redeemed: "0",
             delivered_at: DEMO_AT.iso8601 },
    event_key: "demo-v5-#{order_id}"
  )
rescue => e
  Rails.logger.warn("[demo_v5] achat #{order_id} ignoré : #{e.class} #{e.message}")
end

demo_purchase!(9000, 900, 300, "DECATHLON") # Léa : active son multiplicateur d'activité
DEMO_FILLEULS.each_key.with_index do |mid, i|
  demo_purchase!(9001 + i, mid, 100, %w[CARREFOUR BIO FNAC DECATHLON SEPHORA LEROY].fetch(i % 6))
end

puts "Seed démo V5.1 : leader #900 + 8 filleuls, niveaux posés, achats V5 (poches alimentées) sur #{DEMO_PERIOD}."
