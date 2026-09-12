# frozen_string_literal: true

ActiveRecord::Schema.define(version: 1) do
  create_table "posts", force: :cascade do |t|
    t.string "title", null: false
    t.timestamps
  end

  create_table "comments", force: :cascade do |t|
    t.references "post", null: false, foreign_key: true
    t.text "body", null: false
    t.timestamps
  end
end
