require_relative "../../ui"
require_relative "../../llm_config"
require_relative "../../engine/llama_embed"

module Mimic
  module LlmCli
    module Wizard
      # Picks which embedding model `llm embed start` launches, and on which
      # port. The endpoint it serves is not asked for -- Engine::LlamaEmbed reads it
      # off the GGUF, and `mode` in config.yaml overrides that when the header is
      # wrong.
      class Embed
        def initialize(config, models, prompt: Ui::Prompt.new)
          @config = config
          @embed = config.embed
          @models = models
          @prompt = prompt
        end

        def run
          Ui.banner("llm embed -- setup wizard")
          return no_models if @models.empty?

          choose_model
          choose_port
          choose_batch_size
          @config.save
          report
          @config
        end

        private

        def choose_model
          step(1, "Embedding model")
          choices = @models.to_h { |model| [label(model), model.path.to_s] }
          @embed.path = @prompt.select("Embedding model:", choices, default: choices.key(@embed.path))
        end

        def choose_port
          step(2, "Port")
          loop do
            port = @prompt.ask("Port for the embedding server:", convert: :int, default: @embed.port)
            if port.to_i == @config.llama.port.to_i
              puts Ui.red("Port #{port} is where llama-server already serves the chat model.")
              next
            end

            @embed.port = port.to_i
            break
          end
        end

        # Both llama-server batch flags come off this one answer: a pooled
        # encoder cannot split a document across micro-batches, so the physical
        # batch has to hold the longest document rather than sit at its default.
        def choose_batch_size
          step(3, "Batch size")
          puts "Must be at least as long, in tokens, as the longest document you send."
          @embed.batch_size = @prompt.ask("Batch size:", convert: :int, default: @embed.batch_size).to_i
        end

        def label(model)
          mode = Engine::LlamaEmbed.mode_for(model.path)
          "#{model.path.dirname.basename}/#{model.path.basename} [#{mode}]"
        end

        def report
          Ui.panel(
            "Embedding model: #{File.basename(@embed.path)}\n" \
            "Endpoint:        #{@embed.base_url} (#{Engine::LlamaEmbed.new(@config).mode})\n" \
            "Batch size:      #{@embed.batch_size}\n" \
            "Saved to         #{LlmConfig::LLM_CONFIG_PATH}"
          )
        end

        def no_models
          puts "No embedding models found under the configured search paths."
          puts "Add one with `llm path add <dir>` -- see `llm models`."
          nil
        end

        def step(index, title)
          puts "\n#{Ui.bold_cyan("Step #{index}/3")} -- #{title}"
        end
      end
    end
  end
end
