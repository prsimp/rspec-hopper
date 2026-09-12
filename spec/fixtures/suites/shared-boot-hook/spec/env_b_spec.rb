# frozen_string_literal: true

RSpec.describe "TEST_ENV_NUMBER via after_fork (b)" do
  it "matches the value re-derived by the hook" do
    EnvCapture.record(__FILE__, "load" => EnvCapture::LOADED, "derived" => EnvCapture.derived, "run" => EnvCapture.current)
    expect(EnvCapture.derived).to eq(EnvCapture.current)
  end
end
