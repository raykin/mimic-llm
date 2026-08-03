require "pathname"
require "etc"
require "timeout"
require_relative "../config"
require_relative "../llm_config"
require_relative "../probes"
require_relative "../paths"

module Mimic
  module Services
    class Llama
      LOG_FILE = Paths::LLM_RUN_DIR / "llama-server.log"
      PID_FILE = Paths::PID_DIR / "llama-server.pid"
      PRESET_FILE = Paths::LLM_RUN_DIR / "llama-models.ini"

      KNOWN_BINARIES = [
        Paths::LLM_ROOT / "llama.cpp/build/bin/llama-server",
        Pathname.new(Dir.home) / ".local/bin/llama-server",
      ].freeze

      # The metadata block sits ~9 KB above a startup failure line, so the
      # tail has to reach back far enough to still see n_expert / n_layer.
      LOG_TAIL_BYTES = 64_000

      module Shared
        private

        def model_alias
          @model_alias ||= @settings.model_alias
        end

        def chat_template_override
          candidate = Paths::CHAT_TEMPLATES_DIR / "#{model_alias}.jinja"
          candidate.file? ? candidate : nil
        end

        def mtp_enabled?
          mode = @settings.mtp.to_s.downcase
          return true if %w[on true 1].include?(mode)
          return false if %w[off false 0].include?(mode)

          Llama.supports_mtp?(@settings.model_path)
        end
      end

      include Shared

      class << self
        def log_tail(offset = 0)
          text = LOG_FILE.binread.force_encoding(Encoding::UTF_8).scrub
          text = text[offset..] || "" if offset.positive?
          text[-LOG_TAIL_BYTES..] || text
        rescue SystemCallError
          ""
        end

        def last_lines(text, n = 4)
          text.strip.lines.last(n).join
        end

        # MTP-capable GGUFs carry a *.nextn_predict_layers metadata key in the header.
        def supports_mtp?(model_path)
          File.open(model_path, "rb") { |f| f.read(8_000_000).to_s.include?("nextn_predict_layers") }
        rescue SystemCallError, IOError
          false
        end

        def cleanup_failed(pid)
          PID_FILE.unlink if PID_FILE.exist?
          return unless Probes.child_alive?(pid)

          Process.kill("TERM", -pid)
          Timeout.timeout(10) { Process.waitpid(pid) }
        rescue Timeout::Error
          Process.kill("KILL", -pid)
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end

        def stop
          Probes.stop_pid(PID_FILE, "llama-server")
        end
      end

      def initialize(settings)
        @settings = settings
      end

      def models_url = "#{@settings.base_url}/v1/models"
      def running? = Probes.http_ok(models_url)

      def find_binary
        return @find_binary if defined?(@find_binary)

        configured = @settings.binary
        @find_binary = if configured && !configured.empty? && File.file?(configured)
                          configured
                        else
                          Probes.which("llama-server") || KNOWN_BINARIES.find(&:file?)&.to_s
                        end
      end

      def render_preset
        entries = {
          "model" => @settings.model_path,
          "ctx-size" => @settings.context_length,
          # All-GPU or nothing. Without this llama.cpp auto-fit silently
          # moves tensors to CPU to make an oversized ctx boot, and the
          # resulting PCIe traffic per ubatch costs more than the run is
          # worth. ik is the engine for deliberate CPU-MoE offload; here a
          # model that doesn't fit should fail at load.
          "n-gpu-layers" => 999,
          "flash-attn" => @settings.flash_attn,
          "ubatch-size" => 1024,
          "cache-type-k" => @settings.cache_type,
          "cache-type-v" => @settings.cache_type,
          "threads" => Etc.nprocessors || 4,
          "parallel" => @settings.n_slots,
          "temp" => @settings.temperature,
          "top-p" => @settings.top_p,
          "top-k" => @settings.top_k,
          "min-p" => @settings.min_p,
          "presence-penalty" => @settings.presence_penalty,
          "repeat-penalty" => @settings.repeat_penalty,
          "load-on-startup" => "true",
        }
        override = chat_template_override
        entries["chat-template-file"] = override.to_s if override
        if mtp_enabled?
          entries["spec-type"] = "draft-mtp"
          entries["spec-draft-n-max"] = 2
        end
        # `version` must sit under the global `[*]` section: keys above the
        # first section head become a preset literally named "default"
        # (preset.cpp maps the empty section name to
        # COMMON_PRESET_DEFAULT_NAME), and since the parser then skips
        # `version` that preset carries no model. The router advertises it
        # in /v1/models and, when a client picks it, spawns a model-less
        # child that never finishes loading.
        lines = ["[*]", "version = 1", "", "[#{model_alias}]"]
        lines += entries.map { |k, v| "#{k} = #{v}" }
        Paths::LLM_RUN_DIR.mkpath
        PRESET_FILE.write("#{lines.join("\n")}\n")
        PRESET_FILE
      end

      def start(remember: true)
        return Result.ok("llama-server already running") if running?

        binary = find_binary
        return Result.error("llama-server binary not found -- run `mimic setup`") if binary.nil?

        model_path = @settings.model_path
        if model_path.to_s.empty? || !File.file?(model_path)
          return Result.error("GGUF model not found: #{model_path.to_s.empty? ? '<unset>' : model_path} -- run `mimic setup`")
        end

        render_preset
        Paths::PID_DIR.mkpath
        log_offset = LOG_FILE.exist? ? LOG_FILE.size : 0
        log = File.open(LOG_FILE, "ab")
        begin
          pid = Process.spawn(*build_command(binary), out: log, err: log,
                               chdir: Paths::LLM_RUN_DIR.to_s, pgroup: true)
        ensure
          log.close
        end
        PID_FILE.write(pid.to_s)

        unless Probes.wait_ready(models_url, alive: -> { Probes.child_alive?(pid) }, label: "waiting for llama-server")
          self.class.cleanup_failed(pid)
          return Result.error("llama-server failed to start -- see #{LOG_FILE}\n#{self.class.last_lines(self.class.log_tail(log_offset))}")
        end

        failure = []
        instance_failed = lambda do
          reason = instance_failure(log_offset)
          failure << reason if reason
          !reason.nil?
        end

        if Probes.wait_until(attempts: 120, alive: -> { Probes.child_alive?(pid) },
                              label: "loading model", abort: instance_failed) { model_loaded? }
          @settings.remember_ctx if remember
          return Result.ok("llama-server ready, model loaded (pid #{pid})")
        end

        self.class.cleanup_failed(pid)
        tail = self.class.last_lines(self.class.log_tail(log_offset))
        return Result.error("#{failure.first} -- see #{LOG_FILE}\n#{tail}") unless failure.empty?

        Result.error("model failed to load -- see #{LOG_FILE}\n#{tail}")
      end

      private

      def build_command(binary)
        [binary, "--models-preset", PRESET_FILE.to_s, "--host", @settings.host, "--port", @settings.port.to_s, "--metrics"]
      end

      def model_loaded?
        data = Probes.http_json("#{@settings.base_url}/v1/models") || {}
        (data["data"] || []).any? { |entry| entry["id"] == model_alias && entry.dig("status", "value") == "loaded" }
      end

      # Why the router's model instance died, reading only this launch's log.
      #
      # The router survives its children, so a child that OOMs looks
      # identical to one still loading: the poll that checks for it
      # triggers another autoload, and the pair loop until the caller's
      # attempts run out. The child's exit is only ever reported in the
      # shared log.
      def instance_failure(log_offset)
        tail = self.class.log_tail(log_offset)
        return nil unless tail.include?("instance name=#{model_alias} exited with status 1")

        if tail.include?("cudaMalloc failed: out of memory") || tail.include?("failed to allocate")
          return "#{model_alias} ran out of VRAM at #{@settings.context_length} ctx -- lower the context"
        end

        "#{model_alias} instance exited during load"
      end
    end
  end
end
