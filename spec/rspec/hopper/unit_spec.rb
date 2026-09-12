# frozen_string_literal: true

RSpec.describe RSpec::Hopper::Unit do
  it "builds file and example units" do
    file = described_class.file("./spec/a_spec.rb")
    example = described_class.example("./spec/a_spec.rb[1:2]")
    expect(file).to have_attributes(id: "./spec/a_spec.rb", type: "file", file?: true, example?: false)
    expect(example).to have_attributes(id: "./spec/a_spec.rb[1:2]", type: "example", file?: false, example?: true)
    expect(example.to_h).to eq("id" => "./spec/a_spec.rb[1:2]", "type" => "example")
  end

  it "rejects an unknown type" do
    expect { described_class.new(id: "x", type: "group") }
      .to raise_error(ArgumentError, /unknown unit type "group"; expected one of file, example/)
  end
end
