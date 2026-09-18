# frozen_string_literal: true

# V4b — Abondement manuel de la CIC. Nouveau type d'écriture `manual_credit` :
# permet de créditer la Cagnotte d'Incitation Comportementale (banc d'essai) pour
# financer des campagnes dont le budget dépasse les fonds issus du batch mensuel.
class V4bCicManualCredit < ActiveRecord::Migration[7.2]
  def change
    remove_check_constraint :cic_ledgers, name: "cic_kind_check"
    add_check_constraint :cic_ledgers,
                         "kind IN ('monthly_contribution','campaign_reserve','campaign_release','manual_credit')",
                         name: "cic_kind_check"
  end
end
