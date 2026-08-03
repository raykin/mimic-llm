require_relative "../lib/mimic"
require_relative "../lib/mimic/models_table"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::ModelsTable do
  def table(cfg, scan)
    described_class.new(Mimic::LlmConfig::Settings.new(cfg), scan, pastel: Pastel.new)
  end

  describe "#render" do
    it "does not crash when the active model path no longer exists on disk" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        present = root / "present.gguf"
        FileUtils.touch(present)

        stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [root])
        allow(Mimic::LlmConfig).to receive(:recall_ctx).and_return(nil)
        allow(Mimic::Services::IkLlama).to receive(:load_cache).and_return({})
        allow(Mimic::Vram).to receive(:moe?).and_return(nil)

        instance = table({ "model" => { "path" => (root / "gone.gguf").to_s } }, [[present, root]])

        expect { instance.render }.not_to raise_error
      end
    end

    it "reports the search paths when nothing was found" do
      stub_const("Mimic::LlmConfig::BUILTIN_MODEL_DIRS", [Pathname.new("/opt/models")])

      expect { table({}, []).render }.to output(/No .gguf files found.*\/opt\/models/m).to_stdout
    end
  end
end
