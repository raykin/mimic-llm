require_relative "../../lib/mimic"

RSpec.describe Mimic::Engine::ChatTemplate::Probe do
  subject(:probe) { described_class.new("http://localhost:8080", model_alias: "TestModel") }

  def response(code, body = "{}")
    instance_double(Net::HTTPResponse, code: code.to_s, body: body)
  end

  it "reports nothing when every fixture renders" do
    allow(Mimic::Util::Probes).to receive(:post).and_return(response(200))

    expect(probe.failures).to be_empty
  end

  it "names the fixture the template rejected" do
    allow(Mimic::Util::Probes).to receive(:post) do |_url, body|
      body[:messages].count { |m| m[:role] == "system" } > 1 ? response(500, "must be at the beginning") : response(200)
    end

    expect(probe.failures).to eq(["a system message after the first turn"])
  end

  it "sends the model alias so a router picks the right instance" do
    allow(Mimic::Util::Probes).to receive(:post).and_return(response(200))
    probe.failures

    expect(Mimic::Util::Probes).to have_received(:post)
      .with("http://localhost:8080/apply-template", hash_including(model: "TestModel"))
      .at_least(:once)
  end

  it "stays quiet when the server has no /apply-template" do
    allow(Mimic::Util::Probes).to receive(:post).and_return(response(404))

    expect(probe.failures).to be_empty
  end

  it "stays quiet when the server cannot be reached" do
    allow(Mimic::Util::Probes).to receive(:post).and_return(nil)

    expect(probe.failures).to be_empty
  end
end
