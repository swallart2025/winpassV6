# frozen_string_literal: true

require "bigdecimal"

# V6 — Conversion du cashback « en attente » vers « Crédit Winpass » (dépensable).
# Deux déclencheurs, tous deux PARAMÉTRABLES au BO (CashbackConfig) :
#   * SEUIL   : dès que le solde en attente atteint le seuil (défaut 20,00 €),
#     conversion immédiate (appelée au fil de l'eau par CashbackEngine) ;
#   * CADENCE : à échéance périodique (défaut hebdo), on convertit le reliquat
#     même sous le seuil (batch run_cadence!).
#
# Une conversion vide le solde en attente vers le Crédit Winpass et journalise une
# ligne CashbackConversion. Idempotent PAR ÉTAT : rien à convertir -> no-op.
class ConversionEngine
  include LoyaltyLedger # money / round6

  Result = Struct.new(:status, :converted, :amount, keyword_init: true)

  # Conversion sur seuil, pour un membre (appelée dans la transaction d'achat).
  def self.maybe_convert!(member_id:, at: Time.current)
    cfg  = CashbackConfig.current!
    acct = CashbackAccount.find_by(member_id: member_id)
    return Result.new(status: :none, converted: 0, amount: 0) unless acct

    acct.lock!
    return Result.new(status: :below_threshold, converted: 0, amount: 0) if acct.pending_amount < cfg.threshold_amount

    convert!(acct, trigger: "threshold", at: at)
  end

  # Conversion sur cadence, en batch (à lancer par un planificateur hebdo).
  # Convertit tout solde en attente > 0 dont la dernière conversion est échue
  # (ou qui n'a jamais été converti).
  def self.run_cadence!(at: Time.current)
    cfg     = CashbackConfig.current!
    horizon = at - cfg.cadence_days.days
    scope   = CashbackAccount.where("pending_amount > 0")
                             .where("last_conversion_at IS NULL OR last_conversion_at <= ?", horizon)

    converted = 0
    total     = BigDecimal("0")
    scope.find_each do |acct|
      ActiveRecord::Base.transaction do
        acct.lock!
        next if acct.pending_amount <= 0

        r = new.send(:do_convert!, acct, trigger: "cadence", at: at)
        converted += 1
        total = r.amount + total
      end
    end
    Result.new(status: :processed, converted: converted, amount: total)
  end

  # Conversion manuelle (BO / membre) du solde en attente d'un membre.
  def self.convert_now!(member_id:, at: Time.current)
    acct = CashbackAccount.find_by(member_id: member_id)
    return Result.new(status: :none, converted: 0, amount: 0) unless acct

    ActiveRecord::Base.transaction do
      acct.lock!
      return Result.new(status: :nothing, converted: 0, amount: 0) if acct.pending_amount <= 0

      convert!(acct, trigger: "manual", at: at)
    end
  end

  # Helper de classe partagé (l'appelant tient déjà le verrou / la transaction).
  def self.convert!(acct, trigger:, at:)
    new.send(:do_convert!, acct, trigger: trigger, at: at)
  end

  private

  def do_convert!(acct, trigger:, at:)
    amount = round6(acct.pending_amount)
    acct.update!(
      pending_amount:        BigDecimal("0"),
      credit_winpass_amount: round6(acct.credit_winpass_amount + amount),
      last_conversion_at:    at
    )
    CashbackConversion.create!(member_id: acct.member_id, amount: amount,
                               trigger: trigger, converted_at: at)
    Result.new(status: :converted, converted: 1, amount: amount)
  end
end
