require_relative "../../../ui"
require_relative "../../../model"
require_relative "../../../llm_config"
require_relative "../../../engine_cli"
require_relative "../../../engine/server_process"
require_relative "harness"

module Mimic
  module LlmCli
    module Dev
      module Quality
        # Serves every model in turn at one fixed context and hands each to the
        # quality harness.
        #
        # It drives the same Settings object the rest of the CLI does, but it
        # is the one caller that must never persist it: a benchmark that
        # rewrites `llm setup`'s answers has changed the thing it was measuring
        # -- the next `llm start` would come up on whichever model the sweep
        # happened to finish on, at the sweep's context rather than the one
        # sized against this card. Hence `remember: false` on every start (the
        # engines' own opt-out of writing model-ctx.json and model-sampling.json)
        # and no `save` anywhere in here. The preset file is shared by every
        # model and is rewritten on each start, so it is re-rendered from the
        # on-disk config on the way out.
        class Sweep
          # An existing `llm setup` preset, so a sweep is comparable with a run
          # someone launched by hand. Low enough that every model on a 24 GB
          # card reaches it without CPU offload deciding the score.
          CONTEXT = 60_000

          def initialize(config, harness:, models:)
            @config = config
            @harness = harness
            @models = models
          end

          def run
            @models.count { |model| serve_and_test(model) }
          ensure
            restore
          end

          # A model nothing has judged yet still has to run somewhere, and the
          # config's own engine belongs to the configured model rather than to
          # this one. The fallbacks are Model::Library's rules in the one
          # direction this needs them: pick an engine given a model, rather
          # than filter models given an engine.
          def self.engine_for(model)
            model.memory.engine || default_engine(model)
          end

          def self.default_engine(model)
            model.moe? && model.memory.iquant? ? "ik_llama.cpp" : "llama.cpp"
          end

          private

          def serve_and_test(model)
            configure(model)
            puts Ui.bold_cyan("\n== #{stem(model)} · #{@config.llama.engine} · #{CONTEXT} ctx ==")
            stop_server
            result = EngineCli::Registry.for(@config).start(**start_options)
            return skipped(result) unless result.ok?

            @harness.run(stem(model))
            true
          end

          def skipped(result)
            puts Ui.red("#{result.message} -- skipping this model")
            false
          end

          def configure(model)
            @config.model.path = model.path.to_s
            @config.model.context_length = CONTEXT
            @config.llama.engine = self.class.engine_for(model)
          end

          # Every model fits fully resident at CONTEXT, so nothing here has a
          # reason to put experts on the CPU -- and a score taken at whatever
          # offload one model happens to have cached is not comparable with one
          # taken at zero. ik_llama.cpp is the only engine with the lever, and
          # the only one whose `start` accepts the keyword.
          def start_options
            @config.llama.ik? ? { remember: false, n_cpu_moe: 0 } : { remember: false }
          end

          # The alias stops at the quant marker, so two quants of one model share
          # it; the stem is what tells the two runs apart in the log.
          def stem(model) = model.path.basename(".gguf").to_s

          def stop_server
            Engine::ServerProcess.chat.stop(exclude: Engine::ServerProcess.embed.pids)
          end

          # The sweep leaves the card free and the preset describing the model
          # `llm setup` chose, not the last one measured. Restarting that model
          # is the user's call -- it costs a full load nothing here needs.
          def restore
            stop_server
            EngineCli::Registry.for(LlmConfig.load).render_preset
          rescue StandardError => e
            puts Ui.yellow("could not restore the configured preset (#{e.message}) -- run `llm config` to rewrite it")
          end
        end
      end
    end
  end
end
