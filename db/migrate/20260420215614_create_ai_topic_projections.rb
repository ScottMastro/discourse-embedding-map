# frozen_string_literal: true

class CreateAiTopicProjections < ActiveRecord::Migration[8.0]
  def change
    create_table :ai_topic_projections, primary_key: :topic_id do |t|
      t.bigint :topic_id, null: false
      t.float :x, null: false
      t.float :y, null: false
      t.integer :model_id, null: false
      t.string :method, null: false, default: "umap"
      t.datetime :computed_at, null: false

      t.index :model_id
    end
  end
end
