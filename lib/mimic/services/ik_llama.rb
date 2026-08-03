require "json"
require "pathname"
require_relative "../config"
require_relative "../llm_config"
require_relative "../probes"
require_relative "../paths"
require_relative "llama"

module Mimic
  module Services
    class IkLlama
      include Llama::Shared

      LAUNCH_RECORD = Paths::LLM_RUN_DIR / "ik-llama-launch.txt"
      TRACE_LOG_BASE = Paths::LLM_RUN_DIR / "ik_llama"
      CPU_MOE_CACHE = Paths::LLM_ROOT / "ik-n-cpu-moe.json"

      KNOWN_BINARIES = [
        Paths::LLM_ROOT / "ik_llama.cpp/build/bin/llama-server",
      ].freeze

      # Layers offloaded to CPU on each retry after an OOM, and the ceiling
      # we give up at -- generous enough for any current MoE GGUF's layer
      # count.
      CPU_MOE_STEP = 4
      CPU_MOE_MAX = 28

      OOM_MARKERS = ["cudaMalloc failed", "out of memory"].freeze
      KV_OOM_MARKER = "failed to allocate buffer for kv cache"

      class << self
        def load_cache
          JSON.parse(CPU_MOE_CACHE.read)
        rescue SystemCallError, JSON::ParserError
          {}
        end

        def save_cache(model_path, n_cpu_moe)
          cache = load_cache
          cache[model_path] = n_cpu_moe
          Paths::LLM_ROOT.mkpath
          CPU_MOE_CACHE.write(JSON.generate(cache))
        end

        def log_tail
          Llama.log_tail
        end

        def meta_int(tail, key)
          match = tail.match(/^llm_load_print_meta: #{Regexp.escape(key)}\s*= (\d+)$/)
          match && match[1].to_i
        end

        # Why bumping --n-cpu-moe cannot rescue this failure, if it can't.
        #
        # The flag only relocates MoE expert tensors, so it is useless on a
        # dense model and cannot shrink a KV cache. Retrying regardless just
        # reloads the weights until the ceiling, which on a dense model means
        # every attempt is byte-identical to the one that already failed.
        def retry_blocker(tail, n_cpu_moe)
          return "startup failed for a reason other than VRAM" unless OOM_MARKERS.any? { |m| tail.include?(m) }
          return "this model is dense, so it has no experts to offload" if meta_int(tail, "n_expert") == 0

          n_layer = meta_int(tail, "n_layer")
          ceiling = [CPU_MOE_MAX, n_layer || CPU_MOE_MAX].min
          return nil if n_cpu_moe < ceiling

          return "the KV cache does not fit -- lower `model.context_length`" if tail.include?(KV_OOM_MARKER)

          "every layer is already offloaded (ceiling #{ceiling})"
        end
      end

      def initialize(settings)
        @settings = settings
      end

      def find_binary
        return @find_binary if defined?(@find_binary)

        configured = @settings.binary
        @find_binary = if configured && !configured.empty? && File.file?(configured)
                          configured
                        else
                          KNOWN_BINARIES.find(&:file?)&.to_s || Probes.which("llama-server")
                        end
      end

      def render_preset(n_cpu_moe = 0)
        binary = find_binary || "llama-server"
        Paths::LLM_RUN_DIR.mkpath
        LAUNCH_RECORD.write("#{build_command(binary, n_cpu_moe).join(' ')}\n")
        LAUNCH_RECORD
      end

      def start(remember: true)
        return Result.ok("ik_llama server already running") if Llama.new(@settings).running?

        binary = find_binary
        return Result.error("ik_llama llama-server not found -- run `mimic setup`") if binary.nil?

        model_path = @settings.model_path
        if model_path.to_s.empty? || !File.file?(model_path)
          return Result.error("GGUF model not found: #{model_path.to_s.empty? ? '<unset>' : model_path} -- run `mimic setup`")
        end

        if mtp_enabled?
          puts "[ik_llama] MTP requested but not yet wired for ik_llama -- starting without it"
        end

        n_cpu_moe = self.class.load_cache.fetch(model_path, 0)
        loop do
          puts "[ik_llama] offloading MoE experts of first #{n_cpu_moe} layers to CPU" if n_cpu_moe.positive?
          pid = launch(binary, n_cpu_moe)
          if Probes.wait_ready(Llama.new(@settings).models_url, alive: -> { Probes.child_alive?(pid) }, label: "waiting for ik_llama server")
            self.class.save_cache(model_path, n_cpu_moe)
            @settings.remember_ctx if remember
            return Result.ok("ik_llama server ready (pid #{pid})")
          end

          tail = self.class.log_tail
          blocker = self.class.retry_blocker(tail, n_cpu_moe)
          Llama.cleanup_failed(pid)
          if blocker
            return Result.error("ik_llama server failed to start -- #{blocker}. See #{Llama::LOG_FILE}\n#{Llama.last_lines(tail)}")
          end
          ceiling = [CPU_MOE_MAX, self.class.meta_int(tail, "n_layer") || CPU_MOE_MAX].min
          n_cpu_moe = [n_cpu_moe + CPU_MOE_STEP, ceiling].min
        end
      end

      private

      def build_command(binary, n_cpu_moe = 0)
        cmd = [
          binary,
          "-m", @settings.model_path,
          "-a", model_alias,
          "-c", @settings.context_length.to_s,
          "-fa", @settings.flash_attn,
          "-ctk", @settings.cache_type,
          "-ctv", @settings.cache_type,
          "-ngl", "999",
          "-ub", "1024",
          "--jinja",
          "-cram", "2048",
          "-np", @settings.n_slots.to_s,
          "--temp", @settings.temperature.to_s,
          "--top-p", @settings.top_p.to_s,
          "--top-k", @settings.top_k.to_s,
          "--min-p", @settings.min_p.to_s,
          "--presence-penalty", @settings.presence_penalty.to_s,
          "--repeat-penalty", @settings.repeat_penalty.to_s,
          "--host", @settings.host,
          "--port", @settings.port.to_s,
          "--metrics",
          # ik_llama's logger (llama.cpp's pre-revamp common/log.h)
          # otherwise writes a bare "llama.log" into the cwd. Name it for
          # the engine and put it beside the server log. Takes a path
          # without the extension.
          "--log-file", TRACE_LOG_BASE.to_s,
        ]
        override = chat_template_override
        cmd += ["--chat-template-file", override.to_s] if override
        cmd += ["--n-cpu-moe", n_cpu_moe.to_s] if n_cpu_moe.positive?
        cmd
      end

      def launch(binary, n_cpu_moe)
        render_preset(n_cpu_moe)
        Paths::PID_DIR.mkpath
        log = File.open(Llama::LOG_FILE, "ab")
        begin
          pid = Process.spawn(*build_command(binary, n_cpu_moe), out: log, err: log,
                               chdir: Paths::LLM_RUN_DIR.to_s, pgroup: true)
        ensure
          log.close
        end
        Llama::PID_FILE.write(pid.to_s)
        pid
      end
    end
  end
end
