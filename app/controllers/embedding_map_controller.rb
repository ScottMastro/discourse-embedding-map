# frozen_string_literal: true

module EmbeddingMap
  class EmbeddingMapController < ::ApplicationController
    requires_plugin ::EmbeddingMap::PLUGIN_NAME

    before_action :check_access

    def index
      rows = DB.query(<<~SQL, category_ids: visible_category_ids)
        SELECT p.topic_id, p.x, p.y, t.category_id,
               EXTRACT(EPOCH FROM t.created_at)::bigint AS created_at,
               t.slug, t.title
        FROM ai_topic_projections p
        JOIN topics t ON t.id = p.topic_id
        WHERE t.deleted_at IS NULL
          AND t.archetype = 'regular'
          AND t.visible = TRUE
          AND t.category_id IN (:category_ids)
      SQL

      # Compact array-of-arrays payload keeps ~33k points near 1MB gzipped.
      # Titles included for the hover tooltip; slug lets the client build
      # the topic URL without a second round-trip.
      points =
        rows.map do |r|
          [r.topic_id, r.x.round(3), r.y.round(3), r.category_id, r.created_at, r.slug, r.title]
        end

      render json: {
               points: points,
               categories: categories_payload,
               computed_at: computed_at_epoch,
             }
    end

    private

    def check_access
      raise Discourse::NotFound unless SiteSetting.embedding_map_enabled

      min_tl = SiteSetting.embedding_map_min_trust_level
      if min_tl == -1
        # anonymous allowed
      elsif current_user.nil? || current_user.trust_level < min_tl
        raise Discourse::InvalidAccess
      end
    end

    def visible_category_ids
      @visible_category_ids ||= Category.secured(guardian).pluck(:id)
    end

    def categories_payload
      Category
        .where(id: visible_category_ids)
        .pluck(:id, :name, :color, :slug)
        .map { |id, name, color, slug| { id: id, name: name, color: color, slug: slug } }
    end

    def computed_at_epoch
      max = DB.query_single("SELECT MAX(computed_at) FROM ai_topic_projections").first
      max&.to_i
    end
  end
end
