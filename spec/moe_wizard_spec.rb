require_relative "../lib/mimic"
require_relative "../lib/mimic/moe_wizard"
require "tmpdir"
require "fileutils"

RSpec.describe Mimic::MoeWizard do
  def wizard(scan, prompt: instance_double(TTY::Prompt))
    described_class.new(scan, prompt: prompt, pastel: Pastel.new)
  end

  describe "#run" do
    it "offers only MoE models, deduped by realpath" do
      Dir.mktmpdir do |dir|
        root = Pathname.new(dir)
        moe = root / "moe.gguf"
        dense = root / "dense.gguf"
        FileUtils.touch(moe)
        FileUtils.touch(dense)
        allow(Mimic::Vram).to receive(:moe?) { |path| path == moe.realpath.to_s }
        allow(Mimic::Services::IkLlama).to receive(:load_cache).and_return({})
        prompt = instance_double(TTY::Prompt)
        allow(prompt).to receive(:select).and_return(moe.realpath.to_s, :cancel)

        expect { wizard([[moe, root], [dense, root]], prompt: prompt).run }.to output.to_stdout

        expect(prompt).to have_received(:select).with("MoE model:", { "moe.gguf" => moe.realpath.to_s })
      end
    end

    it "rejects a value above the model's layer ceiling" do
      allow(Mimic::Vram).to receive_messages(moe?: true, block_count: 10)
      allow(Mimic::Services::IkLlama).to receive(:load_cache).and_return({})
      prompt = instance_double(TTY::Prompt, ask: 99)
      allow(prompt).to receive(:select).and_return("/m.gguf", :set)

      expect { wizard(scan_of("/m.gguf"), prompt: prompt).run }.to raise_error(SystemExit)
    end

    it "caches a value within range" do
      Dir.mktmpdir do |dir|
        cache_file = Pathname.new(dir) / "ik-n-cpu-moe.json"
        stub_const("Mimic::Services::IkLlama::CPU_MOE_CACHE", cache_file)
        allow(Mimic::Vram).to receive_messages(moe?: true, block_count: 10)

        prompt = instance_double(TTY::Prompt, ask: 4)
        allow(prompt).to receive(:select).and_return("/m.gguf", :set)

        expect { wizard(scan_of("/m.gguf"), prompt: prompt).run }.to output.to_stdout

        expect(JSON.parse(cache_file.read)).to eq("/m.gguf" => 4)
      end
    end

    it "reports when no MoE model was found" do
      expect { wizard([]).run }.to output(/No MoE .gguf models found/).to_stdout
    end
  end

  # A scan entry whose realpath is the given path, without touching the disk.
  def scan_of(path)
    [[instance_double(Pathname, realpath: Pathname.new(path)), Pathname.new("/")]]
  end
end
