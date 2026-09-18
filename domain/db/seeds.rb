# frozen_string_literal: true

load Rails.root.join("db/seeds/config.rb") # configuration de récompense

# Réseau de démonstration : Alice(20) <- Bruno(120) <- David(300) <- Sophie(410) <- Emma(500)
NETWORK  = { 20 => "Alice", 120 => "Bruno", 300 => "David", 410 => "Sophie", 500 => "Emma" }.freeze
SPONSORS = { 120 => 20, 300 => 120, 410 => 300, 500 => 410 }.freeze

NETWORK.each do |member_id, name|
  m = Membership.find_or_create_by!(member_id: member_id) do |x|
    x.display_name = name
    x.status = "active"
  end
  m.update_columns(display_name: name) if m.display_name != name
  Wallet.find_or_create_by!(member_id: member_id)
end

SPONSORS.each do |child, sponsor|
  next if MemberSponsorship.active.exists?(member_id: child)

  MemberSponsorship.create!(member_id: child, sponsor_member_id: sponsor,
                            effective_from: Time.zone.local(2026, 1, 1), reason: "signup")
end

puts "Seed : config V1-2026 + réseau (#{NETWORK.size} membres) + comportemental en place."

# Jeu de démonstration cohérent V5.1 (leader + 8 filleuls + achats V5 qui alimentent
# les poches) — pour voir Prime de Statut / Bâtisseurs / Comportemental distribuer.
load Rails.root.join("db/seeds/demo_v5.rb")
