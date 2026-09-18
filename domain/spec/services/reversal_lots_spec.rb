# frozen_string_literal: true

require "rails_helper"

# Bug #1 — l'annulation doit INVALIDER les lots de la commande annulée : ils
# passent en « reversed » (remaining 0), ne sont plus consommables en FEFO, et le
# clawback est CLAMPÉ au reliquat réel (jamais de solde négatif).
RSpec.describe "ReversalEngine — invalidation des lots (bug #1)" do
  before { seed_network! }

  def buy(id:, buyer: 410, points: "0")
    PurchaseEngine.call(order: order(id: id, buyer: buyer, points: points), event_key: "ord-#{id}")
  end
  def cancel(order_id) = ReversalEngine.call(order_id: order_id, event_key: "rev-#{order_id}")
  def lot_for(order_id, member_id)
    WalletLot.where(earn_id: EarnLedger.where(order_id: order_id, member_id: member_id).select(:id)).first
  end

  it "neutralise les lots de l'acheteur ET des parrains (status reversed, remaining 0)" do
    buy(id: 1001)
    cancel(1001)
    expect(lot_for(1001, 410).status).to eq("reversed")     # acheteur
    expect(lot_for(1001, 410).remaining).to eq(0)
    expect(lot_for(1001, 300).status).to eq("reversed")     # un parrain
  end

  it "un lot annulé n'est plus consommable en FEFO" do
    buy(id: 1001)                 # lot 3,60 pour Sophie
    cancel(1001)                  # -> reversed
    buy(id: 2001)                 # nouveau lot actif 3,60
    reversed_lot = lot_for(1001, 410)
    # Un paiement en points ne doit toucher QUE le lot actif (2001), pas le reversed (1001).
    PurchaseEngine.call(order: order(id: 3001, buyer: 410, points: "1.0"), event_key: "ord-3001")
    expect(reversed_lot.reload.remaining).to eq(0)
    expect(reversed_lot.status).to eq("reversed")
  end

  it "clampe le clawback au reliquat quand le lot a été partiellement consommé" do
    buy(id: 1001)                 # lot 3,60
    buy(id: 2001, points: "2.0")  # burn 2 -> lot 1001 partiellement consommé (reste 1,60)
    lot = lot_for(1001, 410)
    expect(lot.remaining).to eq(bd("1.6"))

    cancel(1001)
    expect(lot.reload.status).to eq("reversed")
    expect(lot.remaining).to eq(0)
    expect(balance(410)).to be >= 0                 # jamais négatif
    expect(statements_sum(410)).to eq(balance(410)) # invariant Σ(relevé) == solde conservé
  end

  it "ne reprend rien si le lot était déjà entièrement consommé (sans solde négatif)" do
    buy(id: 1001)                 # lot 3,60
    buy(id: 2001, points: "3.6")  # consomme entièrement le lot 1001
    expect(lot_for(1001, 410).remaining).to eq(0)

    cancel(1001)
    expect(balance(410)).to be >= 0
    expect(statements_sum(410)).to eq(balance(410))
  end
end
