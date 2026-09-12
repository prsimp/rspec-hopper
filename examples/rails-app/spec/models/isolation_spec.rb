# frozen_string_literal: true

# Passes only if every other example's data was rolled back or cleaned up in
# this process's database, whichever process and unit order ran them.
RSpec.describe "database isolation" do
  it "starts from an empty posts table" do
    expect(Post.count).to eq(0)
  end

  it "starts from an empty comments table" do
    expect(Comment.count).to eq(0)
  end
end
