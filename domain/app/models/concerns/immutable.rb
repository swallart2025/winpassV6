# frozen_string_literal: true

# Rend un modèle "journal" immuable : une fois créée, une ligne ne peut plus
# être ni modifiée ni supprimée. C'est une garantie forte pour les journaux
# comptables (earn_ledgers, member_sponsorships, pool_contributions...).
module Immutable
  extend ActiveSupport::Concern

  included do
    before_update  { raise ActiveRecord::ReadOnlyRecord, "#{self.class} est un journal immuable" }
    before_destroy { raise ActiveRecord::ReadOnlyRecord, "#{self.class} est un journal immuable" }
  end
end
