# frozen_string_literal: true

# En développement, l'application est servie via une URL Codespaces
# (*.app.github.dev). Sans cela, Rails renverrait "Blocked host". On lève la
# protection d'hôte hors production (aucune incidence sur la prod).
Rails.application.configure do
  config.hosts.clear unless Rails.env.production?
end
