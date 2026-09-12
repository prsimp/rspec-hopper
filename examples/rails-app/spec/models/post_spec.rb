# frozen_string_literal: true

RSpec.describe Post do
  it "requires a title" do
    expect(described_class.new).not_to be_valid
    expect(described_class.new(title: "Hello")).to be_valid
  end

  it "destroys its comments with it" do
    post = described_class.create!(title: "With comments")
    post.comments.create!(body: "first")
    expect { post.destroy! }.to change(Comment, :count).by(-1)
  end

  it "finds posts by title fragment" do
    described_class.create!(title: "Hopper feeds the machine")
    described_class.create!(title: "Unrelated")
    expect(described_class.titled_like("machine").pluck(:title)).to eq(["Hopper feeds the machine"])
  end
end
