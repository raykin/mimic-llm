require_relative "../../lib/mimic"

RSpec.describe Mimic::Engine::Router do
  subject(:router) { described_class.new("http://127.0.0.1:8080") }

  def model(id, status, port: 49_643)
    { "id" => id, "status" => { "value" => status, "args" => ["llama-server", "--port", port.to_s, "--alias", id] } }
  end

  def stub_models(*models)
    allow(Mimic::Util::Probes).to receive(:http_json)
      .with("http://127.0.0.1:8080/models", timeout: 3).and_return("data" => models)
  end

  describe "#running" do
    # The router's status is an object, not a string, and a sleeping child
    # still counts as running: the router refuses to unload anything else.
    it "lists the loaded, loading and sleeping models with their child ports" do
      stub_models(model("a", "loaded", port: 1), model("b", "unloaded"), model("c", "loading", port: 3),
                  model("d", "sleeping", port: 4))

      expect(router.running.map { |m| [m.id, m.port] }).to eq([["a", 1], ["c", 3], ["d", 4]])
    end

    it "is nil when the router does not answer" do
      allow(Mimic::Util::Probes).to receive(:http_json).and_return(nil)

      expect(router.running).to be_nil
    end
  end

  describe "#busy?" do
    let(:child) { described_class::Child.new("a", 49_643) }

    it "is true while a slot is processing a request" do
      allow(Mimic::Util::Probes).to receive(:http_json).with("http://127.0.0.1:49643/slots", timeout: 3)
        .and_return([{ "id" => 0, "is_processing" => false }, { "id" => 1, "is_processing" => true }])

      expect(router.busy?(child)).to be true
    end

    it "is false when every slot is idle" do
      allow(Mimic::Util::Probes).to receive(:http_json).and_return([{ "id" => 0, "is_processing" => false }])

      expect(router.busy?(child)).to be false
    end

    # A child still loading has no slots endpoint and no request to cut off.
    it "is false when the child does not answer" do
      allow(Mimic::Util::Probes).to receive(:http_json).and_return(nil)

      expect(router.busy?(child)).to be false
    end
  end

  describe "#unload" do
    it "posts the model id to the router's unload route" do
      allow(Mimic::Util::Probes).to receive(:post).and_return(Net::HTTPOK.new("1.1", "200", "OK"))

      expect(router.unload("a")).to be true
      expect(Mimic::Util::Probes).to have_received(:post)
        .with("http://127.0.0.1:8080/models/unload", { "model" => "a" })
    end

    it "is false when the router refuses" do
      allow(Mimic::Util::Probes).to receive(:post).and_return(Net::HTTPBadRequest.new("1.1", "400", "Bad"))

      expect(router.unload("a")).to be false
    end
  end
end
