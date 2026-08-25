require_relative "../../lib/mimic"
require_relative "../../lib/mimic/util/host"

RSpec.describe Mimic::Util::Host do
  describe ".build_jobs" do
    it "never returns fewer than 2 jobs" do
      allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:       1000000 kB\n"])
      allow(Etc).to receive(:nprocessors).and_return(8)
      expect(described_class.build_jobs).to be >= 2
    end

    it "caps jobs by RAM, not just by CPU count" do
      allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:   41943040 kB\n"])
      allow(Etc).to receive(:nprocessors).and_return(20)
      expect(described_class.build_jobs).to eq(8)
    end

    it "caps jobs at the CPU count" do
      allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:  200000000 kB\n"])
      allow(Etc).to receive(:nprocessors).and_return(4)
      expect(described_class.build_jobs).to eq(4)
    end
  end

  describe ".backend" do
    it "prefers cuda when nvidia-smi is present" do
      allow(Mimic::Util::Probes).to receive(:which).with("nvidia-smi").and_return("/usr/bin/nvidia-smi")
      expect(described_class.backend).to eq("cuda")
    end

    it "falls back to cpu when no GPU tooling is found" do
      allow(Mimic::Util::Probes).to receive(:which).and_return(nil)
      expect(described_class.backend).to eq("cpu") unless Pathname.new("/dev/kfd").exist?
    end
  end

  describe ".llama_server" do
    def build_path(engine) = Mimic::EngineCli::Registry.builds(engine).first.to_s

    def only_existing(path)
      allow(File).to receive(:file?).and_return(false)
      allow(File).to receive(:file?).with(path).and_return(true) if path
    end

    it "finds a built llama.cpp binary even when nothing is on PATH" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return(nil)
      wanted = build_path("llama.cpp")
      only_existing(wanted)

      expect(described_class.llama_server).to eq(wanted)
    end

    it "falls back to a built ik_llama.cpp binary" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return(nil)
      wanted = build_path("ik_llama.cpp")
      only_existing(wanted)

      expect(described_class.llama_server).to eq(wanted)
    end

    it "returns nil when nothing is found anywhere" do
      allow(Mimic::Util::Probes).to receive(:which).with("llama-server").and_return(nil)
      only_existing(nil)

      expect(described_class.llama_server).to be_nil
    end
  end
end
