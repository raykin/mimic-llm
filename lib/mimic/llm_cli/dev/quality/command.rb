require_relative "../../../ui"
require_relative "../../base"
require_relative "../../../llm_config"
require_relative "../../../model/library"
require_relative "sweep"
require_relative "harness"
require_relative "engine_seed"

module Mimic
  module LlmCli
    module Dev
      module Quality
        # Serves every model in the library in turn and scores it, so the local
        # results log covers the whole shelf rather than whichever model
        # happened to be configured when someone remembered to run it.
        class Command < Base
          default_task :sweep

          desc "sweep", "score every non-embedding model on its own engine at #{Sweep::CONTEXT} ctx"
          method_option :group, type: :string, default: "--default",
                                desc: "pack group forwarded to local-quality-test.rb"
          method_option :only, type: :string, desc: "substring filter on the model alias"
          def sweep
            harness = require_harness
            models = sweep_models(LlmConfig.load)
            return puts(Ui.yellow("no models to score")) if models.empty?

            announce(models)
            scored = Sweep.new(LlmConfig.load, harness: harness, models: models).run
            puts "\n#{Ui.green("scored #{scored}/#{models.size} models")} -- results appended to #{harness.log_path}"
          end

          desc "engines", "show the per-model engine verdicts the sweep serves on"
          def engines
            rows = sweep_models(LlmConfig.load).map do |model|
              verdict = model.memory.engine
              [stem(model), verdict || Ui.yellow("#{Sweep.engine_for(model)} (default)")]
            end
            return puts(Ui.yellow("no models found")) if rows.empty?

            Ui.table(header: %w[Model Engine], rows: rows)
            puts "\nSeed these from the results log with `llm quality seed`."
          end

          desc "seed", "read the results log and record the best-scoring engine per model"
          def seed
            harness = require_harness
            models = sweep_models(LlmConfig.load)
            written = EngineSeed.new(harness.log_path).apply(models)
            puts "#{Ui.green("seeded #{written} engine verdicts")} from #{harness.log_path}"
          end

          private

          # Embedding models answer /v1/embeddings and nothing else -- every pack
          # in the harness is a chat completion, so scoring one measures nothing.
          # The alias stops at the quant marker, so two quants of one model share
          # it -- the sweep visits them separately and has to name them separately.
          def stem(model) = model.path.basename(".gguf").to_s

          def sweep_models(config)
            found = Model::Library.new(config).all.reject(&:embedding?)
            filter = options[:only]
            filter ? found.select { |m| stem(m).downcase.include?(filter.downcase) } : found
          end

          def announce(models)
            puts Ui.bold_cyan("scoring #{models.size} models at #{Sweep::CONTEXT} ctx, #{options[:group]}")
            puts Ui.yellow("this rewrites nothing in `llm setup` -- run `llm start` afterwards to serve your own model again")
          end

          def require_harness
            script = Harness.locate
            if script.nil?
              puts Ui.red("#{Harness::SCRIPT} not found -- set #{Harness::ENV_VAR} to its path")
              raise SystemExit, 1
            end
            Harness.new(script, group: options.fetch(:group, "--default"))
          end
        end
      end
    end
  end
end
