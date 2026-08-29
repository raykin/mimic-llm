require "pathname"
require_relative "chat_template"
require_relative "../llm_config"
require_relative "../paths"
require_relative "../util/probes"
require_relative "../result"
require_relative "../model/footprint"
require_relative "launcher"
require_relative "server_process"
require_relative "../engine_cli/registry"

module Mimic
  module Engine
    # What every engine shares: one llama-server process, one log, one pid
    # file, and the model-side preparation each of them has to do before
    # spawning it. Subclasses supply the argv and the readiness protocol.
    class Base
      PORT_RELEASE_ATTEMPTS = 60

      def initialize(settings)
        @settings = settings
      end

      def process = @process ||= Engine::ServerProcess.chat

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
        Engine::Launcher.new(log_file: process.log_file, pid_file: process.pid_file, chdir: Paths::LLM_RUN_DIR)
      end

      # A departing server stops answering HTTP the moment it starts unloading,
      # but keeps its listening socket for the whole teardown -- so `running?`
      # going false is not permission to bind, and spawning on it dies with
      # "couldn't bind to server socket".
      def await_port_release
        host = @settings.llama.host
        port = @settings.llama.port.to_i
        return true if Util::Probes.port_free?(host, port)

        Util::Probes.wait_until(attempts: PORT_RELEASE_ATTEMPTS, delay: 1,
                                label: "waiting for port #{port} to be released") do
          Util::Probes.port_free?(host, port)
        end
      end

      def port_busy_error(engine)
        Result.error("#{engine} not started -- #{@settings.llama.host}:#{@settings.llama.port} " \
                     "is still held by another process")
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
      # Model::Footprint.compute_default. Router mode loads the model in a child, so
      # the descendants carry the VRAM the spawned pid does not.
      def record_compute(pid)
        pids = [pid, *Util::Probes.descendants(pid)]
        estimate = @settings.model.file.footprint(@settings.model.context_length, @settings.llama.cache_type,
                                                  compute_mib: 0, slots: @settings.llama.n_slots,
                                                  mmproj_path: @settings.model.mmproj_path)
        overhead = estimate.measured_overhead_mib(pids: pids)
        return if overhead.nil?

        @settings.model.file.memory.remember_compute(@settings.model.context_length, @settings.llama.cache_type,
                                                     overhead)
      end

      def mtp_enabled?
        mode = @settings.model.mtp.to_s.downcase
        return true if %w[on true 1].include?(mode)
        return false if %w[off false 0].include?(mode)

        @settings.model.file.supports_mtp?
      end

      def model_missing
        model_path = @settings.model.path
        return nil unless model_path.to_s.empty? || !File.file?(model_path)

        "GGUF model not found: #{model_path.to_s.empty? ? '<unset>' : model_path} -- run `mimic setup`"
      end
    end
  end
end
