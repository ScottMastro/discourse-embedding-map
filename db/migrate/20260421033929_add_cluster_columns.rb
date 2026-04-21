# frozen_string_literal: true

class AddClusterColumns < ActiveRecord::Migration[8.0]
  def change
    add_column :ai_topic_projections, :cluster_idx, :integer

    create_table :ai_topic_clusters do |t|
      t.bigint :model_id, null: false
      t.integer :cluster_idx, null: false
      t.integer :size, null: false
      t.float :centroid_x, null: false
      t.float :centroid_y, null: false
      t.jsonb :keywords, null: false, default: []
      t.text :label_llm
      t.string :method, null: false, default: "hdbscan"
      t.datetime :computed_at, null: false

      t.index %i[model_id cluster_idx], unique: true
    end
  end
end
