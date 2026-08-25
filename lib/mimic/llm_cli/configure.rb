require_relative "../ui"
require_relative "../llm_config"
require_relative "../engine_cli"

# LLM config editor -- flat key=value editing for model + llama keys.
#
# Edits ~/.llm/config.yaml only.
module Mimic
  module LlmCli
    module Configure
      FIELDS = {
        "model.path" => ["Model GGUF path", :str],
        "model.context_length" => ["Context length", :int],
        "model.mtp" => ["MTP speculative decoding (auto/on/off)", :str],
        "model.temperature" => ["Temperature", :float],
        "model.top_p" => ["top_p", :float],
        "model.top_k" => ["top_k", :int],
        "llama.engine" => ["Inference engine (llama.cpp/ik_llama.cpp/prism-llama.cpp)", :str],
        "llama.port" => ["llama.cpp port", :int],
        "llama.n_slots" => ["Number of llama.cpp slots (1 for local use)", :int],
      }.freeze

      class << self
        def get(cfg, dotted)
          section, key = dotted.split(".")
          cfg[section][key]
        end

        def set(cfg, dotted, raw)
          section, key = dotted.split(".")
          cfg[section][key] = case FIELDS.fetch(dotted)[1]
                              when :int then Integer(raw, 10)
                              when :float then Float(raw)
                              else raw
                              end
        end

        def run
          unless LlmConfig.exists?
            puts Ui.yellow("No LLM config yet -- run `llm setup` first.")
            return
          end

          settings = LlmConfig.load
          cfg = settings.to_h
          prompt = Ui::Prompt.new

          loop do
            picked = prompt.select("Edit which value?", menu_choices(cfg))
            return if picked == "__quit__"
            return save(settings) if picked == "__save__"

            edit(cfg, picked, prompt)
          end
        end

        private
        def menu_choices(cfg)
          choices = FIELDS.map do |dotted, (label, _)|
            { name: format("%-45s = %s", label, get(cfg, dotted)), value: dotted }
          end
          choices << { name: "Save & exit", value: "__save__" }
          choices << { name: "Exit without saving", value: "__quit__" }
        end

        def save(settings)
          settings.save
          EngineCli::Registry.for(settings).render_preset
          puts "#{Ui.green('Saved')} #{LlmConfig::LLM_CONFIG_PATH}"
        end

        def edit(cfg, dotted, prompt)
          raw = prompt.ask("#{FIELDS.fetch(dotted)[0]}:", default: get(cfg, dotted).to_s)
          return if raw.nil?

          set(cfg, dotted, raw)
        rescue ArgumentError, TypeError
          puts Ui.red("Invalid value, keeping previous.")
        end
      end
    end
  end
end
