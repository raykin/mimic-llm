require_relative "../../ui"
require_relative "../../engine"
require_relative "../../model/footprint"
require_relative "../../model"

module Mimic
  module LlmCli
    module Wizard
      class Moe
        def initialize(scan, prompt: Ui::Prompt.new)
          @scan = scan
          @prompt = prompt
        end

        def run
          Ui.banner("llm -- MoE offload wizard")
          paths = moe_model_paths
          return puts "No MoE .gguf models found under the configured search paths." if paths.empty?

          path = choose_model(paths)
          case choose_action(path)
          when :set then set_value(path)
          when :clear then clear_value(path)
          else puts "Cancelled."
          end
        end

        private

        def moe_model_paths
          @scan.each_with_object([]) do |model, found|
            real = model.real.to_s
            found << real if !found.include?(real) && Model::Header.new(real).moe?
          end
        end

        def choose_model(paths)
          step(1, "Model")
          choices = paths.to_h do |path|
            cached = Model.new(path).memory.n_cpu_moe
            ["#{File.basename(path)}#{cached ? " (cached: #{cached})" : ''}", path]
          end
          @prompt.select("MoE model:", choices)
        end

        def choose_action(path)
          step(2, "n_cpu_moe")
          puts "Current cached value: #{Model.new(path).memory.n_cpu_moe || 'none (auto-tunes from 0 on next start)'}"
          @prompt.select("What do you want to do?", [
                           { name: "Set a value (0-#{ceiling(path)})", value: :set },
                           { name: "Clear cached value", value: :clear },
                           { name: "Cancel", value: :cancel },
                         ])
        end

        def set_value(path)
          limit = ceiling(path)
          value = @prompt.ask("Layers to offload to CPU (0-#{limit}):", convert: :int, default: Model.new(path).memory.n_cpu_moe || 0)
          abort "n_cpu_moe must be between 0 and #{limit}" unless value.between?(0, limit)

          Model.new(path).memory.remember_n_cpu_moe(value)
          puts "#{Ui.green('Set')} #{File.basename(path)} n_cpu_moe=#{value}"
        end

        def clear_value(path)
          abort "no cached value to clear for #{File.basename(path)}" if Model.new(path).memory.n_cpu_moe.nil?

          Model.new(path).memory.forget_n_cpu_moe
          puts "#{Ui.green('Cleared')} #{File.basename(path)}"
        end

        def ceiling(path)
          @ceiling ||= Model::Header.new(path).block_count || Engine::IkLlama::CPU_MOE_MAX
        end

        def step(index, title)
          puts "\n#{Ui.bold_cyan("Step #{index}/2")} -- #{title}"
        end
      end
    end
  end
end
