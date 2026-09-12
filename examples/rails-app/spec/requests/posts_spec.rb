# frozen_string_literal: true

RSpec.describe "GET /posts" do
  it "lists posts in id order" do
    first = Post.create!(title: "First")
    second = Post.create!(title: "Second")
    get "/posts"
    expect(response).to have_http_status(:ok)
    expect(response.parsed_body).to eq([{ "id" => first.id, "title" => "First" },
                                        { "id" => second.id, "title" => "Second" }])
  end

  it "shows a post with its comments" do
    post = Post.create!(title: "Shown")
    post.comments.create!(body: "one")
    post.comments.create!(body: "two")
    get "/posts/#{post.id}"
    expect(response.parsed_body).to eq("id" => post.id, "title" => "Shown", "comments" => %w[one two])
  end

  it "404s for an unknown post" do
    get "/posts/0"
    expect(response).to have_http_status(:not_found)
  end
end
