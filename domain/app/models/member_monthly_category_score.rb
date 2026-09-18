# frozen_string_literal: true

# Détail mensuel par catégorie (cumul d'achats, contribution au score, date du
# dernier rechargement). Sert à l'affichage et à l'audit du score d'adhésion.
class MemberMonthlyCategoryScore < ApplicationRecord
  include Immutable
  validates :member_id, :period, :category, presence: true
end
