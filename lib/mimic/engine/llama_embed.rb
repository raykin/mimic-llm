require "pathname"
require_relative "../model/schema"
require_relative "../llm_config"
require_relative "../model"
require_relative "../paths"
require_relative "../util/probes"
require_relative "../result"
require_relative "launcher"
require_relative "base"
require_relative "../engine_cli/registry"

module Mimic
  module Engine
    # The embedding server: a second llama-server, on a second port, holding a
    # model that answers /v1/embeddings or /rerank and nothing else.
    #
    # It runs beside the chat server rather than through it -- the router
    # preset loads one generative model per instance, and an embedding model
    # needs process-wide flags (--embeddings sets pooling and restricts the
    # server to that use case) that would apply to the chat model too.
    #
    # Unlike its siblings this one is selected by role, not by config: it must
    # stay out of EngineCli::Registry, which dispatches on llama.engine and
    # drives the setup wizard's engine picker.
    class LlamaEmbed < Base
      RERANK_NAME = /rerank/i

      class << self
        def log_file = Paths::LLM_RUN_DIR / "llama-embed.log"
        def pid_file = Paths::PID_DIR / "llama-embed.pid"

        # This server is one process with no children, so a scan for
        # "llama-server" could only ever find the chat server.
        def proc_scan_fallback? = false

        # Which endpoint a model wants, read from the GGUF. A reranker is an
        # embedding model whose pooling is RANK, but the bge rerankers ship
        # no pooling_type key at all -- for those the name is what is left.
        def mode_for(path)
          return "rerank" if Model::Header.new(path).pooling_type == Model::Schema::POOLING_RANK
          return "rerank" if RERANK_NAME.match?(File.basename(path.to_s))

          "embeddings"
        end

        # The live embedding pids, for the chat side to leave alone.
        def pids
          pid = Util::Probes.read_pid(pid_file, "llama-server")
          pid ? [pid, *Util::Probes.descendants(pid)] : []
        end
      end

      def initialize(settings)
        super
        @embed = settings.embed
      end

      def health_url = "#{@embed.base_url}/health"
      def models_url = "#{@embed.base_url}/v1/models"
      def running? = Util::Probes.http_ok(health_url)
      def mode = @embed.mode == "auto" ? self.class.mode_for(@embed.path) : @embed.mode

      def command(binary)
        [
          binary,
          "-m", @embed.path,
          "-a", @embed.model_alias,
          "--host", @embed.host.to_s,
          "--port", @embed.port.to_s,
          "--ctx-size", @embed.context_length.to_s,
          # A pooled embedding model is non-causal: a document has to fit in
          # one ubatch or llama-server rejects it, so both batch sizes move
          # together rather than leaving -ub at its 512 default.
          "-b", @embed.batch_size.to_s,
          "-ub", @embed.batch_size.to_s,
          "-ngl", "999",
          mode == "rerank" ? "--rerank" : "--embeddings",
        ]
      end

      # llama.cpp's own build, not whatever engine the chat server runs:
      # ik_llama.cpp is the engine for CPU-MoE offload on a big generative
      # model and has no reason to be serving a 600 MB encoder.
      def find_binary
        @find_binary ||= first_existing(EngineCli::Registry.builds("llama.cpp"),
                                        Util::Probes.which("llama-server"), @settings.llama.binary)
      end

      def start
        return Result.error("no embedding model configured -- run `llm embed setup`") unless @embed.configured?

        if @embed.port.to_i == @settings.llama.port.to_i
          return Result.error("embedding server cannot share the same port as llama-server (#{@embed.port})")
        end
        return Result.ok("embedding server already running") if running?

        binary = find_binary
        return Result.error("llama-server binary not found -- run `llm setup`") if binary.nil?
        return Result.error("embedding model not found: #{@embed.path}") unless File.file?(@embed.path)

        launch(binary)
      end

      private

      def launch(binary)
        log_file = self.class.log_file
        log_offset = log_file.exist? ? log_file.size : 0
        pid = launcher.spawn(command(binary))
        if Util::Probes.wait_ready(health_url, alive: -> { Util::Probes.child_alive?(pid) }, label: "waiting for embedding server")
          return Result.ok("embedding server ready on #{@embed.base_url} (#{mode}, pid #{pid})")
        end

        self.class.cleanup_failed(pid)
        Result.error("embedding server failed to start -- see #{log_file}\n" \
                     "#{self.class.last_lines(self.class.log_tail(log_offset))}")
      end
    end
  end
end
