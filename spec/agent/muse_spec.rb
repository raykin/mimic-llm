require "json"
require "tmpdir"
require_relative "../../lib/mimic"
require_relative "../../lib/mimic/agent"

RSpec.describe Mimic::Agent::Muse do
  let(:settings) do
    instance_double(
      Mimic::LlmConfig::Settings,
      model: instance_double(Mimic::LlmConfig::ModelSettings, name: "m", context_length: 65_536),
      llama: instance_double(Mimic::LlmConfig::LlamaSettings, base_url: "http://x"),
    )
  end
  subject(:agent) { described_class.new(settings) }

  let(:root) { Pathname.new(Dir.mktmpdir) }
  let(:home) { root / "agents/muse" }
  let(:written) { JSON.parse((home / "muse/settings.json").read) }

  before do
    stub_const("Mimic::Paths::AGENTS_DIR", root / "agents")
    allow(Mimic::Util::Probes).to receive(:which).with("muse").and_return("/usr/bin/muse")
    allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(0)
  end

  after { root.rmtree }

  describe "#launch" do
    it "aborts when muse isn't installed" do
      allow(Mimic::Util::Probes).to receive(:which).with("muse").and_return(nil)
      expect do
        expect { agent.launch([]) }
          .to raise_error(SystemExit) { |e| expect(e.status).to eq(1) }
      end.to output(/muse binary not found/).to_stderr
    end

    it "runs muse against a config root of its own so the user's install stays pointed at Meta" do
      agent.launch(["--resume"])

      expect(Mimic::Agent).to have_received(:spawn_and_wait)
        .with(["muse", "--resume"], { "XDG_CONFIG_HOME" => home.to_s })
    end

    it "points the transport at llama-server's /v1 with no credential" do
      agent.launch([])

      expect(written["provider"]).to eq("meta")
      expect(written["model"]).to eq("m")
      expect(written["endpoint_transport"]).to eq("base_url" => "http://x/v1", "auth" => "none")
    end

    # Without a catalog row muse fetches <origin>/muse-code/models, which
    # llama-server 404s, and aborts before the first inference call.
    it "writes a catalog row muse's session profile accepts" do
      agent.launch([])

      expect(written["model_catalog"]).to eq(
        [{ "model_id" => "m", "provider_id" => "meta", "profile_id" => "tbh",
           "display_label" => "m", "visibility" => "visible", "display_order" => 0,
           "is_default" => true, "context_limit" => 65_536, "output_limit" => 32_768,
           "description" => "Served by llama.cpp" }],
      )
    end

    it "keeps settings muse persisted for itself" do
      (home / "muse").mkpath
      (home / "muse/settings.json").write(JSON.generate("theme" => "dark", "provider" => "meta"))

      agent.launch([])

      expect(written["theme"]).to eq("dark")
    end

    it "raises the agent's own exit status" do
      allow(Mimic::Agent).to receive(:spawn_and_wait).and_return(3)

      expect { agent.launch([]) }.to raise_error(SystemExit) { |e| expect(e.status).to eq(3) }
    end
  end
end
