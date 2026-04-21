# frozen_string_literal: true

# name: discourse-embedding-map
# version: 1.0
# authors: ScottMastro
# url: https://github.com/ScottMastro/discourse-embedding-map
# required_version: 2.7.0
# transpile_js: true

enabled_site_setting :embedding_map_enabled

register_svg_icon "diagram-project" if respond_to?(:register_svg_icon)

register_asset "stylesheets/embedding-map.scss"

after_initialize do
  module ::EmbeddingMap
    PLUGIN_NAME = "discourse-embedding-map"
  end

  class EmbeddingMap::Engine < ::Rails::Engine
    engine_name EmbeddingMap::PLUGIN_NAME
    isolate_namespace EmbeddingMap
  end

  require_relative "app/controllers/embedding_map_controller.rb"

  EmbeddingMap::Engine.routes.draw { get "/topic-map.json" => "embedding_map#index" }

  Discourse::Application.routes.append do
    mount ::EmbeddingMap::Engine, at: "/"
    # Ember client-side route — the server just needs to render the app shell so
    # a hard-refresh on /topic-map doesn't 404. list#latest emits the standard
    # application layout and the Ember router takes over.
    get "/topic-map" => "list#latest"
  end
end
