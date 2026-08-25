require "pathname"
require "timeout"
require_relative "chat_template"
require_relative "../llm_config"
require_relative "../paths"
require_relative "../util/probes"
require_relative "../result"
require_relative "../model/vram"
require_relative "launcher"
require_relative "../engine_cli/registry"

module Mimic
  module Engine
    # What every engine shares: one llama-server process, one log, one pid
    # file, and the model-side preparation each of them has to do before
    # spawning it. Subclasses supply the argv and the readiness protocol.
    class Base
      # The metadata block sits ~9 KB above a startup failure line, so the
      # tail has to reach back far enough to still see n_expert / n_layer.
      LOG_TAIL_BYTES = 64_000

      class << self
        # Methods rather than constants: Ruby resolves a constant lexically,
        # so an inherited reader would name the chat server's log whichever
        # subclass called it.
        def log_file = Paths::LLM_RUN_DIR / "llama-server.log"
        def pid_file = Paths::PID_DIR / "llama-server.pid"

        # Whether a /proc scan for the binary is an acceptable second way to
        # find this server's pid.
        def proc_scan_fallback? = true

        def log_tail(offset = 0)
          text = log_file.binread.force_encoding(Encoding::UTF_8).scrub
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

        def cleanup_failed(pid, pid_file: self.pid_file)
          pid_file.unlink if pid_file.exist?
          return unless Util::Probes.child_alive?(pid)

          Process.kill("TERM", -pid)
          Timeout.timeout(10) { Process.waitpid(pid) }
        rescue Timeout::Error
          Process.kill("KILL", -pid)
          Process.waitpid(pid)
        rescue Errno::ECHILD
          nil
        end

        def stop(exclude: [])
          Util::Probes.stop_pid(pid_file, "llama-server", exclude: exclude, fallback: proc_scan_fallback?)
        end
      end

      def initialize(settings)
        @settings = settings
      end

      def models_url = "#{@settings.llama.base_url}/v1/models"
      def running? = Util::Probes.http_ok(models_url)

      def find_binary
        @find_binary ||= first_existing(@settings.llama.binary, EngineCli::Registry.binaries(@settings.llama.engine))
      end

      def live_args = raise(NotImplementedError)
      def render_preset = raise(NotImplementedError)
      def start(**) = raise(NotImplementedError)

      private

      def launcher
        Engine::Launcher.new(log_file: self.class.log_file, pid_file: self.class.pid_file, chdir: Paths::LLM_RUN_DIR)
      end

      def first_existing(*candidates)
        candidates.flatten.compact.map(&:to_s).reject(&:empty?).find { |c| File.file?(c) }
      end

      def model_alias
        @model_alias ||= @settings.model.name
      end

      def chat_template
        @chat_template ||= Engine::ChatTemplate.new(@settings.model.path, model_alias: model_alias)
      end

      def chat_template_override = chat_template.override_path

      def ensure_chat_template
        return if @chat_template_ensured

        @chat_template_ensured = true
        return unless chat_template.guarded?

        installed = chat_template.install
        return puts "[chat-template] #{model_alias} ships a template that can throw -- using #{installed}" if installed
        return unless chat_template.override_path.nil?

        puts "[chat-template] #{model_alias}'s template carries a guard mimic has no rule for -- " \
             "requests may fail; hand-write #{Paths::CHAT_TEMPLATES_DIR}/#{model_alias}.jinja"
      end

      def report_template_failures
        failures = Engine::ChatTemplate::Probe.new(@settings.llama.base_url, model_alias: model_alias).failures
        return if failures.empty?

        puts "[chat-template] #{model_alias} cannot render #{failures.join(', ')} -- " \
             "those requests will fail; see #{Paths::CHAT_TEMPLATES_DIR}"
      end

      # What this launch actually cost beyond the weights + KV estimate,
      # kept so the next preflight budgets against a measurement instead of
      # Model::Vram.compute_default. Router mode loads the model in a child, so the
      # descendants carry the VRAM the spawned pid does not.
      def record_compute(pid)
        pids = [pid, *Util::Probes.descendants(pid)]
        overhead = Model::Vram.measured_overhead_mib(@settings.model.path, @settings.model.context_length,
                                              @settings.llama.cache_type, pids: pids)
        return if overhead.nil?

        @settings.model.file.remember_compute(@settings.model.context_length, @settings.llama.cache_type, overhead)
      end

      def mtp_enabled?
        mode = @settings.model.mtp.to_s.downcase
        return true if %w[on true 1].include?(mode)
        return false if %w[off false 0].include?(mode)

        Base.supports_mtp?(@settings.model.path)
      end

      def model_missing
        model_path = @settings.model.path
        return nil unless model_path.to_s.empty? || !File.file?(model_path)

        "GGUF model not found: #{model_path.to_s.empty? ? '<unset>' : model_path} -- run `mimic setup`"
      end
    end
  end
end
