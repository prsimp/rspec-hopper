# frozen_string_literal: true

RSpec.describe Comment do
  let(:post) { Post.create!(title: "Commented") }

  it "requires a body and a post" do
    expect(described_class.new(post: post)).not_to be_valid
    expect(described_class.new(post: post, body: "text")).to be_valid
    expect(described_class.new(body: "text")).not_to be_valid
  end
end
