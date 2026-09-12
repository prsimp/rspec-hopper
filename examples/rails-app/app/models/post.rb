# frozen_string_literal: true

class Post < ApplicationRecord
  has_many :comments, dependent: :destroy

  validates :title, presence: true

  scope :titled_like, ->(fragment) { where("title LIKE ?", "%#{sanitize_sql_like(fragment)}%") }
end
