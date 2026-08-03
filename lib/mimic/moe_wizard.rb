require "json"
require "tty-box"
require_relative "vram"
require_relative "services/ik_llama"

module Mimic
  # View, set or clear the cached --n-cpu-moe value a MoE model starts with.
  class MoeWizard
    def initialize(scan, prompt:, pastel:)
      @scan = scan
      @prompt = prompt
      @pastel = pastel
    end

    def run
      puts TTY::Box.frame("llm -- MoE offload wizard", padding: 0)
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

    def cache = @cache ||= Services::IkLlama.load_cache

    def moe_model_paths
      @scan.each_with_object([]) do |(path, _dir), found|
        real = path.realpath.to_s
        found << real if !found.include?(real) && Vram.moe?(real)
      end
    end

    def choose_model(paths)
      step(1, "Model")
      choices = paths.to_h do |path|
        cached = cache[path]
        ["#{File.basename(path)}#{cached ? " (cached: #{cached})" : ''}", path]
      end
      @prompt.select("MoE model:", choices)
    end

    def choose_action(path)
      step(2, "n_cpu_moe")
      puts "Current cached value: #{cache[path] || 'none (auto-tunes from 0 on next start)'}"
      @prompt.select("What do you want to do?", [
                       { name: "Set a value (0-#{ceiling(path)})", value: :set },
                       { name: "Clear cached value", value: :clear },
                       { name: "Cancel", value: :cancel },
                     ])
    end

    def set_value(path)
      limit = ceiling(path)
      value = @prompt.ask("Layers to offload to CPU (0-#{limit}):", convert: :int, default: cache[path] || 0)
      abort "n_cpu_moe must be between 0 and #{limit}" unless value.between?(0, limit)

      Services::IkLlama.save_cache(path, value)
      puts "#{@pastel.green('Set')} #{File.basename(path)} n_cpu_moe=#{value}"
    end

    def clear_value(path)
      abort "no cached value to clear for #{File.basename(path)}" if cache[path].nil?

      cache.delete(path)
      Services::IkLlama::CPU_MOE_CACHE.write(JSON.generate(cache))
      puts "#{@pastel.green('Cleared')} #{File.basename(path)}"
    end

    def ceiling(path)
      @ceiling ||= Vram.block_count(path) || Services::IkLlama::CPU_MOE_MAX
    end

    def step(index, title)
      puts "\n#{@pastel.bold.cyan("Step #{index}/2")} -- #{title}"
    end
  end
end
