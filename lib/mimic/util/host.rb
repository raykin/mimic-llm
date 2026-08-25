require "etc"
require "open3"
require "pathname"
require_relative "probes"
require_relative "../engine_cli/registry"

# Machine facts the wizard reports on and the build path has to respect.
module Mimic
  module Util
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

        def llama_server = EngineCli::Registry.installed_binary

        def gpu_total_mib
          out, status = Open3.capture2("nvidia-smi", "--query-gpu=memory.total", "--format=csv,noheader,nounits")
          return nil unless status.success?

          Integer(out.lines.first.to_s.strip)
        rescue Errno::ENOENT, ArgumentError, TypeError
          nil
        end

        # VRAM held by the given processes. The engine that owns the CUDA
        # context is not always the process we spawned -- llama.cpp's router
        # loads each model in a child -- so the caller passes the whole
        # descendant set and every match counts.
        def gpu_process_mib(pids)
          out, status = Open3.capture2("nvidia-smi", "--query-compute-apps=pid,used_memory",
                                       "--format=csv,noheader,nounits")
          return nil unless status.success?

          wanted = pids.map(&:to_i)
          total = out.lines.filter_map do |line|
            pid, mib = line.split(",").map { |field| field.strip.to_i }
            mib if wanted.include?(pid)
          end.sum
          total.positive? ? total : nil
        rescue Errno::ENOENT, ArgumentError, TypeError
          nil
        end

        private

        def amd? = Pathname.new("/dev/kfd").exist? || Probes.which("rocminfo")
      end
    end
  end
end
