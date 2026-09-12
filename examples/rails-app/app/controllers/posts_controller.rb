# frozen_string_literal: true

class PostsController < ApplicationController
  def index
    render json: Post.order(:id).pluck(:id, :title).map { |id, title| { id: id, title: title } }
  end

  def show
    post = Post.find(params[:id])
    render json: { id: post.id, title: post.title, comments: post.comments.order(:id).pluck(:body) }
  end
end
