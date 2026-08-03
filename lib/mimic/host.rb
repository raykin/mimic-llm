require "etc"
require "pathname"
require_relative "probes"
require_relative "services/ik_llama"
require_relative "services/llama"

# Machine facts the wizard reports on and the build path has to respect.
module Mimic
  module Host
    class << self
      def total_mem_kb
        File.readlines("/proc/meminfo").each do |line|
          return line.split[1].to_i if line.start_with?("MemTotal")
        end
        0
      end

      def free_home_bytes
        `df -B1 --output=avail #{Dir.home}`.lines[1].to_i
      end

      def backend
        return "cuda" if Probes.which("nvidia-smi")
        return "hip" if amd?

        "cpu"
      end

      # Auto-detect GPU backend for cmake build flags. CPU is built-in by default.
      def gpu_build_flags
        return ["-DGGML_CUDA=on"] if Probes.which("nvcc")
        return ["-DGGML_HIP=on"] if amd?

        []
      end

      # Cap parallel compile jobs by RAM -- unbounded -j OOMs this box and logs out the desktop.
      def build_jobs
        mem_gb = total_mem_kb / 1024 / 1024
        cpu = Etc.nprocessors || 4
        [2, [cpu, [mem_gb / 5, 2].max].min].max
      end

      def llama_server
        Probes.which("llama-server") ||
          Services::Llama::KNOWN_BINARIES.find(&:file?)&.to_s ||
          Services::IkLlama::KNOWN_BINARIES.find(&:file?)&.to_s
      end

      private

      def amd? = Pathname.new("/dev/kfd").exist? || Probes.which("rocminfo")
    end
  end
end
