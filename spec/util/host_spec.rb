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
  # nvidia-smi is the only source for these; a box without it answers nil
  # rather than raising, since every caller treats "no GPU" as unknowable.
  describe ".gpu_total_mib" do
    def smi(output, success:)
      allow(Open3).to receive(:capture2).and_return([output, instance_double(Process::Status, success?: success)])
    end

    it "reads the card's total memory in MiB" do
      smi("24576\n", success: true)

      expect(described_class.gpu_total_mib).to eq(24_576)
    end

    it "is nil when nvidia-smi fails" do
      smi("", success: false)

      expect(described_class.gpu_total_mib).to be_nil
    end

    it "is nil when nvidia-smi is not installed" do
      allow(Open3).to receive(:capture2).and_raise(Errno::ENOENT)

      expect(described_class.gpu_total_mib).to be_nil
    end

    it "is nil when the output is not a number" do
      smi("[N/A]\n", success: true)

      expect(described_class.gpu_total_mib).to be_nil
    end
  end

  describe ".gpu_process_mib" do
    def compute_apps(output)
      allow(Open3).to receive(:capture2).and_return([output, instance_double(Process::Status, success?: true)])
    end

    # The engine that owns the CUDA context is not always the process we
    # spawned -- llama.cpp's router loads each model in a child -- so every
    # listed pid counts.
    it "sums the VRAM held by every listed pid" do
      compute_apps("41, 100\n42, 250\n99, 900\n")

      expect(described_class.gpu_process_mib([41, 42])).to eq(350)
    end

    it "is nil when none of the pids is on the GPU" do
      compute_apps("99, 900\n")

      expect(described_class.gpu_process_mib([42])).to be_nil
    end

    it "is nil when nvidia-smi fails" do
      allow(Open3).to receive(:capture2).and_return(["", instance_double(Process::Status, success?: false)])

      expect(described_class.gpu_process_mib([42])).to be_nil
    end
  end
end
