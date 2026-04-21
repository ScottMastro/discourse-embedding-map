# frozen_string_literal: true

module EmbeddingMap
  class EmbeddingMapController < ::ApplicationController
    requires_plugin ::EmbeddingMap::PLUGIN_NAME

    before_action :check_access

    def index
      rows = DB.query(<<~SQL, category_ids: visible_category_ids)
          SELECT p.topic_id, p.x, p.y, p.cluster_idx, p.supercluster_idx,
                 t.category_id,
                 EXTRACT(EPOCH FROM t.created_at)::bigint AS created_at,
                 t.slug, t.title
          FROM ai_topic_projections p
          JOIN topics t ON t.id = p.topic_id
          WHERE t.deleted_at IS NULL
            AND t.archetype = 'regular'
            AND t.visible = TRUE
            AND t.category_id IN (:category_ids)
        SQL

      # Compact array-of-arrays payload. Indices:
      #   7 = cluster_idx, 8 = supercluster_idx (null = HDBSCAN noise / unclustered)
      points =
        rows.map do |r|
          [
            r.topic_id,
            r.x.round(3),
            r.y.round(3),
            r.category_id,
            r.created_at,
            r.slug,
            r.title,
            r.cluster_idx,
            r.supercluster_idx,
          ]
        end

      render json: {
               points: points,
               categories: categories_payload,
               clusters: group_payload(rows, "ai_topic_clusters", :cluster_idx),
               superclusters: group_payload(rows, "ai_topic_superclusters", :supercluster_idx),
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

    def group_payload(rows, table, row_attr)
      # Only include groups that still have ≥1 topic after Guardian filtering —
      # otherwise the legend would advertise clusters the user can't see.
      visible_sizes = Hash.new(0)
      rows.each { |r| visible_sizes[r.send(row_attr)] += 1 if r.send(row_attr) }
      return [] if visible_sizes.empty?

      # `table` is caller-controlled (not user input) — interpolating it is
      # safe here and avoids a second prepared-statement path per table.
      DB
        .query(<<~SQL, cluster_idxs: visible_sizes.keys)
          SELECT cluster_idx, size, centroid_x, centroid_y, keywords, label_llm
          FROM #{table}
          WHERE cluster_idx IN (:cluster_idxs)
          ORDER BY size DESC
        SQL
        .map do |c|
          keywords = c.keywords.is_a?(String) ? JSON.parse(c.keywords) : c.keywords
          {
            idx: c.cluster_idx,
            size: visible_sizes[c.cluster_idx],
            cx: c.centroid_x.round(3),
            cy: c.centroid_y.round(3),
            keywords: keywords,
            label: c.label_llm,
          }
        end
    end

    def computed_at_epoch
      max = DB.query_single("SELECT MAX(computed_at) FROM ai_topic_projections").first
      max&.to_i
    end
  end
end
