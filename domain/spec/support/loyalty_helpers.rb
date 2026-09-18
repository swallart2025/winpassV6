# frozen_string_literal: true

# Utilitaires pour construire des jeux de données à résultats connus (golden).
module LoyaltyHelpers
  DELIVERED = Time.zone.local(2026, 3, 15, 10, 0, 0)

  # Réseau : Sophie(410) <- David(300) <- Bruno(120) <- Alice(20)
  # ("<-" = "est parrainé par"). Profondeur de Sophie = 3. Tous ACTIFS.
  def seed_network!
    t0 = Time.zone.local(2026, 1, 1)
    { 20 => "Alice", 120 => "Bruno", 300 => "David", 410 => "Sophie" }.each { |id, n| enroll!(id, n) }
    sponsor!(410, 300, t0)
    sponsor!(300, 120, t0)
    sponsor!(120, 20, t0)
  end

  def enroll!(member_id, name = nil)
    Membership.find_or_create_by!(member_id: member_id) { |m| m.display_name = name; m.status = "active" }
    Wallet.find_or_create_by!(member_id: member_id)
  end

  def sponsor!(member_id, sponsor_id, from)
    MemberSponsorship.create!(member_id: member_id, sponsor_member_id: sponsor_id,
                              effective_from: from, reason: "signup")
  end

  # Rend un parrain inactif (déclenche la compression verticale).
  def suspend!(member_id)
    Membership.where(member_id: member_id).update_all(status: "suspended")
  end

  # Commande "livrée". points: fraction réglée en points (0 = achat cash).
  def order(id:, buyer: 410, amount: "400", rate: "0.02", at: DELIVERED, merchant: "CARREFOUR", points: "0")
    { id: id, member_id: buyer, order_amount: amount, commission_rate: rate,
      merchant_id: merchant, delivered_at: at, points_redeemed: points }
  end

  # Exécute `count` blocs en parallèle (vrais threads, connexions distinctes),
  # relâchés simultanément par une barrière. Renvoie le tableau des résultats.
  def run_in_parallel(count)
    barrier = Concurrent::CyclicBarrier.new(count) if defined?(Concurrent::CyclicBarrier)
    results = Array.new(count)
    threads = (0...count).map do |i|
      Thread.new do
        ActiveRecord::Base.connection_pool.with_connection do
          barrier&.wait
          results[i] = yield(i)
        end
      end
    end
    threads.each(&:join)
    results
  end

  def balance(member_id) = Wallet.find_by!(member_id: member_id).available_balance
  def statements_sum(member_id) = WalletStatement.where(member_id: member_id).sum(:amount)
  def bd(str) = BigDecimal(str)
end

RSpec.configure { |c| c.include LoyaltyHelpers }
