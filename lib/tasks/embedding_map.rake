# frozen_string_literal: true

namespace :embedding_map do
  desc "Compute UMAP projection of topic embeddings into ai_topic_projections"
  task compute: :environment do
    model_id = SiteSetting.ai_embeddings_selected_model.to_i
    raise "ai_embeddings_selected_model is not configured" if model_id.zero?

    config = ActiveRecord::Base.connection_db_config.configuration_hash
    dsn_parts = [
      "host=#{config[:host] || "localhost"}",
      "port=#{config[:port] || 5432}",
      "dbname=#{config[:database]}",
    ]
    dsn_parts << "user=#{config[:username]}" if config[:username]
    dsn_parts << "password=#{config[:password]}" if config[:password]
    dsn = dsn_parts.join(" ")

    env = {
      "EMBEDDING_MAP_DSN" => dsn,
      "EMBEDDING_MAP_MODEL_ID" => model_id.to_s,
      "EMBEDDING_MAP_MAX_POINTS" => SiteSetting.embedding_map_max_points.to_s,
      "EMBEDDING_MAP_N_NEIGHBORS" => SiteSetting.embedding_map_umap_n_neighbors.to_s,
      "EMBEDDING_MAP_MIN_DIST" => SiteSetting.embedding_map_umap_min_dist.to_s,
    }

    script = File.expand_path("../python/project_embeddings.py", __dir__)
    python = ENV["EMBEDDING_MAP_PYTHON"] || "python3"

    puts "Running #{python} #{script}"
    success = system(env, python, script)
    raise "UMAP projection failed" unless success
  end
end
