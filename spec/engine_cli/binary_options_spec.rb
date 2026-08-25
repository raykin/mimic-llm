require_relative "../../lib/mimic"

RSpec.describe Mimic::EngineCli::BinaryOptions do
  def stub_completion(script)
    allow(Open3).to receive(:capture2e).with("/bin/llama-server", "--completion-bash").and_return([script, nil])
  end

  let(:options) { described_class.new("/bin/llama-server") }

  it "reads the long options out of the completion script" do
    stub_completion(%(_llama_completions() {\n  opts="-c --ctx-size -rea --reasoning"\n}\n))

    expect(options.names).to eq(%w[ctx-size reasoning])
  end

  # PrismML's fork predates --reasoning-effort, and the router rejects the
  # whole preset file over one key its arg table does not carry.
  it "refuses a key the build does not carry" do
    stub_completion(%(opts="-rea --reasoning"))

    expect(options.supports?("reasoning")).to be true
    expect(options.supports?("reasoning-effort")).to be false
  end

  # set_preset_only() options have no CLI form, so no completion list names
  # them -- treating that as absence would strip the router's own keys.
  it "accepts preset-only keys that no completion script lists" do
    stub_completion(%(opts="-rea --reasoning"))

    expect(options.supports?("load-on-startup")).to be true
  end

  it "audits nothing when the binary answers no flag list" do
    stub_completion("")

    expect(options.supports?("anything-at-all")).to be true
  end

  it "audits nothing when the binary cannot be run" do
    allow(Open3).to receive(:capture2e).and_raise(Errno::ENOENT)

    expect(options.supports?("anything-at-all")).to be true
  end
end
