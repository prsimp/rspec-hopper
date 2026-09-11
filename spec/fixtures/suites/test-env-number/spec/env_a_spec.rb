# frozen_string_literal: true

RSpec.describe "TEST_ENV_NUMBER (a)" do
  it "is the same at load time and run time" do
    EnvCapture.record(__FILE__, "load" => EnvCapture::LOADED, "run" => EnvCapture.current)
    expect(EnvCapture.current).to eq(EnvCapture::LOADED)
  end
end
