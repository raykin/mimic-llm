require_relative "../lib/mimic"
require_relative "../lib/mimic/host"

RSpec.describe Mimic::Host do
  describe ".build_jobs" do
    it "never returns fewer than 2 jobs" do
      allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:       1000000 kB\n"])
      allow(Etc).to receive(:nprocessors).and_return(8)
      expect(described_class.build_jobs).to be >= 2
    end

    it "caps jobs at the CPU count" do
      allow(File).to receive(:readlines).with("/proc/meminfo").and_return(["MemTotal:  200000000 kB\n"])
      allow(Etc).to receive(:nprocessors).and_return(4)
      expect(described_class.build_jobs).to eq(4)
    end
  end

  describe ".backend" do
    it "prefers cuda when nvidia-smi is present" do
      allow(Mimic::Probes).to receive(:which).with("nvidia-smi").and_return("/usr/bin/nvidia-smi")
      expect(described_class.backend).to eq("cuda")
    end

    it "falls back to cpu when no GPU tooling is found" do
      allow(Mimic::Probes).to receive(:which).and_return(nil)
      expect(described_class.backend).to eq("cpu") unless Pathname.new("/dev/kfd").exist?
    end
  end

  describe ".llama_server" do
    it "finds a built llama.cpp binary even when nothing is on PATH" do
      allow(Mimic::Probes).to receive(:which).with("llama-server").and_return(nil)
      known = Mimic::Services::Llama::KNOWN_BINARIES.first
      allow(known).to receive(:file?).and_return(true)
      expect(described_class.llama_server).to eq(known.to_s)
    end

    it "falls back to a built ik_llama.cpp binary" do
      allow(Mimic::Probes).to receive(:which).with("llama-server").and_return(nil)
      allow(Mimic::Services::Llama::KNOWN_BINARIES.first).to receive(:file?).and_return(false)
      known = Mimic::Services::IkLlama::KNOWN_BINARIES.first
      allow(known).to receive(:file?).and_return(true)
      expect(described_class.llama_server).to eq(known.to_s)
    end

    it "returns nil when nothing is found anywhere" do
      allow(Mimic::Probes).to receive(:which).with("llama-server").and_return(nil)
      allow(Mimic::Services::Llama::KNOWN_BINARIES.first).to receive(:file?).and_return(false)
      allow(Mimic::Services::IkLlama::KNOWN_BINARIES.first).to receive(:file?).and_return(false)
      expect(described_class.llama_server).to be_nil
    end
  end
end
