# frozen_string_literal: true

require "bigdecimal"

# V6 — Overlay CASHBACK, branché DANS la transaction d'achat (PurchaseEngine).
#
# Principe de la Phase 1 : côté MEMBRE, seule la générosité (le socle personnel
# 40 %) est convertible en cashback dépensable (« Crédit Winpass »). Les AUTRES
# poches (Prime de Statut, Grande Galerie, Bâtisseurs, fonctionnement, parrainage
# reçu) ne sont PAS versées au membre : elles sont seulement cumulées dans un
# compteur global, en euros, pour information (elles restent distribuées par les
# batchs V5 comme avant — cet overlay ne touche pas au cœur Earn/Burn).
#
# Ce que fait record! (idempotent par construction : il s'exécute derrière le
# verrou d'idempotence de PurchaseEngine, donc jamais deux fois pour un achat) :
#   1. crédite le solde EN ATTENTE de cashback de l'acheteur (socle 40 %) ;
#   2. incrémente le compteur « autres poches » de l'acheteur ;
#   3. incrémente le compteur « parrainage reçu » de chaque parrain rémunéré ;
#   4. tente une conversion immédiate si le seuil est atteint (ConversionEngine).
class CashbackEngine
  include LoyaltyLedger # money / round6

  def self.record!(buyer:, personal:, reserves:, sponsorship:, at:)
    new(buyer, personal, reserves, sponsorship, at).record!
  end

  def initialize(buyer, personal, reserves, sponsorship, at)
    @buyer       = buyer.to_i
    @personal    = money(personal)
    @reserves    = reserves || {}
    @sponsorship = sponsorship || {}
    @at          = at
  end

  def record!
    credit_cashback_pending!
    bump_buyer_counter!
    bump_sponsors_counter!
    # Conversion « au fil de l'eau » : dès que le seuil (20 €) est atteint.
    ConversionEngine.maybe_convert!(member_id: @buyer, at: @at)
  end

  private

  # 1) Socle 40 % -> solde en attente de conversion + cumul « à vie ».
  def credit_cashback_pending!
    acct = CashbackAccount.find_or_create_by!(member_id: @buyer)
    acct.lock!
    acct.update!(
      pending_amount:    round6(acct.pending_amount + @personal),
      lifetime_cashback: round6(acct.lifetime_cashback + @personal)
    )
  end

  # 2) Autres poches de l'acheteur -> compteur global (informationnel).
  def bump_buyer_counter!
    c = MemberPocheCounter.find_or_create_by!(member_id: @buyer)
    c.lock!
    c.update!(
      prime_statut:   round6(c.prime_statut   + res("prime_statut")),
      comportemental: round6(c.comportemental + res("comportemental")),
      grands_leaders: round6(c.grands_leaders + res("grands_leaders")),
      fonctionnement: round6(c.fonctionnement + res("fonctionnement"))
    )
  end

  # 3) Parrainage reçu -> compteur global de chaque parrain.
  def bump_sponsors_counter!
    @sponsorship.each do |member_id, amount|
      c = MemberPocheCounter.find_or_create_by!(member_id: member_id.to_i)
      c.lock!
      c.update!(parrainage_recu: round6(c.parrainage_recu + money(amount)))
    end
  end

  def res(key)
    money(@reserves[key] || @reserves[key.to_sym] || 0)
  end
end
