# frozen_string_literal: true

# Fails on its first attempt in a run and passes from the second, counting
# attempts in a file shared by every worker process. Whatever it wrote before
# failing must have been rolled back before the retry. Under plain `rspec`,
# which does not retry, it skips itself.
RSpec.describe "a flaky example" do
  def next_attempt
    counter = Rails.root.join("tmp/flaky-attempts")
    FileUtils.mkdir_p(counter.dirname)
    File.open(counter, File::RDWR | File::CREAT, 0o644) do |f|
      f.flock(File::LOCK_EX)
      count = f.read.to_i + 1
      f.rewind
      f.truncate(0)
      f.write(count.to_s)
      count
    end
  end

  it "passes from the second attempt with a clean table" do
    skip "only meaningful under rspec-hopper, which retries it" unless File.basename($PROGRAM_NAME) == "rspec-hopper"

    expect(Post.count).to eq(0)
    Post.create!(title: "Written by attempt")
    attempt = next_attempt
    expect(attempt).to be >= 2, "attempt #{attempt} fails on purpose"
  end
end
