# frozen_string_literal: true

# Fails a worker loudly if it is connected to another process's database,
# the guard the README recommends for `--boot shared`, and creates the
# schema in a fresh per-process SQLite file.
module DatabaseGuard
  module_function

  def check!
    suffix = ENV.fetch("TEST_ENV_NUMBER", "")
    database = ActiveRecord::Base.connection_db_config.database.to_s
    return if File.basename(database, ".sqlite3").end_with?("test#{suffix}")

    raise "worker #{suffix.inspect} is connected to #{database}"
  end

  def load_schema!
    return if ActiveRecord::Base.connection.table_exists?(:posts)

    ActiveRecord::Schema.verbose = false
    load Rails.root.join("db/schema.rb")
  end
end
