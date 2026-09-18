# Image de développement/test du moteur de fidélité Winpass.
# Elle génère un squelette Rails 7.2 propre, y installe les dépendances, puis
# superpose le code métier (dossier domain/). Ainsi, tout le "boilerplate" est
# produit par Rails lui-même (donc correct), et seul le code métier est fourni.
FROM ruby:3.3.6-slim

ENV DEBIAN_FRONTEND=noninteractive \
    LANG=C.UTF-8 \
    BUNDLE_JOBS=4

# Dépendances système (compilation des gems + client PostgreSQL).
RUN apt-get update -qq && \
    apt-get install -y --no-install-recommends \
      build-essential libpq-dev libyaml-dev postgresql-client git curl tzdata && \
    rm -rf /var/lib/apt/lists/*

RUN gem install rails -v 7.2.2.1 --no-document

WORKDIR /app

# 1) Squelette Rails API + PostgreSQL, généré par Rails.
RUN rails new . --api --database=postgresql --skip-test --skip-git --force

# 1-bis) CORRECTIF : fige la bibliothèque JSON sur une version stable. Une version
# trop récente casse les migrations avec « unknown keyword: quirks_mode ».
RUN bundle add json --version "2.6.3"

# 2) Gems de test (RSpec + FactoryBot).
RUN bundle add rspec-rails --group="development,test" && \
    bundle add factory_bot_rails --group="development,test"

# 2b) Outils qualité & sécurité (lint idiomatique + scan de vulnérabilités),
#     pour produire le rapport qualité. Runnables via `docker compose run`.
RUN bundle add rubocop-rails --group="development" && \
    bundle add brakeman --group="development"

# 3) Code métier par-dessus le squelette.
COPY domain/ /app/

# 4) Point d'entrée : prépare la base, lance les tests, puis démarre l'API.
COPY entrypoint.sh /usr/local/bin/entrypoint.sh
RUN chmod +x /usr/local/bin/entrypoint.sh

EXPOSE 3000
ENTRYPOINT ["entrypoint.sh"]
