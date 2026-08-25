require_relative "../ui"
require_relative "base"
require_relative "wizard/embed"
require_relative "../llm_config"
require_relative "../model/library"
require_relative "../engine/llama_embed"

module Mimic
  module LlmCli
    # `llm embed` -- the embedding server, run beside the chat server rather
    # than instead of it.
    class Embed < Base
      desc "setup", "pick the embedding model, its port and its batch size"
      def setup
        cfg = LlmConfig.load
        return unless Wizard::Embed.new(cfg, embedding_models(cfg), prompt: @prompt).run
        return unless @prompt.yes?("Start the embedding server now?", default: true)

        start
      end

      desc "start", "start the embedding server"
      def start
        report(Engine::LlamaEmbed.new(LlmConfig.load).start)
      end

      desc "stop", "stop the embedding server"
      def stop
        puts "embedding server: #{Engine::ServerProcess.embed.stop ? 'stopped' : 'was not running'}"
      end

      desc "restart", "stop then start the embedding server"
      def restart
        stop
        start
      end

      desc "status", "embedding server status"
      def status
        cfg = LlmConfig.load
        embed = cfg.embed
        return puts Ui.yellow("No embedding model configured -- run `llm embed setup`") unless embed.configured?

        service = Engine::LlamaEmbed.new(cfg)
        running = service.running?
        puts running ? Ui.green("embedding server running") : Ui.yellow("embedding server not running")
        puts "Model:    #{File.basename(embed.path)}"
        puts "Endpoint: #{embed.base_url}"
        puts "Mode:     #{service.mode}"
        puts "Batch:    #{embed.batch_size}"
      end

      desc "models", "list the embedding models under the search paths"
      def models
        cfg = LlmConfig.load
        found = embedding_models(cfg)
        return puts "No embedding models found under #{cfg.search_paths.to_a.join(', ')}" if found.empty?

        found.each do |model|
          mark = model.path.to_s == cfg.embed.path ? Ui.green("●") : " "
          puts "#{mark} #{model.path} [#{Engine::LlamaEmbed.mode_for(model.path)}]"
        end
      end

      private

      def embedding_models(cfg)
        Model::Library.new(cfg).embedding
      end
    end
  end
end
