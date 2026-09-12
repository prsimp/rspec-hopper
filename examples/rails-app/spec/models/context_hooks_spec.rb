# frozen_string_literal: true

# Records created in before(:all) live outside the per-example transaction,
# so the after(:all) cleanup has to run for every unit that ran the hook:
# once per file with file units, once per example with example units.
# rubocop:disable-next RSpec/BeforeAfterAll, RSpec/InstanceVariable
RSpec.describe "before(:all) records" do
  before(:all) do
    @posts = Array.new(3) { |i| Post.create!(title: "Seeded #{i}") }
  end

  after(:all) do
    Post.where(id: @posts.map(&:id)).destroy_all
  end

  it "sees the seeded posts" do
    expect(Post.where(id: @posts.map(&:id)).count).to eq(3)
  end

  it "can add to them inside the example transaction" do
    Post.create!(title: "Transient")
    expect(Post.count).to eq(4)
  end
end
