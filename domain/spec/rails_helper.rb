# frozen_string_literal: true

ENV["RAILS_ENV"] ||= "test"
require_relative "../config/environment"
abort("Rails tourne en mode production !") if Rails.env.production?
require "rspec/rails"

Dir[Rails.root.join("spec/support/**/*.rb")].each { |f| require f }

RSpec.configure do |config|
  config.infer_spec_type_from_file_location!
  config.filter_rails_from_backtrace!

  # Les tests de CONCURRENCE utilisent de vrais threads avec des connexions
  # distinctes : on désactive les fixtures transactionnelles et on nettoie par
  # TRUNCATE avant chaque test. On ne réamorce QUE la configuration (chaque test
  # construit son propre réseau via les helpers).
  config.use_transactional_fixtures = false

  config.before(:each) do
    tables = ActiveRecord::Base.connection.tables - %w[schema_migrations ar_internal_metadata]
    ActiveRecord::Base.connection.execute(
      "TRUNCATE #{tables.map { |t| ActiveRecord::Base.connection.quote_table_name(t) }.join(', ')} RESTART IDENTITY CASCADE"
    )
    load Rails.root.join("db/seeds/config.rb")
  end
end
